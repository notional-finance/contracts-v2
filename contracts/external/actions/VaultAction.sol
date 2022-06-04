// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {ActionGuards} from "./ActionGuards.sol";
import {IVaultAction} from "../../../../interfaces/notional/IVaultController.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";
import {VaultStateLib, VaultState} from "../../internal/vaults/VaultState.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

contract VaultAction is ActionGuards, IVaultAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /**
     * @notice Updates or lists a deployed vault along with its configuration.
     *
     * @param vaultAddress address of deployed vault
     * @param vaultConfig struct of vault configuration
     */
    function updateVault(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig
    ) external override onlyOwner {
        VaultConfiguration.setVaultConfig(vaultAddress, vaultConfig);
        bool enabled = (vaultConfig.flags & VaultConfiguration.ENABLED) == VaultConfiguration.ENABLED;
        emit VaultChange(vaultAddress, enabled);
    }

    /**
     * @notice Enables or disables a vault. If a vault is disabled, no one can enter
     * the vault anymore.
     *
     * @param vaultAddress address of deployed vault
     * @param enable bool if the vault should be enabled immediately
     */
    function setVaultPauseStatus(
        address vaultAddress,
        bool enable
    ) external override onlyOwner {
        VaultConfiguration.setVaultEnabledStatus(vaultAddress, enable);
        emit VaultPauseStatus(vaultAddress, enable);
    }

    /**
     * @notice Allows the owner to reduce the max borrow capacity on the vault and force
     * the redemption of strategy tokens to cash to reduce the overall risk of the vault.
     * This method is intended to be used in emergencies to mitigate insolvency risk.
     * @param vaultAddress address of the vault
     * @param maxVaultBorrowCapacity the new max vault borrow capacity
     * @param maturity the maturity to redeem tokens in, will generally be either the current
     * maturity or the next maturity.
     * @param strategyTokensToRedeem how many tokens we would want to redeem in the maturity
     * @param vaultData vault data to pass to the vault
     */
    function reduceMaxBorrowCapacity(
        address vaultAddress,
        uint80 maxVaultBorrowCapacity,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external override onlyOwner {
        VaultConfiguration.setMaxBorrowCapacity(vaultAddress, maxVaultBorrowCapacity);
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vaultAddress);
        _redeemStrategyTokensToCashInternal(vaultConfig, maturity, strategyTokensToRedeem, vaultData);
    }

    /**
     * @notice Strategy vaults can call this method to redeem strategy tokens to cash
     * and hold them as asset cash within the pool. This should typically be used
     * during settlement but can also be used for vault-wide deleveraging.
     * @param maturity the maturity of the vault where the redemption will take place
     * @param strategyTokensToRedeem the number of strategy tokens redeemed
     * @param vaultData arbitrary data to pass back to the vault
     * @return assetCashRequiredToSettle amount of asset cash still remaining to settle the debt
     * @return underlyingCashRequiredToSettle amount of underlying cash still remaining to settle the debt
     */
    function redeemStrategyTokensToCash(
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external override returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    ) {
        // NOTE: this call must come from the vault itself
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        // NOTE: if the msg.sender is not the vault itself this will revert
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Paused");
        return _redeemStrategyTokensToCashInternal(vaultConfig, maturity, strategyTokensToRedeem, vaultData);
    }

    function _redeemStrategyTokensToCashInternal(
        VaultConfig memory vaultConfig,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) private nonReentrant returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    ) {
        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, maturity);
        int256 assetCashReceived = vaultConfig.redeem(strategyTokensToRedeem, maturity, vaultData);
        require(assetCashReceived > 0);

        vaultState.totalAssetCash = vaultState.totalAssetCash.add(uint256(assetCashReceived));
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.sub(strategyTokensToRedeem);
        vaultState.setVaultState(vaultConfig.vault);

        return _getCashRequiredToSettle(vaultConfig, vaultState, maturity);
    }

    /**
     * @notice Strategy vaults can call this method to deposit asset cash into strategy tokens.
     * @param maturity the maturity of the vault where the redemption will take place
     * @param assetCashToDepositExternal the number of asset cash tokens to deposit (external)
     * @param vaultData arbitrary data to pass back to the vault for deposit
     */
    function depositVaultCashToStrategyTokens(
        uint256 maturity,
        uint256 assetCashToDepositExternal,
        bytes calldata vaultData
    ) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // NOTE: if the msg.sender is not the vault itself this will revert
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Paused");

        VaultState memory vaultState = VaultStateLib.getVaultState(msg.sender, maturity);
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);

        int256 assetCashInternal = assetToken.convertToInternal(SafeInt256.toInt(assetCashToDepositExternal));
        uint256 strategyTokensMinted = vaultConfig.deposit(assetCashInternal, maturity, vaultData);

        vaultState.totalAssetCash = vaultState.totalAssetCash.sub(SafeInt256.toUint(assetCashInternal));
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.add(strategyTokensMinted);
        vaultState.setVaultState(msg.sender);

        // When exchanging asset cash for strategy tokens we will decrease the vault's collateral, ensure that
        // we don't go under the configured minimum here.

        // NOTE: this debt outstanding does not net off escrowed asset cash held in individual accounts so it
        // is a more pessimistic view of the vault's collateral ratio than reality. It's better to be on the safe
        // side here than overestimate the collateral ratio. If there is a lot of escrowed asset cash held in
        // individual accounts it means there has been a lot of deleveraging or lend rates are near zero. Neither
        // of those things are good economic conditions.
        vaultConfig.checkCollateralRatio(vaultState, vaultState.totalVaultShares, vaultState.totalfCash, 0);
    }

    /**
     * @notice Settles an entire vault, can only be called during an emergency stop out or during
     * the vault's defined settlement period. May be called multiple times during a vault term if
     * the vault has been stopped out early.
     *
     * @param vault the vault to settle
     * @param maturity the maturity of the vault
     * @param settleAccounts a list of accounts to manually settle (if any)
     * @param vaultSharesToRedeem the amount of vault shares to settle on each account
     * @param redeemCallData call data passed to redeem for all accounts being settled
     */
    function settleVault(
        address vault,
        uint256 maturity,
        address[] calldata settleAccounts,
        uint256[] calldata vaultSharesToRedeem,
        bytes calldata redeemCallData
    ) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, maturity);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // Ensure that we are past maturity and the vault is able to settle
        require(
            maturity <= block.timestamp &&
            settleAccounts.length == vaultSharesToRedeem.length &&
            vaultState.isFullySettled == false &&
            IStrategyVault(vault).canSettleMaturity(maturity),
            "Cannot Settle"
        );

        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            maturity,
            block.timestamp
        );

        // This settles any accounts passed into the method that have escrowed asset cash
        int256 assetCashShortfall =  _settleAccountsLoop(
            vaultState, vaultConfig, settlementRate, settleAccounts, vaultSharesToRedeem, redeemCallData
        );

        // This is how much it costs in asset cash to settle the pooled portion of the vault
        uint256 assetCashRequiredToSettle = settlementRate.convertFromUnderlying(
            vaultState.totalfCashRequiringSettlement.neg()
        ).toUint();

        if (vaultState.totalAssetCash >= assetCashRequiredToSettle) {
            // In this case, we have sufficient cash to settle the pooled portion and perhaps
            // some extra left to return to accounts
            vaultState.totalAssetCash = vaultState.totalAssetCash - assetCashRequiredToSettle;
        } else {
            // Don't allow the pooled portion of the vault to have a cash shortfall unless all
            // strategy tokens have been redeemed to asset cash. This implies that accounts with
            // escrowed asset cash may end up paying for a broader insolvency in the vault.
            //
            // For the vault to be insolvent, it would be the case that one or more accounts
            // inside the vault are insolvent. Insolvent accounts should be liquidated before
            // settling the vault such that they can be individually settled inside the
            // _settleAccountsLoop to isolate their vault shares. If all insolvent accounts are
            // inside _settleAccountsLoop then there should be no shortfall in the pooled portion.
            //
            // If for some reason every account is insolvent in the vault, then we would still need
            // to redeem all the tokens before we could declare a shortfall in the vault.
            require(vaultState.totalStrategyTokens == 0, "Redeem all tokens");
            assetCashShortfall = assetCashShortfall.add((assetCashRequiredToSettle - vaultState.totalAssetCash).toInt());
            vaultState.totalAssetCash = 0;
        }

        // We always clear fCash requiring settlement because if there is a shortfall we will
        // always attempt to resolve it before exiting the method.
        vaultState.totalfCash = vaultState.totalfCash.sub(vaultState.totalfCashRequiringSettlement);
        vaultState.totalfCashRequiringSettlement = 0;

        if (assetCashShortfall > 0) {
            vaultConfig.resolveCashShortfall(assetCashShortfall);

            // If there is any cash shortfall, we automatically disable the vault. Accounts can still
            // exit but no one can enter. Governance can re-enable the vault.
            VaultConfiguration.setVaultEnabledStatus(vaultConfig.vault, false);
        }

        // TODO: is this the correct behavior if we are in an insolvency
        vaultState.isFullySettled = vaultState.totalfCash == 0 && vaultState.accountsRequiringSettlement == 0;
        vaultState.setVaultState(vault);
    }

    function _settleAccountsLoop(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        AssetRateParameters memory settlementRate,
        address[] calldata settleAccounts,
        uint256[] calldata vaultSharesToRedeem,
        bytes calldata redeemCallData
    ) private returns (int256 assetCashShortfall) {
        (uint256 totalStrategyTokens, uint256 assetCashRedeemed) = _redeemVaultShares(
            vaultState,
            vaultConfig,
            vaultSharesToRedeem,
            redeemCallData
        );

        for (uint i; i < settleAccounts.length; i++) {
            assetCashShortfall = assetCashShortfall.add(
                _settleAccount(
                    vaultState,
                    vaultConfig,
                    settlementRate,
                    settleAccounts[i],
                    vaultSharesToRedeem[i],
                    assetCashRedeemed,
                    totalStrategyTokens
                )
            );
        }
    }

    function _redeemVaultShares(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        uint256[] calldata vaultSharesToRedeem,
        bytes calldata redeemCallData
    ) internal returns (uint256 totalStrategyTokens, uint256 assetCashRedeemed) {
        // Calculate the total vault shares to redeem per account and then redeem all the strategy tokens
        // in one call to the vault for gas efficiency. Will split the cash redeemed back to each account
        // proportionately
        uint256 totalVaultShares;
        for (uint i; i < vaultSharesToRedeem.length; i++) {
            totalVaultShares = totalVaultShares.add(vaultSharesToRedeem[i]);
        }
        (/* */, totalStrategyTokens) = vaultState.getPoolShare(totalVaultShares);
        assetCashRedeemed = vaultConfig.redeem(totalStrategyTokens, vaultState.maturity, redeemCallData).toUint();
    }

    function _settleAccount(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        AssetRateParameters memory settlementRate,
        address account,
        uint256 vaultSharesToRedeem,
        uint256 assetCashRedeemed,
        uint256 totalStrategyTokens
    ) private returns (int256 assetCashShortfall) {
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        require(
            vaultState.maturity == vaultAccount.maturity &&
            vaultAccount.requiresSettlement()
        );
        // Vaults must have some default behavior defined for redemptions and not rely on
        // calldata to make redemption decisions.
        uint256 strategyTokens = vaultState.exitMaturityPool(vaultAccount, vaultSharesToRedeem);

        // Return the portion of the strategy token redemption that the account is owed
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
            SafeInt256.toInt(assetCashRedeemed.mul(strategyTokens).div(totalStrategyTokens))
        );

        // fCash is zeroed out inside this method
        vaultAccount.settleEscrowedAccount(vaultState, settlementRate);

        if (vaultAccount.tempCashBalance >= 0) {
            // TODO: need to authenticate that there is not excess vault shares sold here...
            // Return excess asset cash to the account
            vaultAccount.transferTempCashBalance(vaultConfig.borrowCurrencyId, false);
        } else {
            // Account is insolvent here, add the balance to the shortfall required
            // and clear the account requiring settlement
            assetCashShortfall = vaultAccount.tempCashBalance.neg();

            // Pre-emptive clear the vault account assuming the shortfall will be cleared
            vaultAccount.tempCashBalance = 0;

            if (vaultState.accountsRequiringSettlement > 0) {
                // Don't revert on underflow here, just floor the value at 0 in case
                // we somehow miss an insolvent account in tracking.
                vaultState.accountsRequiringSettlement -= 1;
            }
        }
        vaultAccount.setVaultAccount(vaultConfig);
    }

    /** View Methods **/
    function getVaultConfig(
        address vault
    ) external view override returns (VaultConfig memory vaultConfig) {
        vaultConfig = VaultConfiguration.getVaultConfigView(vault);
    }

    function getVaultState(
        address vault,
        uint256 maturity
    ) external view override returns (VaultState memory vaultState) {
        vaultState = VaultStateLib.getVaultState(vault, maturity);
    }

    function getCurrentVaultState(
        address vault
    ) external view override returns (VaultState memory vaultState) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        vaultState = VaultStateLib.getVaultState(vault, vaultConfig.getCurrentMaturity(block.timestamp));
    }

    function getCurrentVaultMaturity(
        address vault
    ) external override view returns (uint256) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        return vaultConfig.getCurrentMaturity(block.timestamp);
    }

    function getCashRequiredToSettle(
        address vault,
        uint256 maturity
    ) external view override returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, maturity);
        return _getCashRequiredToSettle(vaultConfig, vaultState, maturity);
    }

    function getCashRequiredToSettleCurrent(
        address vault
    ) external view override returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        uint256 currentMaturity = vaultConfig.getCurrentMaturity(block.timestamp);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, currentMaturity);

        return _getCashRequiredToSettle(vaultConfig, vaultState, currentMaturity);
    }

    function _getCashRequiredToSettle(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 maturity
    ) private view returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    ) {
        // If this is prior to maturity, it will return the current asset rate. After maturity it will
        // return the settlement rate.
        AssetRateParameters memory ar = AssetRate.buildSettlementRateView(vaultConfig.borrowCurrencyId, maturity);
        
        // If this is a positive number, there is more cash remaining to be settled.
        // If this is a negative number, there is more cash than required to repay the debt
        int256 assetCashInternal = ar.convertFromUnderlying(vaultState.totalfCashRequiringSettlement)
            .add(vaultState.totalAssetCash.toInt())
            .neg();

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
        assetCashRequiredToSettle = assetToken.convertToExternal(assetCashInternal);
        underlyingCashRequiredToSettle = underlyingToken.convertToExternal(ar.convertToUnderlying(assetCashInternal));
    }
}
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
        int256 assetCashReceived = vaultConfig.redeem(vaultConfig.vault, strategyTokensToRedeem, maturity, vaultData);
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
        uint256 strategyTokensMinted = vaultConfig.deposit(vaultConfig.vault, assetCashInternal, maturity, vaultData);

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
     */
    function settleVault(address vault, uint256 maturity) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, maturity);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // Ensure that we are past maturity and the vault is able to settle
        require(
            maturity <= block.timestamp &&
            vaultState.isSettled == false &&
            // TODO: is this method necessary?
            IStrategyVault(vault).canSettleMaturity(maturity),
            "Cannot Settle"
        );

        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            maturity,
            block.timestamp
        );

        // This is how much it costs in asset cash to settle the pooled portion of the vault
        uint256 assetCashRequiredToSettle = settlementRate.convertFromUnderlying(
            vaultState.totalfCash.neg()
        ).toUint();

        if (vaultState.totalAssetCash < assetCashRequiredToSettle) {
            // Don't allow the pooled portion of the vault to have a cash shortfall unless all
            // strategy tokens have been redeemed to asset cash.
            require(vaultState.totalStrategyTokens == 0, "Redeem all tokens");

            // After this point, we have a cash shortfall and will need to resolve it
            int256 assetCashShortfall = vaultState.totalAssetCash.sub(assetCashRequiredToSettle).toInt();
            uint16 currencyId = vaultConfig.borrowCurrencyId;

            // Attempt to resolve the cash balance using the reserve
            (int256 reserveInternal, /* */, /* */, /* */) = BalanceHandler.getBalanceStorage(
                Constants.RESERVE, currencyId
            );

            if (assetCashShortfall <= reserveInternal) {
                BalanceHandler.setReserveCashBalance(currencyId, reserveInternal - assetCashShortfall);
                vaultState.totalAssetCash = vaultState.totalAssetCash.add(assetCashShortfall.toUint());
            } else {
                // At this point the protocol needs to raise funds from sNOTE since the reserve is
                // insufficient to cover
                BalanceHandler.setReserveCashBalance(currencyId, 0);
                vaultState.totalAssetCash = vaultState.totalAssetCash.add(reserveInternal.toUint());
                emit ProtocolInsolvency(currencyId, vaultConfig.vault, assetCashShortfall - reserveInternal);
            }

            // If there is any cash shortfall, we automatically disable the vault. Accounts can still
            // exit but no one can enter. Governance can re-enable the vault.
            VaultConfiguration.setVaultEnabledStatus(vaultConfig.vault, false);
            vaultState.setVaultState(vault);
        }

        VaultStateLib.setSettledVaultState(vault, maturity);
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
        int256 assetCashInternal = ar.convertFromUnderlying(vaultState.totalfCash)
            .add(vaultState.totalAssetCash.toInt())
            .neg();

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
        assetCashRequiredToSettle = assetToken.convertToExternal(assetCashInternal);
        underlyingCashRequiredToSettle = underlyingToken.convertToExternal(ar.convertToUnderlying(assetCashInternal));
    }
}
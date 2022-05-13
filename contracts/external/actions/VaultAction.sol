// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./ActionGuards.sol";
import {IVaultAction} from "../../../../interfaces/notional/IVaultController.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";
import {VaultStateLib, VaultState} from "../../internal/vaults/VaultState.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

contract VaultAction is ActionGuards, IVaultAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeMath for uint256;

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
        // require(Address.isContract(vaultAddress));
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        // Require that we have a significant amount of allowance set on the vault so we can transfer
        // asset tokens from the vault.
        require(IERC20(assetToken.tokenAddress).allowance(vaultAddress, address(this)) >= type(uint248).max);

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
    ) external override nonReentrant returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    ) {
        // NOTE: this call must come from the vault itself
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        VaultState memory vaultState = VaultStateLib.getVaultState(msg.sender, maturity);
        int256 assetCashReceived = vaultConfig.redeem(strategyTokensToRedeem, vaultData);
        require(assetCashReceived > 0);

        vaultState.totalAssetCash = vaultState.totalAssetCash.add(uint256(assetCashReceived));
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.sub(strategyTokensToRedeem);
        vaultState.setVaultState(msg.sender);

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
        // NOTE: this call must come from the vault itself
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        VaultState memory vaultState = VaultStateLib.getVaultState(msg.sender, maturity);
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);

        int256 assetCashInternal = assetToken.convertToInternal(SafeInt256.toInt(assetCashToDepositExternal));
        uint256 strategyTokensMinted = vaultConfig.deposit(assetCashInternal, vaultData);

        vaultState.totalAssetCash = vaultState.totalAssetCash.sub(SafeInt256.toUint(assetCashInternal));
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.add(strategyTokensMinted);
        vaultState.setVaultState(msg.sender);
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
     * @param nTokensToRedeem amount of nTokens to redeem to cover shortfall (0 if not needed)
     */
    function settleVault(
        address vault,
        uint256 maturity,
        address[] calldata settleAccounts,
        uint256[] calldata vaultSharesToRedeem,
        bytes calldata redeemCallData,
        uint256 nTokensToRedeem
    ) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);

        // Ensure that we are past maturity and the vault is able to settle
        require(maturity <= block.timestamp);
        require(settleAccounts.length == vaultSharesToRedeem.length);
        // The vault will let us know when settlement can begin after maturity
        require(IStrategyVault(vault).canSettleMaturity(maturity), "Vault Cannot Settle");

        VaultState memory vaultState = VaultStateLib.getVaultState(vault, maturity);
        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            maturity,
            block.timestamp
        );
        int256 assetCashRequiredToSettle = settlementRate.convertFromUnderlying(vaultState.totalfCashRequiringSettlement.neg());
        // This will revert if we have insufficient cash. Any remaining cash will be left behind on the vault for vault
        // accounts to withdraw their share of.
        vaultState.totalAssetCash = vaultState.totalAssetCash.sub(SafeInt256.toUint(assetCashRequiredToSettle));
        vaultState.totalfCash = vaultState.totalfCash.sub(vaultState.totalfCashRequiringSettlement);
        vaultState.totalfCashRequiringSettlement = 0;

        int256 assetCashShortfall = _settleAccountsLoop(vaultState, vaultConfig, settlementRate,
            settleAccounts, vaultSharesToRedeem, redeemCallData);

        if (assetCashShortfall > 0) {
            vaultConfig.resolveCashShortfall(assetCashShortfall, nTokensToRedeem);
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
        // Calculate the total vault shares to redeem per account and then redeem all the strategy tokens
        // in one call to the vault for gas efficiency. Will split the cash redeemed back to each account
        // proportionately
        uint256 totalStrategyTokens;
        {
            uint256 totalVaultShares;
            for (uint i; i < vaultSharesToRedeem.length; i++) {
                totalVaultShares = totalVaultShares.add(vaultSharesToRedeem[i]);
            }
            (totalStrategyTokens, /* uint256 totalAssetCash */) = vaultState.getPoolShare(totalVaultShares);
        }
        uint256 assetCashRedeemed = SafeInt256.toUint(vaultConfig.redeem(totalStrategyTokens, redeemCallData));

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

    function _settleAccount(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        AssetRateParameters memory settlementRate,
        address account,
        uint256 vaultSharesToRedeem,
        uint256 assetCashRedeemed,
        uint256 totalStrategyTokens
    ) private returns (int256 assetCashShortfall) {
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig.vault);
        require(
            vaultState.maturity == vaultAccount.maturity &&
            vaultAccount.requiresSettlement
        );
        // Vaults must have some default behavior defined for redemptions and not rely on
        // calldata to make redemption decisions.
        uint256 strategyTokens = vaultState.exitMaturityPool(vaultAccount, vaultSharesToRedeem);

        // Return the portion of the strategy token redemption that the account is owed
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
            SafeInt256.toInt(assetCashRedeemed.mul(strategyTokens).div(totalStrategyTokens))
        );

        // fCash is zeroed out inside this method
        vaultAccount.settleEscrowedAccount(vaultState, vaultConfig, settlementRate);

        if (vaultAccount.tempCashBalance >= 0) {
            // Return excess asset cash to the account
            vaultAccount.transferTempCashBalance(vaultConfig.borrowCurrencyId, false);
        } else {
            // Account is insolvent here, add the balance to the shortfall required
            // and clear the account requiring settlement
            assetCashShortfall = vaultAccount.tempCashBalance.neg();

            // Pre-emptively clear the vault account assuming the shortfall will be cleared
            vaultAccount.requiresSettlement = false;
            vaultAccount.tempCashBalance = 0;

            if (vaultState.accountsRequiringSettlement > 0) {
                // Don't revert on underflow here, just floor the value at 0 in case
                // we somehow miss an insolvent account in tracking.
                vaultState.accountsRequiringSettlement -= 1;
            }
        }
        vaultAccount.setVaultAccount(vaultConfig.vault);
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
        int256 assetCashInternal = ar.convertFromUnderlying(vaultState.totalfCashRequiringSettlement);

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
        assetCashRequiredToSettle = assetToken.convertToExternal(assetCashInternal);
        underlyingCashRequiredToSettle = underlyingToken.convertToExternal(vaultState.totalfCashRequiringSettlement);
    }
}
// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./ActionGuards.sol";
import {IVaultAction} from "../../../../interfaces/notional/IVaultController.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";

contract VaultAction is ActionGuards, IVaultAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using TokenHandler for Token;
    using SafeInt256 for int256;

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
     * @notice Settles an entire vault, can only be called during an emergency stop out or during
     * the vault's defined settlement period. May be called multiple times during a vault term if
     * the vault has been stopped out early.
     *
     * @param vault the vault to settle
     * @param maturity the maturity of the vault
     */
    function settleVault(
        address vault,
        uint256 maturity,
        address[] calldata settleAccounts,
        uint256[] calldata vaultSharesToRedeem,
        uint256 nTokensToRedeem
    ) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);

        // Ensure that we are past maturity and the vault is able to settle
        require(maturity <= block.timestamp);
        require(settleAccounts.length == vaultSharesToRedeem.length);
        // The vault will let us know when settlement can begin after maturity
        require(IStrategyVault(vault).canSettleMaturity(maturity), "Vault Cannot Settle");
        uint16 currencyId = vaultConfig.borrowCurrencyId;

        VaultState memory vaultState = vaultConfig.getVaultState(maturity);
        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            currencyId,
            maturity,
            block.timestamp
        );

        vaultConfig.settlePooledfCash(vaultState, settlementRate);

        int256 assetCashShortfall;
        {
            VaultAccount memory vaultAccount;
            for (uint i; i < settleAccounts.length; i++) {
                vaultAccount = VaultAccountLib.getVaultAccount(settleAccounts[i], vault);
                require(
                    vaultState.maturity == vaultAccount.maturity &&
                    vaultAccount.requiresSettlement
                );
                // Vaults must have some default behavior defined for redemptions and not rely on
                // calldata to make redemption decisions.
                vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem[i]);
                // fCash is zeroed out inside this method
                vaultAccount.settleEscrowedAccount(vaultState, vaultConfig, settlementRate);

                if (vaultAccount.tempCashBalance >= 0) {
                    // Return excess asset cash to the account
                    vaultAccount.transferTempCashBalance(currencyId, false);
                } else {
                    // Account is insolvent here, add the balance to the shortfall required
                    // and clear the account requiring settlement
                    assetCashShortfall = assetCashShortfall.add(vaultAccount.tempCashBalance.neg());

                    // Pre-emptively clear the vault account assuming the shortfall will be cleared
                    vaultAccount.requiresSettlement = false;
                    vaultAccount.maturity = 0;
                    vaultAccount.tempCashBalance = 0;

                    if (vaultState.accountsRequiringSettlement > 0) {
                        // Don't revert on underflow here, just floor the value at 0 in case
                        // we somehow miss an insolvent account in tracking.
                        vaultState.accountsRequiringSettlement -= 1;
                    }
                }
                vaultAccount.setVaultAccount(vault);
            }
        }

        if (assetCashShortfall > 0) {
            vaultConfig.resolveCashShortfall(assetCashShortfall, nTokensToRedeem);
        }

        // TODO: is this the correct behavior if we are in an insolvency
        vaultState.isFullySettled = vaultState.totalfCash == 0 && vaultState.accountsRequiringSettlement == 0;
        vaultConfig.setVaultState(vaultState);
    }
}
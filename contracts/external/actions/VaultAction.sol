// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./ActionGuards.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";

contract VaultAction is ActionGuards {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeMath for uint256;

    /// @notice Emitted when a new vault is listed or updated
    event VaultChange(address vaultAddress, bool enabled);
    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address vaultAddress, bool enabled);

    modifier allowAccountOrVault(address account, address vault) {
        require(msg.sender == account || msg.sender == vault, "Unauthorized");
        _;
    }

    /**
     * @notice Updates or lists a deployed vault along with its configuration.
     *
     * @param vaultAddress address of deployed vault
     * @param vaultConfig struct of vault configuration
     */
    function updateVault(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig
    ) external onlyOwner {
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
    ) external onlyOwner {
        VaultConfiguration.setVaultEnabledStatus(vaultAddress, enable);
        emit VaultPauseStatus(vaultAddress, enable);
    }

    /**
     * @notice Enters the account into the specified vault using the specified fCash
     * amount. Additional data is forwarded to the vault contract.
     *
     * @param account the address that will enter the vault
     * @param vault the vault to enter
     * @param fCash total amount of fCash to borrow to enter the vault
     * @param maxBorrowRate maximum interest rate to borrow at
     * @param vaultData additional data to pass to the vault contract
     * @return vaultSharesMinted
     */
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        bool useUnderlying,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external allowAccountOrVault(account, vault) nonReentrant returns (uint256) { 
        // Vaults cannot be entered if they are paused
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Not Enabled");

        // Vaults cannot be entered if they are in the settlement time period at the end of a quarter.
        require(!ILeveragedVault(vault).isInSettlement(), "In Settlement");

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        // Do this first in case the vault has a matured vault position
        vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);

        // This will update the account's cash balance in memory, this will establish the amount of
        // collateral that the vault account has. This method only transfers from the account, so approvals
        // must be set accordingly.
        vaultAccount.depositIntoAccount(account, vaultConfig.borrowCurrencyId, depositAmountExternal, useUnderlying);

        if (fCash > 0) {
            return _borrowAndEnterVault(
                vaultConfig,
                vaultAccount,
                vaultConfig.getCurrentMaturity(block.timestamp),
                fCash,
                maxBorrowRate,
                vaultData
            );
        } else {
            // If the account is not using any leverage we just enter the vault. No matter what the leverage
            // ratio will decrease in this case so we do not need to check vault health and the account will
            // not have to pay any nToken fees. This is useful for accounts that want to quickly and cheaply
            // deleverage their account without paying down debts.
            AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(vaultConfig.borrowCurrencyId);
            (/* */, uint256 vaultSharesMinted) = vaultAccount.enterAccountIntoVault(vaultConfig, vaultData, assetRate);
            return vaultSharesMinted;
        }
    }

    /**
     * @notice Re-enters the vault at a longer dated maturity. There is no way to
     * partially re-enter a vault, the account's entire position will be rolled
     * forward.
     *
     * @param account the address that will reenter the vault
     * @param vault the vault to reenter
     * @param vaultSharesToRedeem the amount of vault shares to redeem for asset tokens
     * @param fCashToBorrow amount of fCash to borrow in the next maturity
     * @param minLendRate minimum lend rate to close out current position
     * @param maxBorrowRate maximum borrow rate to initiate new position
     * @param vaultData additional data to pass to the vault contract
     */
    function rollVaultPosition(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToBorrow,
        uint32 minLendRate,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external allowAccountOrVault(account, vault) nonReentrant returns (uint256) {
        // Cannot enter a vault if it is not enabled
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Not Enabled");
        require(vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTER), "No Reenter");

        // Vaults can only be rolled during the settlement period
        require(ILeveragedVault(vault).isInSettlement(), "Not in Settlement");
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);

        // Can only roll vaults that are in the current maturity
        uint256 currentMaturity = vaultConfig.getCurrentMaturity(block.timestamp);
        require(vaultAccount.maturity == currentMaturity, "Incorrect maturity");
        // Account must be borrowing fCash, otherwise they should exit.
        require(fCashToBorrow > 0, "Must Borrow");

        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the cash balance.
        vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem);

        // Fully exit the current lending position
        vaultAccount.lendToExitVault(
            vaultConfig,
            vaultAccount.fCash.neg(), // must fully exit the fCash position
            minLendRate,
            block.timestamp
        );

        // If the lending was unsuccessful then we cannot roll the position, the account cannot
        // have two fCash balances.
        require(vaultAccount.fCash == 0 && vaultAccount.requiresSettlement, "Failed Lend");

        // Borrows into the vault, paying nToken fees and checks borrow capacity
       return _borrowAndEnterVault(
            vaultConfig,
            vaultAccount,
            currentMaturity.add(vaultConfig.termLengthInSeconds), // next maturity
            fCashToBorrow,
            maxBorrowRate,
            vaultData
        );
    }

    function _borrowAndEnterVault(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        uint256 maturity,
        uint256 fCashToBorrow,
        uint256 maxBorrowRate,
        bytes calldata vaultData
    ) private returns (uint256) {
        (AssetRateParameters memory assetRate, int256 totalVaultDebt) = vaultAccount.borrowIntoVault(
            vaultConfig,
            maturity,
            SafeInt256.toInt(fCashToBorrow).neg(),
            maxBorrowRate,
            block.timestamp
        );

        // Transfers cash, sets vault account state, mints vault shares
        (
            int256 accountUnderlyingInternalValue,
            uint256 vaultSharesMinted
        ) = vaultAccount.enterAccountIntoVault(vaultConfig, vaultData, assetRate);

        vaultAccount.calculateLeverage(vaultConfig, assetRate, accountUnderlyingInternalValue);
        return vaultSharesMinted;
    }

    /**
     * @notice Exits a vault by redeeming yield tokens, lending to offset fCash debt
     * and then withdrawing any earnings back to the account.
     *
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param vaultSharesToRedeem amount of vault tokens to exit
     * @param fCashToLend amount of fCash to lend
     * @param minLendRate the minimum rate to lend at
     * @param useUnderlying if vault shares should be redeemed to underlying
     */
    function exitVault(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToLend,
        uint32 minLendRate,
        bool useUnderlying
    ) external allowAccountOrVault(account, vault) nonReentrant { 
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        
        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the temporary cash balance.
        int256 accountUnderlyingInternalValue = vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem);
        
        if (vaultAccount.maturity <= block.timestamp) {
            vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);
            require(vaultAccount.requiresSettlement == false); // dev: unsuccessful settlement
        } else {
            AssetRateParameters memory assetRate = vaultAccount.lendToExitVault(
                vaultConfig,
                SafeInt256.toInt(fCashToLend),
                minLendRate,
                block.timestamp
            );
        
            // It's possible that the user redeems more vault shares than they lend (it is not always the case that they
            // will be reducing their leverage ratio here, so we check that this is the case).
            int256 leverageRatio = vaultAccount.calculateLeverage(vaultConfig, assetRate, accountUnderlyingInternalValue);
            require(leverageRatio <= vaultConfig.maxLeverageRatio, "Over Leverage");
        }
        
        // Transfers any net deposit or withdraw from the account
        vaultAccount.transferTempCashBalance(vaultConfig.borrowCurrencyId, useUnderlying);
        vaultAccount.setVaultAccount(vault);
    }

    /**
     * @notice If an account is above the maximum leverage ratio, some amount of vault shares can be redeemed
     * such that they fall back under the maximum leverage ratio. A portion of the redemption will be paid
     * to the msg.sender.
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param vaultSharesToRedeem amount of vault tokens to exit
     */
    function deleverageAccount(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToLend
    ) external nonReentrant { 
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);

        // Check that the account has an active position
        require(block.timestamp < vaultAccount.maturity);
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(vaultConfig.borrowCurrencyId);

        // Check that the leverage ratio is above the maximum allowed
        int256 accountUnderlyingInternalValue = ILeveragedVault(vaultConfig.vault)
            .underlyingInternalValueOf(vaultAccount.account, vaultAccount.maturity);
        int256 leverageRatio = vaultAccount.calculateLeverage(vaultConfig, assetRate, accountUnderlyingInternalValue);
        require(leverageRatio > vaultConfig.maxLeverageRatio, "Insufficient Leverage");

        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the temporary cash balance.
        accountUnderlyingInternalValue = vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem);

        // Pay the liquidator their share out of temp cash balance
        int256 liquidatorPayment = vaultAccount.tempCashBalance
            .mul(vaultConfig.liquidationRate)
            .div(Constants.PERCENTAGE_DECIMALS);
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.sub(liquidatorPayment);

        // The account will now require specialized settlement. We do not allow the liquidator to lend on behalf
        // of the account during liquidation or they can move the fCash market against the account and put them
        // in an insolvent position.
        VaultState memory vaultState = vaultConfig.getVaultState(vaultAccount.maturity);
        vaultAccount.increaseEscrowedAssetCash(vaultState, vaultAccount.tempCashBalance);
        vaultConfig.setVaultState(vaultState);

        // Ensure that the leverage ratio does not drop too much (we would over liquidate the account
        // in this case). If the account is still over leveraged we still allow the transaction to complete
        // in that case.
        leverageRatio = vaultAccount.calculateLeverage(vaultConfig, assetRate, accountUnderlyingInternalValue);
        require(vaultConfig.maxLeverageRatio.mulInRatePrecision(0.70e9) < leverageRatio, "Over liquidation");

        // Sets the vault account
        vaultAccount.setVaultAccount(vault);

        // Transfer the liquidator payment
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        assetToken.transfer(msg.sender, vaultConfig.borrowCurrencyId, liquidatorPayment.neg());
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
    ) external nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);

        // Ensure that we are past maturity and the vault is able to settle
        require(maturity <= block.timestamp);
        require(settleAccounts.length == vaultSharesToRedeem.length);
        // The vault will let us know when settlement can begin after maturity
        require(ILeveragedVault(vault).canSettleMaturity(maturity), "Vault Cannot Settle");
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
                vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem[i]);
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
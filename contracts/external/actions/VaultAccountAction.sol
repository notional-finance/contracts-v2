// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./ActionGuards.sol";
import {IVaultAccountAction} from "../../../../interfaces/notional/IVaultController.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";

contract VaultAccountAction is ActionGuards, IVaultAccountAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeMath for uint256;

    modifier allowAccountOrVault(address account, address vault) {
        require(msg.sender == account || msg.sender == vault, "Unauthorized");
        _;
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
     */
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        bool useUnderlying,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external allowAccountOrVault(account, vault) override nonReentrant { 
        // Ensure that system level accounts cannot enter vaults
        requireValidAccount(account);
        // Vaults cannot be entered if they are paused
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Not Enabled");

        // Vaults cannot be entered if they are in the settlement time period at the end of a quarter.
        require(!IStrategyVault(vault).isInSettlement(), "In Settlement");

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        // Do this first in case the vault has a matured vault position
        vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);

        // This will update the account's cash balance in memory, this will establish the amount of
        // collateral that the vault account has. This method only transfers from the account, so approvals
        // must be set accordingly.
        vaultAccount.depositIntoAccount(account, vaultConfig.borrowCurrencyId, depositAmountExternal, useUnderlying);

        if (fCash > 0) {
            _borrowAndEnterVault(
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
            vaultAccount.enterAccountIntoVault(vaultConfig, vaultData);
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
     * @param opts struct with slippage limits and data to send to vault
     */
    function rollVaultPosition(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToBorrow,
        RollVaultOpts calldata opts
    ) external allowAccountOrVault(account, vault) override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        // Can only roll vaults that are in the current maturity
        uint256 currentMaturity = vaultConfig.getCurrentMaturity(block.timestamp);

        // Cannot roll unless all of these requirements are met
        require(
            vaultConfig.getFlag(VaultConfiguration.ENABLED) &&
            vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTER) &&
            IStrategyVault(vault).isInSettlement() && // vault must be in its settlement period
            vaultAccount.maturity == currentMaturity && // must be in the active maturity
            fCashToBorrow > 0, // must borrow into the next maturity, if not, then they should just exit
            "No Roll Allowed"
        );

        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the cash balance.
        vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem, opts.exitVaultData);

        // Fully exit the current lending position
        vaultAccount.lendToExitVault(
            vaultConfig,
            vaultAccount.fCash.neg(), // must fully exit the fCash position
            opts.minLendRate,
            block.timestamp
        );

        // If the lending was unsuccessful then we cannot roll the position, the account cannot
        // have two fCash balances.
        require(vaultAccount.fCash == 0 && !vaultAccount.requiresSettlement, "Failed Lend");

        // Borrows into the vault, paying nToken fees and checks borrow capacity
        _borrowAndEnterVault(
            vaultConfig,
            vaultAccount,
            currentMaturity.add(vaultConfig.termLengthInSeconds), // next maturity
            fCashToBorrow,
            opts.maxBorrowRate,
            opts.enterVaultData
        );
    }

    function _borrowAndEnterVault(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        uint256 maturity,
        uint256 fCashToBorrow,
        uint256 maxBorrowRate,
        bytes calldata vaultData
    ) private {
        vaultAccount.borrowIntoVault(
            vaultConfig,
            maturity,
            SafeInt256.toInt(fCashToBorrow).neg(),
            maxBorrowRate,
            block.timestamp
        );

        // Transfers cash, sets vault account state, mints vault shares
        int256 accountUnderlyingInternalValue = vaultAccount.enterAccountIntoVault(vaultConfig, vaultData);
        int256 leverageRatio = vaultAccount.calculateLeverage(vaultConfig, accountUnderlyingInternalValue);
        require(leverageRatio <= vaultConfig.maxLeverageRatio, "Max Leverage");
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
        bool useUnderlying,
        bytes calldata exitVaultData
    ) external allowAccountOrVault(account, vault) override nonReentrant { 
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        
        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the temporary cash balance.
        int256 accountUnderlyingInternalValue = vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem, exitVaultData);
        
        if (vaultAccount.maturity <= block.timestamp) {
            vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);
            require(vaultAccount.requiresSettlement == false); // dev: unsuccessful settlement
        } else {
            vaultAccount.lendToExitVault(
                vaultConfig,
                SafeInt256.toInt(fCashToLend),
                minLendRate,
                block.timestamp
            );
        
            // It's possible that the user redeems more vault shares than they lend (it is not always the case that they
            // will be reducing their leverage ratio here, so we check that this is the case).
            int256 leverageRatio = vaultAccount.calculateLeverage(vaultConfig, accountUnderlyingInternalValue);
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
        bytes calldata exitVaultData
    ) external nonReentrant override {
        require(account != msg.sender); // Cannot liquidate yourself
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);

        // Check that the account has an active position
        require(block.timestamp < vaultAccount.maturity);

        // Check that the leverage ratio is above the maximum allowed
        int256 accountUnderlyingInternalValue = IStrategyVault(vaultConfig.vault)
            .underlyingInternalValueOf(vaultAccount.account, vaultAccount.maturity, vaultConfig.assetRate.rate);
        int256 leverageRatio = vaultAccount.calculateLeverage(vaultConfig, accountUnderlyingInternalValue);
        require(leverageRatio > vaultConfig.maxLeverageRatio, "Insufficient Leverage");

        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the temporary cash balance.
        accountUnderlyingInternalValue = vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem, exitVaultData);

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
        leverageRatio = vaultAccount.calculateLeverage(vaultConfig, accountUnderlyingInternalValue);
        require(vaultConfig.maxLeverageRatio.mulInRatePrecision(0.70e9) < leverageRatio, "Over liquidation");

        // Sets the vault account
        vaultAccount.setVaultAccount(vault);

        // Transfer the liquidator payment
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        assetToken.transfer(msg.sender, vaultConfig.borrowCurrencyId, liquidatorPayment.neg());
    }

    /** View Methods **/
    function getVaultAccount(address account, address vault) external override view returns (VaultAccount memory) {
        return VaultAccountLib.getVaultAccount(account, vault);
    }

    function getVaultAccountMaturity(address account, address vault) external override view returns (uint256) {
        return VaultAccountLib.getVaultAccount(account, vault).maturity;
    }

    function getVaultAccountLeverage(address account, address vault) external override view returns (
        int256 leverageRatio,
        int256 maxLeverageRatio
    ) {
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        int256 underlyingInternalValue = IStrategyVault(vault).underlyingInternalValueOf(
            vaultAccount.account, vaultAccount.maturity, vaultConfig.assetRate.rate
        );

        leverageRatio = vaultAccount.calculateLeverage(vaultConfig, underlyingInternalValue);
        maxLeverageRatio = vaultConfig.maxLeverageRatio;
    }
}

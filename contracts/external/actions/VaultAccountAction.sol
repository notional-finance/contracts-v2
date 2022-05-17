// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./ActionGuards.sol";
import {IVaultAccountAction} from "../../../../interfaces/notional/IVaultController.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";
import {VaultStateLib, VaultState} from "../../internal/vaults/VaultState.sol";

contract VaultAccountAction is ActionGuards, IVaultAccountAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;
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
        require(
            vaultConfig.getFlag(VaultConfiguration.ENABLED) && !IStrategyVault(vault).isInSettlement(),
            "Cannot Enter"
        );
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);

        // This will update the account's cash balance in memory, this will establish the amount of
        // collateral that the vault account has. This method only transfers from the account, so approvals
        // must be set accordingly.
        vaultAccount.depositIntoAccount(account, vaultConfig.borrowCurrencyId, depositAmountExternal, useUnderlying);

        if (vaultAccount.maturity < block.timestamp && vaultAccount.fCash != 0) {
            // A matured vault account that still requires settlement has to be settled via a separate
            // method and should not be able to reach this point. (Vaults requiring settlement that are not
            // yet matured will bypass this if condition and can safely re-enter a vault). Additionally, the
            // vault must be fully settled before we can clear the account's fCash debts.
            // Code here is the same as VaultAccountLib.settleVaultAccount but does not do any settlement
            // of of escrowed accounts and does not modify matured state.
            VaultState memory maturedState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);
            require(vaultAccount.requiresSettlement() == false && maturedState.isFullySettled, "Unable to Settle");
            vaultAccount.fCash = 0;
        }

        uint256 maturity = vaultConfig.getCurrentMaturity(block.timestamp);
        vaultAccount.borrowAndEnterVault(vaultConfig, maturity, fCash, maxBorrowRate, vaultData);
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
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
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
        vaultAccount.redeemVaultSharesAndLend(
            vaultConfig,
            vaultSharesToRedeem,
            // NOTE: the vault will receive its share of the asset cash held in escrow for settlement here
            vaultAccount.fCash.neg(), // must fully exit the fCash position
            opts.minLendRate,
            opts.exitVaultData
        );

        // If the lending was unsuccessful then we cannot roll the position, the account cannot
        // have two fCash balances.
        require(vaultAccount.fCash == 0 && vaultAccount.requiresSettlement() == false, "Failed Lend");

        // Borrows into the vault, paying nToken fees and checks borrow capacity
        vaultAccount.borrowAndEnterVault(
            vaultConfig,
            currentMaturity.add(vaultConfig.termLengthInSeconds), // next maturity
            fCashToBorrow,
            opts.maxBorrowRate,
            opts.enterVaultData
        );
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
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        
        VaultState memory vaultState = vaultAccount.redeemVaultSharesAndLend(
            vaultConfig,
            vaultSharesToRedeem,
            SafeInt256.toInt(fCashToLend),
            minLendRate,
            exitVaultData
        );
            
        if (vaultAccount.fCash < 0) {
            // It's possible that the user redeems more vault shares than they lend (it is not always the case that they
            // will be increasing their collateral ratio here, so we check that this is the case).
            vaultConfig.checkCollateralRatio(vaultState, vaultAccount.vaultShares, vaultAccount.fCash, vaultAccount.escrowedAssetCash);
        }
        
        // Transfers any net deposit or withdraw from the account
        vaultAccount.transferTempCashBalance(vaultConfig.borrowCurrencyId, useUnderlying);
        vaultAccount.setVaultAccount(vaultConfig);
    }

    /**
     * @notice If an account is below the minimum collateral ratio, some amount of vault shares can be redeemed
     * such that they fall back under the minimum collateral ratio. A portion of the redemption will be paid
     * to the msg.sender.
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param depositAmountExternal amount of cash to deposit
     * @param useUnderlying true if we should use the underlying token
     */
    function deleverageAccount(
        address account,
        address vault,
        uint256 depositAmountExternal,
        bool useUnderlying
    ) external nonReentrant override returns (uint256 vaultSharesToLiquidator) {
        require(account != msg.sender); // Cannot liquidate yourself
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);

        // Check that the account has an active position. After maturity, accounts will be settled instead.
        require(block.timestamp < vaultAccount.maturity);

        // Check that the collateral ratio is below the minimum allowed
        int256 collateralRatio = vaultConfig.calculateCollateralRatio(vaultState, vaultAccount.vaultShares,
            vaultAccount.fCash, vaultAccount.escrowedAssetCash, 0);
        require(vaultConfig.minCollateralRatio < collateralRatio, "Sufficient Collateral");

        // Vault account will receive some deposit from the liquidator, the liquidator will be able to purchase their
        // vault shares at a discount to the deposited amount
        vaultAccount.depositIntoAccount(msg.sender, vaultConfig.borrowCurrencyId, depositAmountExternal, useUnderlying);

        // The liquidator will purchase vault shares from the vault account at discount. The calculation is:
        // (cashDeposited / assetCashValueOfShares) * liquidationRate * vaultShares
        //      where cashDeposited / assetCashValueOfShares represents the share of the total vault share
        //      value the liquidator has deposited
        //      and liquidationRate is a percentage greater than 100% that represents their bonus
        (int256 assetCashValue, /* */) = vaultState.getCashValueOfShare(vaultConfig, vaultAccount.vaultShares);
        vaultSharesToLiquidator = SafeInt256.toUint(vaultAccount.tempCashBalance)
            .mul(vaultConfig.liquidationRate)
            .mul(vaultAccount.vaultShares)
            .div(SafeInt256.toUint(assetCashValue))
            .div(uint256(Constants.PERCENTAGE_DECIMALS));

        vaultAccount.vaultShares = vaultAccount.vaultShares.sub(vaultSharesToLiquidator);
        // We do not allow the liquidator to lend on behalf of the account during liquidation or they can move the
        // fCash market against the account and put them in an insolvent position. All the cash balance deposited
        // goes into the escrowed asset cash balance.
        vaultAccount.increaseEscrowedAssetCash(vaultState, vaultAccount.tempCashBalance);
        vaultState.setVaultState(vault);

        // Ensure that the collateral ratio does not increase too much (we would over liquidate the account
        // in this case). If the account is still over leveraged we still allow the transaction to complete
        // in that case.
        collateralRatio = vaultConfig.calculateCollateralRatio(vaultState, vaultAccount.vaultShares,
            vaultAccount.fCash, vaultAccount.escrowedAssetCash, 0);
        require(collateralRatio < vaultConfig.minCollateralRatio.mulInRatePrecision(1.30e9) , "Over liquidation");

        // Sets the vault account
        vaultAccount.setVaultAccount(vaultConfig);

        // TODO: allow the liquidator to exit their vault shares at this point? we could just call redeem
        // strategy tokens here...

        // Liquidator will receive vault shares that they can redeem by calling exitVault. If the liquidator has a
        // leveraged position on then their collateral ratio will increase
        VaultAccount memory liquidator = VaultAccountLib.getVaultAccount(msg.sender, vaultConfig);
        // The liquidator must be able to receive the vault shares (i.e. not be in the vault at all or be in the
        // vault at the same maturity).
        require((liquidator.maturity == 0 && liquidator.fCash == 0)  || liquidator.maturity == vaultAccount.maturity);
        liquidator.maturity = vaultAccount.maturity;
        liquidator.vaultShares = liquidator.vaultShares.add(vaultSharesToLiquidator);
        liquidator.setVaultAccount(vaultConfig);
    }

    /** View Methods **/
    function getVaultAccount(address account, address vault) external override view returns (VaultAccount memory) {
        return VaultAccountLib.getVaultAccount(account, VaultConfiguration.getVaultConfigNoAssetRate(vault));
    }

    function getVaultAccountMaturity(address account, address vault) external override view returns (uint256) {
        return VaultAccountLib.getVaultAccount(account, VaultConfiguration.getVaultConfigNoAssetRate(vault)).maturity;
    }

    function getVaultAccountLeverage(address account, address vault) external override view returns (
        int256 collateralRatio,
        int256 minCollateralRatio
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);

        collateralRatio = vaultConfig.calculateCollateralRatio(vaultState, vaultAccount.vaultShares,
            vaultAccount.fCash, vaultAccount.escrowedAssetCash, 0);
        minCollateralRatio = vaultConfig.minCollateralRatio;
    }
}

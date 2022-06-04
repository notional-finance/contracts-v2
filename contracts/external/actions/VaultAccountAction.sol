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
    using SafeUint256 for uint256;

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
    ) external override nonReentrant { 
        // Ensure that system level accounts cannot enter vaults
        requireValidAccount(account);
        // Vaults cannot be entered if they are paused
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_ENTRY);

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
    ) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_ROLL);

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        // Can only roll vaults that are in the current maturity
        uint256 currentMaturity = vaultConfig.getCurrentMaturity(block.timestamp);

        // Cannot roll unless all of these requirements are met
        require(
            vaultConfig.getFlag(VaultConfiguration.ENABLED) &&
            vaultConfig.getFlag(VaultConfiguration.ALLOW_ROLL_POSITION) &&
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

        // This should never be the case for a healthy vault account due to the mechanics of exiting the vault
        // above but we check it for safety here.
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
    ) external override nonReentrant { 
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_EXIT);

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
     * to the receiver (an account specified by the caller).
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param liquidator the address that will receive profits from liquidation
     * @param depositAmountExternal amount of cash to deposit
     * @param useUnderlying true if we should use the underlying token
     * @param redeemData calldata sent to the vault when redeeming liquidator profits
     */
    function deleverageAccount(
        address account,
        address vault,
        address liquidator,
        uint256 depositAmountExternal,
        bool useUnderlying,
        bytes calldata redeemData
    ) external nonReentrant override returns (uint256 profitFromLiquidation) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        // Authorization rules for deleveraging
        if (vaultConfig.getFlag(VaultConfiguration.ONLY_VAULT_DELEVERAGE)) {
            require(msg.sender == vault, "Unauthorized");
        }
        // Cannot liquidate self, if a vault needs to deleverage itself as a whole it has other methods 
        // in VaultAction to do so.
        require(account != msg.sender && account != liquidator, "Unauthorized");

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);

        // Check that the account has an active position. After maturity, accounts will be settled instead.
        require(block.timestamp < vaultAccount.maturity);

        // Check that the collateral ratio is below the minimum allowed
        int256 collateralRatio = vaultConfig.calculateCollateralRatio(vaultState, vaultAccount.vaultShares,
            vaultAccount.fCash, vaultAccount.escrowedAssetCash);
        require(collateralRatio < vaultConfig.minCollateralRatio , "Sufficient Collateral");

        // Vault account will receive some deposit from the liquidator, the liquidator will be able to purchase their
        // vault shares at a discount to the deposited amount
        vaultAccount.depositIntoAccount(liquidator, vaultConfig.borrowCurrencyId, depositAmountExternal, useUnderlying);

        // The liquidator will purchase vault shares from the vault account at discount. The calculation is:
        // (cashDeposited / assetCashValueOfShares) * liquidationRate * vaultShares
        //      where cashDeposited / assetCashValueOfShares represents the share of the total vault share
        //      value the liquidator has deposited
        //      and liquidationRate is a percentage greater than 100% that represents their bonus
        uint256 vaultSharesToLiquidator;
        {
            (int256 assetCashValue, /* */) = vaultState.getCashValueOfShare(vaultConfig, vaultAccount.vaultShares);
            vaultSharesToLiquidator = SafeInt256.toUint(vaultAccount.tempCashBalance)
                .mul(vaultConfig.liquidationRate)
                .mul(vaultAccount.vaultShares)
                .div(SafeInt256.toUint(assetCashValue))
                .div(uint256(Constants.PERCENTAGE_DECIMALS));
        }

        vaultAccount.vaultShares = vaultAccount.vaultShares.sub(vaultSharesToLiquidator);
        // We do not allow the liquidator to lend on behalf of the account during liquidation or they can move the
        // fCash market against the account and put them in an insolvent position. All the cash balance deposited
        // goes into the escrowed asset cash balance.
        vaultAccount.increaseEscrowedAssetCash(vaultState, vaultAccount.tempCashBalance);

        // Ensure that the collateral ratio does not increase too much (we would over liquidate the account
        // in this case). If the account is still over leveraged we still allow the transaction to complete
        // in that case.
        collateralRatio = vaultConfig.calculateCollateralRatio(vaultState, vaultAccount.vaultShares,
            vaultAccount.fCash, vaultAccount.escrowedAssetCash);
        require(
            collateralRatio < vaultConfig.minCollateralRatio.mulInRatePrecision(Constants.VAULT_DELEVERAGE_LIMIT),
            "Over Deleverage Limit"
        );

        // Sets the liquidated account account
        vaultAccount.setVaultAccount(vaultConfig);

        // Redeems the vault shares for asset cash and transfers it to the designated address
        if (vaultConfig.getFlag(VaultConfiguration.TRANSFER_SHARES_ON_DELEVERAGE)) {
            return _transferLiquidatorProfits(liquidator, vaultConfig, vaultSharesToLiquidator, vaultAccount.maturity);
        } else {
            return _redeemLiquidatorProfits(liquidator, vaultConfig, vaultState, vaultSharesToLiquidator,
                redeemData, useUnderlying);
        }
    }

    function _transferLiquidatorProfits(
        address receiver,
        VaultConfig memory vaultConfig,
        uint256 vaultSharesToLiquidator,
        uint256 maturity
    ) private returns (uint256) {
        // Liquidator will receive vault shares that they can redeem by calling exitVault. If the liquidator has a
        // leveraged position on then their collateral ratio will increase
        VaultAccount memory liquidator = VaultAccountLib.getVaultAccount(receiver, vaultConfig);
        // The liquidator must be able to receive the vault shares (i.e. not be in the vault at all or be in the
        // vault at the same maturity).
        require((liquidator.maturity == 0 && liquidator.fCash == 0)  || liquidator.maturity == maturity);
        liquidator.maturity = maturity;
        liquidator.vaultShares = liquidator.vaultShares.add(vaultSharesToLiquidator);
        liquidator.setVaultAccount(vaultConfig);
    }

    function _redeemLiquidatorProfits(
        address receiver,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 vaultSharesToLiquidator,
        bytes calldata redeemData,
        bool useUnderlying
    ) private returns (uint256) {
        (uint256 assetCashWithdrawn, uint256 strategyTokensWithdrawn) = vaultState.exitMaturityPoolDirect(vaultSharesToLiquidator);
        // Redeem returns an int, but we ensure that it is positive here
        uint256 assetCashFromRedeem = vaultConfig.redeem(
            strategyTokensWithdrawn, vaultState.maturity, redeemData
        ).toUint();

        vaultState.setVaultState(vaultConfig.vault);

        uint256 totalProfits = assetCashWithdrawn.add(assetCashFromRedeem);
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        
        // Both returned values are negative to signify that assets have left the protocol
        int256 actualTransferExternal;
        if (useUnderlying) {
            actualTransferExternal = assetToken.redeem(vaultConfig.borrowCurrencyId, receiver, totalProfits);
        } else {
            actualTransferExternal = assetToken.transfer(receiver, vaultConfig.borrowCurrencyId, totalProfits.toInt().neg());
        }

        return actualTransferExternal.neg().toUint();
    }

    /** View Methods **/
    function getVaultAccount(address account, address vault) external override view returns (VaultAccount memory) {
        return VaultAccountLib.getVaultAccount(account, VaultConfiguration.getVaultConfigNoAssetRate(vault));
    }

    function getVaultAccountMaturity(address account, address vault) external override view returns (uint256) {
        return VaultAccountLib.getVaultAccount(account, VaultConfiguration.getVaultConfigNoAssetRate(vault)).maturity;
    }

    function getVaultAccountCollateralRatio(address account, address vault) external override view returns (
        int256 collateralRatio,
        int256 minCollateralRatio
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);
        minCollateralRatio = vaultConfig.minCollateralRatio;

        if (vaultState.isFullySettled && vaultAccount.requiresSettlement() == false) {
            // In this case, the maturity has been settled and although the vault account says that it has
            // some fCash balance it does not actually owe any debt anymore.
            collateralRatio = type(int256).max;
        } else {
            collateralRatio = vaultConfig.calculateCollateralRatio(vaultState, vaultAccount.vaultShares,
                vaultAccount.fCash, vaultAccount.escrowedAssetCash);
        }
    }
}

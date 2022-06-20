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
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /**
     * @notice Borrows a specified amount of fCash in the vault's borrow currency and deposits it
     * all plus the depositAmountExternal into the vault to mint strategy tokens.
     *
     * @param account the address that will enter the vault
     * @param vault the vault to enter
     * @param depositAmountExternal some amount of additional collateral in the borrowed currency
     * to be transferred to vault
     * @param maturity the maturity to borrow at
     * @param fCash amount to borrow
     * @param maxBorrowRate maximum interest rate to borrow at
     * @param vaultData additional data to pass to the vault contract
     */
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        uint256 maturity,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external payable override nonReentrant { 
        // Ensure that system level accounts cannot enter vaults
        requireValidAccount(account);
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_ENTRY);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // Vaults cannot be entered if they are paused
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Cannot Enter");
        require(block.timestamp < maturity, "Cannot Enter");
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);

        uint256 strategyTokens;
        if (vaultAccount.maturity != 0 && vaultAccount.maturity <= block.timestamp) {
            strategyTokens = vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);
        }

        // Deposits some amount of underlying tokens into the vault directly to serve as additional collateral when
        // entering the vault.
        uint256 additionalUnderlyingExternal = vaultConfig.transferUnderlyingToVaultDirect(account, depositAmountExternal);
        vaultAccount.borrowAndEnterVault(
            vaultConfig, maturity, fCash, maxBorrowRate, vaultData, strategyTokens, additionalUnderlyingExternal
        );
    }

    /**
     * @notice Re-enters the vault at a longer dated maturity. The account's existing borrow
     * position will be closed and a new borrow position at the specified maturity will be
     * opened. All strategy token holdings will be rolled forward.
     *
     * @param account the address that will reenter the vault
     * @param vault the vault to reenter
     * @param fCashToBorrow amount of fCash to borrow in the next maturity
     * @param maturity new maturity to borrow at
     * @param opts struct with slippage limits and data to send to vault
     */
    function rollVaultPosition(
        address account,
        address vault,
        uint256 fCashToBorrow,
        uint256 maturity,
        RollVaultOpts calldata opts
    ) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_ROLL);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        // Cannot roll unless all of these requirements are met
        require(
            vaultConfig.getFlag(VaultConfiguration.ENABLED) &&
            vaultConfig.getFlag(VaultConfiguration.ALLOW_ROLL_POSITION) &&
            block.timestamp < vaultAccount.maturity && // cannot have matured yet
            vaultAccount.maturity < maturity && // new maturity must be forward in time
            fCashToBorrow > 0, // must borrow into the next maturity, if not, then they should just exit
            "No Roll Allowed"
        );

        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, vaultAccount.maturity);
        // Exit the maturity pool by removing all the vault shares. All of the strategy tokens will be
        // re-deposited into the new maturity
        uint256 strategyTokens = vaultState.exitMaturityPool(vaultAccount, vaultAccount.vaultShares);

        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the cash balance.
        vaultAccount.lendToExitVault(
            vaultConfig,
            vaultState,
            vaultAccount.fCash.neg(), // must fully exit the fCash position
            opts.minLendRate,
            block.timestamp
        );

        // This should never be the case for a healthy vault account due to the mechanics of exiting the vault
        // above but we check it for safety here.
        require(vaultAccount.fCash == 0, "Failed Lend");
        vaultState.setVaultState(vaultConfig.vault);

        // Borrows into the vault, paying nToken fees and checks borrow capacity
        vaultAccount.borrowAndEnterVault(
            vaultConfig,
            maturity, // This is the new maturity to enter
            fCashToBorrow,
            opts.maxBorrowRate,
            opts.enterVaultData,
            strategyTokens,
            0 // No additional tokens deposited in this method
        );
    }

    /**
     * @notice Prior to maturity, allows an account to withdraw their position from the vault. Will
     * redeem some number of vault shares to the borrow currency and close the borrow position by
     * lending `fCashToLend`. Any shortfall in cash from lending will be transferred from the account,
     * any excess profits will be transferred to the account.
     *
     * Post maturity, will net off the account's debt against vault cash balances and redeem all remaining
     * strategy tokens back to the borrowed currency and transfer the profits to the account.
     *
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param vaultSharesToRedeem amount of vault tokens to exit, only relevant when exiting pre-maturity
     * @param fCashToLend amount of fCash to lend
     * @param minLendRate the minimum rate to lend at
     * @param useUnderlying if vault shares should be redeemed to underlying
     * @param exitVaultData passed to the vault during exit
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

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);

        if (vaultAccount.maturity <= block.timestamp) {
            // Safe this off because settleVaultAccount will clear the maturity
            uint256 maturity = vaultAccount.maturity;
            // Past maturity, a vault cannot lend anymore. When they exit they will just be settling.
            uint256 strategyTokens = vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);

            // Redeems all strategy tokens and updates temp cash balance
            vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
                vaultConfig.redeem(account, strategyTokens, maturity, exitVaultData)
            );
        } else {
            VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, vaultAccount.maturity);

            if (vaultSharesToRedeem > 0) {
                // When an account exits the maturity pool it may get some asset cash credited to its temp
                // cash balance and it will sell the strategy tokens it has a claim on.
                uint256 strategyTokens = vaultState.exitMaturityPool(vaultAccount, vaultSharesToRedeem);

                // Redeems and updates temp cash balance
                vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
                    vaultConfig.redeem(account, strategyTokens, vaultState.maturity, exitVaultData)
                );
            }

            vaultAccount.lendToExitVault(
                vaultConfig,
                vaultState,
                SafeInt256.toInt(fCashToLend),
                minLendRate,
                block.timestamp
            );
                
            if (vaultAccount.fCash < 0) {
                // It's possible that the user redeems more vault shares than they lend (it is not always the case that they
                // will be increasing their collateral ratio here, so we check that this is the case).
                vaultConfig.checkCollateralRatio(vaultState, vaultAccount.vaultShares, vaultAccount.fCash);
            }

            vaultState.setVaultState(vaultConfig.vault);
        }

        // Transfers any net deposit or withdraw from the account
        vaultAccount.transferTempCashBalance(vaultConfig, useUnderlying);

        if (vaultAccount.fCash == 0 && vaultAccount.vaultShares == 0) {
            // If the account has no position in the vault at this point, set the maturity to zero as well
            vaultAccount.maturity = 0;
        }
        vaultAccount.setVaultAccount(vaultConfig);
    }

    /**
     * @notice If an account is below the minimum collateral ratio, this method wil deleverage (liquidate)
     * that account. `depositAmountExternal` in the borrow currency will be transferred from the liquidator
     * and used to offset the account's debt position. The liquidator will receive either vaultShares or
     * cash depending on the vault's configuration.
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param liquidator the address that will receive profits from liquidation
     * @param depositAmountExternal amount of asset cash to deposit
     * @param transferSharesToLiquidator transfers the shares to the liquidator instead of redeeming them
     * @param redeemData calldata sent to the vault when redeeming liquidator profits
     * @return profitFromLiquidation amount of vaultShares or cash received from liquidation
     */
    function deleverageAccount(
        address account,
        address vault,
        address liquidator,
        uint256 depositAmountExternal,
        bool transferSharesToLiquidator,
        bytes calldata redeemData
    ) external nonReentrant override returns (uint256 profitFromLiquidation) {
        VaultConfig memory vaultConfig = _authenticateDeleverage(account, vault, liquidator);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);

        // Check that the account has an active position. After maturity, accounts will be settled instead.
        require(block.timestamp < vaultAccount.maturity);

        // Check that the collateral ratio is below the minimum allowed
        (int256 collateralRatio, int256 vaultShareValue) = vaultConfig.calculateCollateralRatio(
            vaultState, vaultAccount.vaultShares, vaultAccount.fCash
        );
        require(collateralRatio < vaultConfig.minCollateralRatio , "Sufficient Collateral");

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        // This will deposit some amount of cash into vaultAccount.tempCashBalance
        _depositLiquidatorAmount(
            liquidator, assetToken, vaultAccount, vaultConfig, depositAmountExternal, vaultShareValue
        );

        // The liquidator will purchase vault shares from the vault account at discount. The calculation is:
        // (cashDeposited / assetCashValueOfShares) * liquidationRate * vaultShares
        //      where cashDeposited / assetCashValueOfShares represents the share of the total vault share
        //      value the liquidator has deposited
        //      and liquidationRate is a percentage greater than 100% that represents their bonus
        uint256 vaultSharesToLiquidator;
        {
            vaultSharesToLiquidator = SafeInt256.toUint(vaultAccount.tempCashBalance)
                .mul(vaultConfig.liquidationRate.toUint())
                .mul(vaultAccount.vaultShares)
                .div(vaultShareValue.toUint())
                .div(uint256(Constants.RATE_PRECISION));
        }

        vaultAccount.vaultShares = vaultAccount.vaultShares.sub(vaultSharesToLiquidator);
        // The liquidated account will lend to exit their position at a zero interest rate and forgo any future interest
        // from asset tokens. Trading on the AMM during liquidation is risky and lending at a zero interest rate is more
        // costly to the the liquidated account but is safer from a protocol perspective. This can be seen as a protocol
        // level liquidation fee.
        {
            int256 fCashToReduce = vaultConfig.assetRate.convertToUnderlying(vaultAccount.tempCashBalance);
            vaultAccount.updateAccountfCash(vaultConfig, vaultState, fCashToReduce, vaultAccount.tempCashBalance.neg());
            // _calculateLiquidatorDeposit should ensure that we only ever lend up to a zero balance, but in the
            // case of any off by one issues we clear the fCash balance by down to zero.
            if (vaultAccount.fCash > 0) vaultAccount.fCash = 0;
        }

        // Sets the liquidated account account
        vaultAccount.setVaultAccount(vaultConfig);

        // Redeems the vault shares for asset cash and transfers it to the designated address
        if (transferSharesToLiquidator) {
            vaultState.setVaultState(vaultConfig.vault);
            return _transferLiquidatorProfits(liquidator, vaultConfig, vaultSharesToLiquidator, vaultAccount.maturity);
        } else {
            return _redeemLiquidatorProfits(
                liquidator, vaultConfig, vaultState, vaultSharesToLiquidator, redeemData, assetToken
            );
        }
    }

    /// @notice Authenticates a call to the deleverage method
    function _authenticateDeleverage(
        address account,
        address vault,
        address liquidator
    ) private returns (VaultConfig memory vaultConfig) {
        vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // Authorization rules for deleveraging
        if (vaultConfig.getFlag(VaultConfiguration.ONLY_VAULT_DELEVERAGE)) {
            require(msg.sender == vault, "Unauthorized");
        }
        // Cannot liquidate self, if a vault needs to deleverage itself as a whole it has other methods 
        // in VaultAction to do so.
        require(account != msg.sender && account != liquidator, "Unauthorized");
    }

    /// @notice Calculates the amount the liquidator must deposit and then transfers it into Notional,
    /// crediting the account's temporary cash balance. Deposits must be in the form of asset cash.
    function _depositLiquidatorAmount(
        address liquidator,
        Token memory assetToken,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 _depositAmountExternal,
        int256 vaultShareValue
    ) private {
        int256 depositAmountExternal = _depositAmountExternal.toInt();
        if (assetToken.tokenType == TokenType.aToken) {
            // Handles special accounting requirements for aTokens
            depositAmountExternal = AaveHandler.convertToScaledBalanceExternal(
                vaultConfig.borrowCurrencyId, depositAmountExternal
            );
        }

        // Calculates the maximum deleverage amount
        (int256 maxLiquidatorDepositAssetCash, bool mustLiquidateFull) = vaultAccount.calculateDeleverageAmount(
            vaultConfig, vaultShareValue
        );
        // For aTokens this amount is in scaled balance external precision (the same as depositAmountExternal)
        int256 maxLiquidatorDepositExternal = assetToken.convertToExternal(maxLiquidatorDepositAssetCash);

        // NOTE: deposit amount external is always positive in this method
        if (depositAmountExternal < maxLiquidatorDepositExternal) {
            // If this flag is set, the liquidator must deposit more cash in ordert to liquidate the account
            // down to a zero fCash balance because it will fall under the minimum borrowing limit.
            require(!mustLiquidateFull, "Must Liquidate All Debt");
        } else {
            // In the other case, limit the deposited amount to the maximum
            depositAmountExternal = maxLiquidatorDepositExternal;
        }

        // Transfers the amount of asset tokens into Notional and credit it to the account's temp cash balance
        int256 assetAmountExternalTransferred = assetToken.transfer(
            liquidator, vaultConfig.borrowCurrencyId, depositAmountExternal
        );

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
            assetToken.convertToInternal(assetAmountExternalTransferred)
        );
    }

    /// @notice Transfers liquidator profits in the form of vault shares to be returned to the liquidator
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
        // vault at the same maturity). If the liquidator has fCash in the current maturity then their collateral
        // ratio will increase as a result of the liquidation, no need to check their collateral position.
        require(liquidator.maturity == 0 || liquidator.maturity == maturity, "Vault Shares Mismatch"); // dev: has vault shares
        liquidator.maturity = maturity;
        liquidator.vaultShares = liquidator.vaultShares.add(vaultSharesToLiquidator);
        liquidator.setVaultAccount(vaultConfig);

        return vaultSharesToLiquidator;
    }

    /// @notice Redeems liquidator profits back to asset cash and transfers it to the liquidator
    function _redeemLiquidatorProfits(
        address liquidator,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 vaultShares,
        bytes calldata redeemData,
        Token memory assetToken
    ) private returns (uint256) {
        (uint256 assetCash, uint256 strategyTokens) = vaultState.exitMaturityPoolDirect(vaultShares);
        int256 assetCashInternal = vaultConfig.redeem(liquidator, strategyTokens, vaultState.maturity, redeemData);
        assetCashInternal = assetCashInternal.add(assetCash.toInt());

        vaultState.setVaultState(vaultConfig.vault);

        // Returns a negative amount to signify assets have left the protocol. For aTokens this is the scaled
        // balance external.
        int256 actualTransferExternal = assetToken.transfer(
            liquidator, vaultConfig.borrowCurrencyId, assetToken.convertToExternal(assetCashInternal.neg())
        );

        if (assetToken.tokenType == TokenType.aToken) {
            // Convert this back to aToken balanceOf amount to return back to the liquidator
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
            actualTransferExternal = AaveHandler.convertFromScaledBalanceExternal(
                underlyingToken.tokenAddress, actualTransferExternal
            );
        }

        // actualTransferExternal is negative to signify assets have left the protocol
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
        int256 minCollateralRatio,
        int256 maxLiquidatorDepositAssetCash,
        bool mustLiquidateFull
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);
        minCollateralRatio = vaultConfig.minCollateralRatio;

        if (vaultState.isSettled) {
            // In this case, the maturity has been settled and although the vault account says that it has
            // some fCash balance it does not actually owe any debt anymore.
            collateralRatio = type(int256).max;
        } else {
            int256 vaultShareValue;
            (collateralRatio, vaultShareValue) = vaultConfig.calculateCollateralRatio(
                vaultState, vaultAccount.vaultShares, vaultAccount.fCash
            );

            // Calculates liquidation factors if the account is eligible
            if (collateralRatio < minCollateralRatio) {
                (maxLiquidatorDepositAssetCash, mustLiquidateFull) = vaultAccount.calculateDeleverageAmount(
                    vaultConfig, vaultShareValue
                );
            }
        }
    }

    function getLibInfo() external pure returns (address) {
        return address(TradingAction);
    }
}

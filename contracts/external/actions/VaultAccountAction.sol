// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {ActionGuards} from "./ActionGuards.sol";
import {IVaultAccountAction} from "../../../interfaces/notional/IVaultController.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";
import {VaultStateLib, VaultState} from "../../internal/vaults/VaultState.sol";
import {TokenHandler, Token, AaveHandler} from "../../internal/balances/TokenHandler.sol";

contract VaultAccountAction is ActionGuards, IVaultAccountAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Borrows a specified amount of fCash in the vault's borrow currency and deposits it
    /// all plus the depositAmountExternal into the vault to mint strategy tokens.
    /// @param account the address that will enter the vault
    /// @param vault the vault to enter
    /// @param depositAmountExternal some amount of additional collateral in the borrowed currency
    /// to be transferred to vault
    /// @param maturity the maturity to borrow at
    /// @param fCash amount to borrow
    /// @param maxBorrowRate maximum interest rate to borrow at
    /// @param vaultData additional data to pass to the vault contract
    /// @return strategyTokensAdded the total strategy tokens added to the maturity, including any tokens
    /// from settlement. Allows enterVault to be used by off-chain methods to get an accurate simulation
    /// of the strategy tokens minted.
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        uint256 maturity,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external payable override nonReentrant returns (uint256 strategyTokensAdded) { 
        // Ensure that system level accounts cannot enter vaults
        requireValidAccount(account);
        require(account != vault);

        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_ENTRY);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // Vaults cannot be entered if they are paused or matured
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Cannot Enter");
        require(block.timestamp < maturity, "Cannot Enter");
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);

        uint256 strategyTokens;
        if (vaultAccount.maturity != 0 && vaultAccount.maturity <= block.timestamp) {
            // These strategy tokens will be transferred to the new maturity
            strategyTokens = vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);
        }

        // Deposits some amount of underlying tokens into the vault directly to serve as additional collateral when
        // entering the vault.
        uint256 additionalUnderlyingExternal = vaultConfig.transferUnderlyingToVaultDirect(account, depositAmountExternal);
        strategyTokensAdded = vaultAccount.borrowAndEnterVault(
            vaultConfig, maturity, fCash, maxBorrowRate, vaultData, strategyTokens, additionalUnderlyingExternal
        );

        emit VaultEnterPosition(vault, account, maturity, fCash);
    }

    /// @notice Re-enters the vault at a longer dated maturity. The account's existing borrow position will be closed
    /// and a new borrow position at the specified maturity will be opened. Strategy token holdings will transfer to
    /// the longer dated maturity.
    /// @param account the address that will reenter the vault
    /// @param vault the vault to reenter
    /// @param fCashToBorrow amount of fCash to borrow in the next maturity
    /// @param maturity new maturity to borrow at
    /// @param depositAmountExternal amount to deposit into the new maturity
    /// @param minLendRate slippage protection for repaying debts
    /// @param maxBorrowRate slippage protection for new borrow position
    /// @return strategyTokensAdded the total strategy tokens added to the maturity, including any tokens
    /// rolled from the previous maturity.. Allows rollVaultPosition to be used by off-chain methods to get
    /// an accurate simulation of the strategy tokens minted.
    function rollVaultPosition(
        address account,
        address vault,
        uint256 fCashToBorrow,
        uint256 maturity,
        uint256 depositAmountExternal,
        uint32 minLendRate,
        uint32 maxBorrowRate,
        bytes calldata enterVaultData
    ) external payable override nonReentrant returns (uint256 strategyTokensAdded) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_ROLL);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
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
        uint256 strategyTokens = vaultState.exitMaturity(vaultAccount, vaultAccount.vaultShares);

        // Exit the vault first and debit the temporary cash balance with the cost to exit
        vaultAccount.lendToExitVault(
            vaultConfig,
            vaultState,
            vaultAccount.fCash.neg(), // must fully exit the fCash position
            minLendRate,
            block.timestamp
        );

        // This should never be the case for a healthy vault account due to the mechanics of exiting the vault
        // above but we check it for safety here.
        require(vaultAccount.fCash == 0, "Failed Lend");
        vaultState.setVaultState(vaultConfig.vault);

        // Takes a deposit from the user as repayment for the lending, allows an account to roll their position
        // even if they are close to the max borrow capacity.
        if (depositAmountExternal > 0) {
            vaultAccount.depositForRollPosition(vaultConfig, depositAmountExternal);
        }

        // Enters the vault at the longer dated maturity. The account is required to borrow at this
        // point due  to the requirement earlier in this method, they cannot enter the maturity
        // with below minAccountBorrowSize
        strategyTokensAdded = vaultAccount.borrowAndEnterVault(
            vaultConfig,
            maturity, // This is the new maturity to enter
            fCashToBorrow,
            maxBorrowRate,
            enterVaultData,
            strategyTokens,
            0 // No additional tokens deposited in this method
        );

        emit VaultRollPosition(vault, account, maturity, fCashToBorrow);
    }

    /// @notice Prior to maturity, allows an account to withdraw their position from the vault. Will
    /// redeem some number of vault shares to the borrow currency and close the borrow position by
    /// lending `fCashToLend`. Any shortfall in cash from lending will be transferred from the account,
    /// any excess profits will be transferred to the account.
    /// Post maturity, will net off the account's debt against vault cash balances and redeem all remaining
    /// strategy tokens back to the borrowed currency and transfer the profits to the account.
    /// @param account the address that will exit the vault
    /// @param vault the vault to enter
    /// @param receiver the address that will receive profits
    /// @param vaultSharesToRedeem amount of vault tokens to exit, only relevant when exiting pre-maturity
    /// @param fCashToLend amount of fCash to lend
    /// @param minLendRate the minimum rate to lend at
    /// @param exitVaultData passed to the vault during exit
    /// @return underlyingToReceiver amount of underlying tokens returned to the receiver on exit
    function exitVault(
        address account,
        address vault,
        address receiver,
        uint256 vaultSharesToRedeem,
        uint256 fCashToLend,
        uint32 minLendRate,
        bytes calldata exitVaultData
    ) external payable override nonReentrant returns (uint256 underlyingToReceiver) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_EXIT);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        require(
            vaultAccount.lastEntryBlockHeight + Constants.VAULT_ACCOUNT_MIN_BLOCKS <= block.number,
            "Min Entry Blocks"
        );

        if (vaultAccount.maturity <= block.timestamp) {
            // Save this off because settleVaultAccount will clear the maturity
            uint256 maturity = vaultAccount.maturity;
            // Past maturity, an account will be settled instead
            uint256 strategyTokens = vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);

            if (vaultAccount.tempCashBalance > 0) {
                // Transfer asset cash back to the account
                VaultConfiguration.transferFromNotional(
                    receiver, vaultConfig.borrowCurrencyId, vaultAccount.tempCashBalance
                );
                vaultAccount.tempCashBalance = 0;
            }

            // Redeems all strategy tokens and any profits are sent back to the account, it is possible for temp
            // cash balance to be negative here if the account is insolvent
            underlyingToReceiver = vaultConfig.redeemWithDebtRepayment(
                vaultAccount, receiver, strategyTokens, maturity, exitVaultData
            );
            emit VaultExitPostMaturity(vault, account, maturity, underlyingToReceiver);
        } else {
            VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, vaultAccount.maturity);
            // Puts a negative cash balance on the vault's temporary cash balance
            vaultAccount.lendToExitVault(
                vaultConfig, vaultState, fCashToLend.toInt(), minLendRate, block.timestamp
            );

            uint256 strategyTokens = vaultState.exitMaturity(vaultAccount, vaultSharesToRedeem);

            if (vaultAccount.tempCashBalance > 0) {
                // Transfer asset cash back to the account, this is possible if there is asset cash
                // when the vault exits the maturity
                VaultConfiguration.transferFromNotional(
                    receiver, vaultConfig.borrowCurrencyId, vaultAccount.tempCashBalance
                );
                vaultAccount.tempCashBalance = 0;
            }

            // If insufficient strategy tokens are redeemed (or if it is set to zero), then
            // redeem with debt repayment will recover the repayment from the account's wallet
            // directly.
            underlyingToReceiver = vaultConfig.redeemWithDebtRepayment(
                vaultAccount, receiver, strategyTokens, vaultState.maturity, exitVaultData
            );

            // It's possible that the user redeems more vault shares than they lend (it is not always the case
            // that they will be increasing their collateral ratio here, so we check that this is the case).
            vaultConfig.checkCollateralRatio(vaultState, vaultAccount);

            // Set the vault state after redemption completes
            vaultState.setVaultState(vaultConfig.vault);
            emit VaultExitPreMaturity(vault, account, vaultState.maturity, fCashToLend, vaultSharesToRedeem, underlyingToReceiver);
        }

        if (vaultAccount.fCash == 0 && vaultAccount.vaultShares == 0) {
            // If the account has no position in the vault at this point, set the maturity to zero as well
            vaultAccount.maturity = 0;
        }
        vaultAccount.setVaultAccount(vaultConfig);
    }

    /// @notice If an account is below the minimum collateral ratio, this method wil deleverage (liquidate)
    /// that account. `depositAmountExternal` in the borrow currency will be transferred from the liquidator
    /// and used to offset the account's debt position. The liquidator will receive either vaultShares or
    /// cash depending.
    /// @param account the address that will exit the vault
    /// @param vault the vault to enter
    /// @param liquidator the address that will receive profits from liquidation
    /// @param depositAmountExternal amount of asset cash to deposit
    /// @param transferSharesToLiquidator transfers the shares to the liquidator instead of redeeming them
    /// @param redeemData calldata sent to the vault when redeeming liquidator profits
    /// @return profitFromLiquidation amount of vaultShares or cash received from liquidation
    function deleverageAccount(
        address account,
        address vault,
        address liquidator,
        uint256 depositAmountExternal,
        bool transferSharesToLiquidator,
        bytes calldata redeemData
    ) external nonReentrant override returns (uint256 profitFromLiquidation) {
        // Do not allow invalid accounts to liquidate
        requireValidAccount(liquidator);
        require(liquidator != vault);

        VaultConfig memory vaultConfig = _authenticateDeleverage(account, vault, liquidator);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);

        // Check that the account has an active position. After maturity, accounts will be settled instead.
        require(block.timestamp < vaultAccount.maturity);

        // Check that the collateral ratio is below the minimum allowed
        (int256 collateralRatio, int256 vaultShareValue) = vaultConfig.calculateCollateralRatio(
            vaultState, account, vaultAccount.vaultShares, vaultAccount.fCash
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
            vaultSharesToLiquidator = vaultAccount.tempCashBalance.toUint()
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
            emit VaultDeleverageAccount(vault, account, vaultSharesToLiquidator, fCashToReduce);
        }

        // Sets the liquidated account account
        vaultAccount.setVaultAccount(vaultConfig);

        // Redeems the vault shares for asset cash and transfers it to the designated address
        emit VaultLiquidatorProfit(vault, account, liquidator, vaultSharesToLiquidator, transferSharesToLiquidator);
        if (transferSharesToLiquidator) {
            vaultState.setVaultState(vaultConfig.vault);
            profitFromLiquidation = _transferLiquidatorProfits(liquidator, vaultConfig, vaultSharesToLiquidator, vaultAccount.maturity);
        } else {
            profitFromLiquidation = _redeemLiquidatorProfits(
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
        require(vaultConfig.getFlag(VaultConfiguration.DISABLE_DELEVERAGE) == false);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // Authorization rules for deleveraging
        if (vaultConfig.getFlag(VaultConfiguration.ONLY_VAULT_DELEVERAGE)) {
            require(msg.sender == vault, "Unauthorized");
        } else {
            require(msg.sender == liquidator, "Unauthorized");
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
        (
            int256 maxLiquidatorDepositAssetCash,
            int256 debtOutstandingAboveMinBorrow
        ) = vaultAccount.calculateDeleverageAmount(vaultConfig, vaultShareValue);
        // Catch potential edge cases where this is negative due to insolvency inside the vault itself
        require(maxLiquidatorDepositAssetCash > 0);
        // For aTokens this amount is in scaled balance external precision (the same as depositAmountExternal)
        int256 maxLiquidatorDepositExternal = assetToken.convertToExternal(maxLiquidatorDepositAssetCash);

        // NOTE: deposit amount external is always positive in this method
        if (depositAmountExternal < maxLiquidatorDepositExternal) {
            // If liquidating past the debt outstanding above the min borrow, then the entire debt outstanding
            // must be liquidated (that is set to maxLiquidatorDepositExternal)
            require(depositAmountExternal < assetToken.convertToExternal(debtOutstandingAboveMinBorrow), "Must Liquidate All Debt");
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
        VaultAccount memory liquidator = VaultAccountLib.getVaultAccount(receiver, vaultConfig.vault);
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
    ) private returns (uint256 underlyingToReceiver) {
        (uint256 assetCash, uint256 strategyTokens) = vaultState.exitMaturityDirect(vaultShares);
        (/* */, underlyingToReceiver) = vaultConfig.redeemWithoutDebtRepayment(
            liquidator, strategyTokens, vaultState.maturity, redeemData
        );

        // Set the vault state after redemption completes
        vaultState.setVaultState(vaultConfig.vault);

        if (assetCash > 0) {
            // Represents the amount of asset cash returned to the liquidator in underlying terms
            uint256 underlyingRedeemed = assetToken.redeem(
                vaultConfig.borrowCurrencyId, liquidator, assetToken.convertToExternal(assetCash.toInt()).toUint()
            ).neg().toUint();
            underlyingToReceiver = underlyingToReceiver.add(underlyingRedeemed);
        }
    }

    /** View Methods **/
    function getVaultAccount(address account, address vault) external override view returns (VaultAccount memory) {
        return VaultAccountLib.getVaultAccount(account, vault);
    }

    function getVaultAccountDebtShares(
        address account,
        address vault
    ) external override view returns (
        uint256 debtSharesMaturity,
        uint256[2] memory accountDebtShares,
        uint256 accountStrategyTokens
    ) {
        VaultAccountSecondaryDebtShareStorage storage s = 
            LibStorage.getVaultAccountSecondaryDebtShare()[account][vault];
        debtSharesMaturity = s.maturity;
        accountDebtShares[0] = s.accountDebtSharesOne;
        accountDebtShares[1] = s.accountDebtSharesTwo;

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);
        (/* */, accountStrategyTokens) = vaultState.getPoolShare(vaultAccount.vaultShares);
    }

    function getVaultAccountCollateralRatio(address account, address vault) external override view returns (
        int256 collateralRatio,
        int256 minCollateralRatio,
        int256 maxLiquidatorDepositAssetCash,
        uint256 vaultSharesToLiquidator
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, vaultAccount.maturity);
        minCollateralRatio = vaultConfig.minCollateralRatio;

        if (vaultState.isSettled) {
            // In this case, the maturity has been settled and although the vault account says that it has
            // some fCash balance it does not actually owe any debt anymore.
            collateralRatio = type(int256).max;
        } else {
            int256 vaultShareValue;
            (collateralRatio, vaultShareValue) = vaultConfig.calculateCollateralRatio(
                vaultState, account, vaultAccount.vaultShares, vaultAccount.fCash
            );

            // Calculates liquidation factors if the account is eligible
            if (collateralRatio < minCollateralRatio && vaultShareValue > 0) {
                (maxLiquidatorDepositAssetCash, /* */) = vaultAccount.calculateDeleverageAmount(
                    vaultConfig, vaultShareValue
                );

                vaultSharesToLiquidator = maxLiquidatorDepositAssetCash.toUint()
                    .mul(vaultConfig.liquidationRate.toUint())
                    .mul(vaultAccount.vaultShares)
                    .div(vaultShareValue.toUint())
                    .div(uint256(Constants.RATE_PRECISION));
            }
        }
    }

    function getLibInfo() external pure returns (address) {
        return address(TradingAction);
    }
}

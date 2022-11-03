// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {
    VaultAccount,
    VaultAccountStorage,
    VaultSettledAssetsStorage,
    VaultAccountSecondaryDebtShareStorage,
    VaultSecondaryBorrowStorage
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {TokenType, Token, TokenHandler} from "../balances/TokenHandler.sol";

import {VaultConfig, VaultConfiguration} from "./VaultConfiguration.sol";
import {VaultStateLib, VaultState} from "./VaultState.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

library VaultAccountLib {
    using VaultConfiguration for VaultConfig;
    using VaultStateLib for VaultState;
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    event VaultSettledAssetsRemaining(
        address indexed vault,
        uint256 indexed maturity,
        int256 remainingAssetCash,
        uint256 remainingStrategyTokens
    );

    /// @notice Returns a single account's vault position
    function getVaultAccount(
        address account, address vault
    ) internal view returns (VaultAccount memory vaultAccount) {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage.getVaultAccount();
        VaultAccountStorage storage s = store[account][vault];

        // fCash is negative on the stack
        vaultAccount.fCash = -int256(uint256(s.fCash));
        vaultAccount.maturity = s.maturity;
        vaultAccount.vaultShares = s.vaultShares;
        vaultAccount.account = account;
        vaultAccount.tempCashBalance = 0;
        vaultAccount.lastEntryBlockHeight = s.lastEntryBlockHeight;
    }

    /// @notice Sets a single account's vault position in storage
    function setVaultAccount(VaultAccount memory vaultAccount, VaultConfig memory vaultConfig) internal {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[vaultAccount.account][vaultConfig.vault];

        // The temporary cash balance must be cleared to zero by the end of the transaction
        require(vaultAccount.tempCashBalance == 0); // dev: cash balance not cleared
        // An account must maintain a minimum borrow size in order to enter the vault. If the account
        // wants to exit under the minimum borrow size it must fully exit so that we do not have dust
        // accounts that become insolvent.
        if (vaultAccount.fCash.neg() < vaultConfig.minAccountBorrowSize) {
            // NOTE: use 1 to represent the minimum amount of vault shares due to rounding in the
            // vaultSharesToLiquidator calculation
            require(vaultAccount.fCash == 0 || vaultAccount.vaultShares <= 1, "Min Borrow");
        }

        if (vaultConfig.hasSecondaryBorrows()) {
            VaultAccountSecondaryDebtShareStorage storage _s = 
                LibStorage.getVaultAccountSecondaryDebtShare()[vaultAccount.account][vaultConfig.vault];
            uint256 secondaryMaturity = _s.maturity;
            require(vaultAccount.maturity == secondaryMaturity || secondaryMaturity == 0); // dev: invalid maturity
        }

        s.fCash = vaultAccount.fCash.neg().toUint().toUint80();
        s.vaultShares = vaultAccount.vaultShares.toUint80();
        s.maturity = vaultAccount.maturity.toUint40();
        s.lastEntryBlockHeight = vaultAccount.lastEntryBlockHeight.toUint32();
    }

    /// @notice Updates an account's fCash position and the current vault state at the same time. Also updates
    /// and checks the total borrow capacity
    /// @param vaultAccount vault account
    /// @param vaultConfig vault configuration
    /// @param vaultState vault state matching the maturity
    /// @param netfCash fCash change to the account, (borrowing < 0, lending > 0)
    /// @param netAssetCash amount of asset cash to charge or credit to the account, must be the oppositely
    /// signed compared to the netfCash sign
    function updateAccountfCash(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 netfCash,
        int256 netAssetCash
    ) internal {
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(netAssetCash);

        // Update fCash state on the account and the vault
        vaultAccount.fCash = vaultAccount.fCash.add(netfCash);
        require(vaultAccount.fCash <= 0);
        vaultState.totalfCash = vaultState.totalfCash.add(netfCash);
        require(vaultState.totalfCash <= 0);

        // Updates the total borrow capacity
        VaultConfiguration.updateUsedBorrowCapacity(vaultConfig.vault, vaultConfig.borrowCurrencyId, netfCash);
    }


    /// @notice Enters into a vault position, borrowing from Notional if required.
    /// @param vaultAccount vault account entering the position
    /// @param vaultConfig vault configuration
    /// @param maturity maturity to enter into
    /// @param fCashToBorrow a positive amount of fCash to borrow, will be converted to a negative
    /// amount inside the method
    /// @param maxBorrowRate the maximum annualized interest rate to borrow at, a zero signifies no
    /// slippage limit applied
    /// @param vaultData arbitrary data to be passed to the vault
    /// @param strategyTokenDeposit some amount of strategy tokens from a previous maturity that will
    /// be carried over into the current maturity
    /// @param additionalUnderlyingExternal some amount of underlying tokens that have been deposited
    /// during enterVault as additional collateral.
    /// @return strategyTokensAdded the total strategy tokens added to the maturity for the account,
    /// including any strategy tokens transferred during a roll or settle
    function borrowAndEnterVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 maturity,
        uint256 fCashToBorrow,
        uint32 maxBorrowRate,
        bytes calldata vaultData,
        uint256 strategyTokenDeposit,
        uint256 additionalUnderlyingExternal
    ) internal returns (uint256 strategyTokensAdded) {
        // The vault account can only be increasing their borrow position or not have one set. If they
        // are increasing their position they must be borrowing from the same maturity.
        require(vaultAccount.maturity == maturity || vaultAccount.fCash == 0);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, maturity);

        // Borrows fCash and puts the cash balance into the vault account's temporary cash balance
        if (fCashToBorrow > 0) {
            _borrowIntoVault(
                vaultAccount,
                vaultConfig,
                vaultState,
                maturity,
                fCashToBorrow.toInt().neg(),
                maxBorrowRate
            );
        } else {
            // Ensure that the maturity is a valid one if we are not borrowing (borrowing will fail)
            // against an invalid market.
            VaultConfiguration.checkValidMaturity(
                vaultConfig.borrowCurrencyId,
                maturity,
                vaultConfig.maxBorrowMarketIndex,
                block.timestamp
            );
        }

        // Sets the maturity on the vault account, deposits tokens into the vault, and updates the vault state 
        strategyTokensAdded = vaultState.enterMaturity(
            vaultAccount, vaultConfig, strategyTokenDeposit, additionalUnderlyingExternal, vaultData
        );
        vaultAccount.lastEntryBlockHeight = block.number;
        setVaultAccount(vaultAccount, vaultConfig);

        vaultConfig.checkCollateralRatio(vaultState, vaultAccount);
    }

    ///  @notice Borrows fCash to enter a vault and pays fees
    ///  @dev Updates vault fCash in storage, updates vaultAccount in memory
    ///  @param vaultAccount the account's position in the vault
    ///  @param vaultConfig configuration for the given vault
    ///  @param maturity the maturity to enter for the vault
    ///  @param fCash amount of fCash to borrow from the market, must be negative
    ///  @param maxBorrowRate maximum annualized rate to pay for the borrow
    function _borrowIntoVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 maturity,
        int256 fCash,
        uint32 maxBorrowRate
    ) private {
        require(fCash < 0); // dev: fcash must be negative

        int256 assetCashBorrowed = VaultConfiguration.executeTrade(
            vaultConfig.borrowCurrencyId,
            maturity,
            fCash,
            maxBorrowRate,
            vaultConfig.maxBorrowMarketIndex,
            block.timestamp
        );
        require(assetCashBorrowed > 0, "Borrow failed");

        updateAccountfCash(vaultAccount, vaultConfig, vaultState, fCash, assetCashBorrowed);

        // Ensure that we are above the minimum borrow size. Accounts smaller than this are not profitable
        // to unwind if we need to liquidate.
        require(vaultConfig.minAccountBorrowSize <= vaultAccount.fCash.neg(), "Min Borrow");

        // Will reduce the tempCashBalance based on the assessed vault fee
        vaultConfig.assessVaultFees(vaultAccount, assetCashBorrowed, maturity, block.timestamp);
    }

    /// @notice Allows an account to exit a vault term prematurely by lending fCash.
    /// @param vaultAccount the account's position in the vault
    /// @param vaultConfig configuration for the given vault
    /// @param fCash amount of fCash to lend from the market, must be positive and cannot
    /// lend more than the account's debt
    /// @param minLendRate minimum rate to lend at
    /// @param blockTime current block time
    function lendToExitVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 fCash,
        uint32 minLendRate,
        uint256 blockTime
    ) internal {
        // Don't allow the vault to lend to positive fCash
        require(vaultAccount.fCash.add(fCash) <= 0); // dev: cannot lend to positive fCash
        
        // Check that the account is in an active vault
        require(blockTime < vaultAccount.maturity);
        
        // Returns the cost in asset cash terms as a negative value to lend an offsetting fCash position
        // so that the account can exit.
        int256 assetCashCostToLend = VaultConfiguration.executeTrade(
            vaultConfig.borrowCurrencyId,
            vaultAccount.maturity,
            fCash,
            minLendRate,
            vaultConfig.maxBorrowMarketIndex,
            blockTime
        );

        if (assetCashCostToLend == 0) {
            // In this case, the lending has failed due to a lack of liquidity or negative interest rates. In this
            // case just just net off the the asset cash balance and the account will forgo any money market interest
            // accrued between now and maturity.
            
            // If this scenario were to occur, it is most likely that interest rates are near zero suggesting that
            // money market interest rates are also near zero (therefore the account is really not giving up much
            // by forgoing money market interest).
            // NOTE: fCash is positive here so assetCashToLend will be negative
            assetCashCostToLend = vaultConfig.assetRate.convertFromUnderlying(fCash).neg();
        }
        require(assetCashCostToLend <= 0);

        updateAccountfCash(vaultAccount, vaultConfig, vaultState, fCash, assetCashCostToLend);
        // NOTE: vault account and vault state are not set into storage in this method.
    }
    
    function depositForRollPosition(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 depositAmountExternal
    ) internal {
        (Token memory assetToken, Token memory underlyingToken) = vaultConfig.getTokens();
        uint256 amountTransferred;
        if (underlyingToken.tokenType == TokenType.Ether) {
            require(depositAmountExternal == msg.value, "Invalid ETH");
            amountTransferred = msg.value;
        } else {
            amountTransferred = underlyingToken.transfer(
                vaultAccount.account, vaultConfig.borrowCurrencyId, depositAmountExternal.toInt()
            ).toUint();
        }

        int256 assetCashExternal;
        if (assetToken.tokenType == TokenType.NonMintable) {
            assetCashExternal = amountTransferred.toInt();
        } else if (amountTransferred > 0) {
            assetCashExternal = assetToken.mint(vaultConfig.borrowCurrencyId, amountTransferred);
        }
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
            assetToken.convertToInternal(assetCashExternal)
        );
    }

    /// @notice Calculates the amount a liquidator can deposit in asset cash terms to deleverage an account.
    /// @param vaultAccount the vault account to deleverage
    /// @param vaultConfig the vault configuration
    /// @param vaultShareValue value of the vault account's vault shares
    /// @return maxLiquidatorDepositAssetCash the maximum a liquidator can deposit in asset cash internal denomination
    /// @return debtOutstandingAboveMinBorrow used to determine the threshold at which a liquidator must liquidate an account
    /// to zero to account for minimum borrow sizes
    function calculateDeleverageAmount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        int256 vaultShareValue
    ) internal pure returns (
        int256 maxLiquidatorDepositAssetCash,
        int256 debtOutstandingAboveMinBorrow
    ) {
        // In the base case, the liquidator can deleverage an account up to maxDeleverageCollateralRatio, this
        // assures that a liquidator cannot over-purchase assets on an account.
        int256 maxCollateralRatioPlusOne = vaultConfig.maxDeleverageCollateralRatio.add(Constants.RATE_PRECISION);

        // All calculations in this method are done in asset cash denomination
        int256 debtOutstanding = vaultConfig.assetRate.convertFromUnderlying(vaultAccount.fCash.neg());

        // The post liquidation collateral ratio is calculated as:
        //                          (shareValue - (debtOutstanding - deposit * (1 - liquidationRate)))
        //   postLiquidationRatio = ----------------------------------------------------------------
        //                                          (debtOutstanding - deposit)
        //
        //   if we rearrange terms to put the deposit on one side we get:
        //
        //              (postLiquidationRatio + 1) * debtOutstanding - shareValue
        //   deposit =  ---------------------------------------------------------- 
        //                  (postLiquidationRatio + 1) - liquidationRate

        maxLiquidatorDepositAssetCash = (
            debtOutstanding.mulInRatePrecision(maxCollateralRatioPlusOne).sub(vaultShareValue)
        // Both denominators are in 1e9 precision
        ).divInRatePrecision(maxCollateralRatioPlusOne.sub(vaultConfig.liquidationRate));

        // If an account's (debtOutstanding - maxLiquidatorDeposit) < minAccountBorrowSize it may not be profitable
        // to liquidate a second time due to gas costs. If this occurs the liquidator must liquidate the account
        // such that it has no fCash debt.
        int256 postLiquidationDebtRemaining = debtOutstanding.sub(maxLiquidatorDepositAssetCash);
        int256 minAccountBorrowSizeAssetCash = vaultConfig.assetRate.convertFromUnderlying(
            vaultConfig.minAccountBorrowSize
        );
        debtOutstandingAboveMinBorrow = debtOutstanding.sub(minAccountBorrowSizeAssetCash);

        // All terms here are in asset cash
        if (postLiquidationDebtRemaining < minAccountBorrowSizeAssetCash) {
            // If the postLiquidationDebtRemaining is negative (over liquidation) or below the minAccountBorrowSize
            // set the max deposit amount to set the fCash debt to zero.
            maxLiquidatorDepositAssetCash = debtOutstanding;
        }

        // Check that the maxLiquidatorDepositAssetCash does not exceed the total vault shares owned by
        // the account:
        //      vaultSharesToLiquidator = vaultShares * [(deposit * liquidationRate) / (vaultShareValue * RATE_PRECISION)]
        //
        // if (deposit * liquidationRate) / vaultShareValue > RATE_PRECISION then the account may be insolvent (or unable
        // to reach the maxDeleverageCollateralRatio) and we are over liquidating. In this case the liquidator's max deposit is
        //      (deposit * liquidationRate) / vaultShareValue == RATE_PRECISION, therefore:
        //      deposit = (RATE_PRECISION * vaultShareValue / liquidationRate)
        int256 depositRatio = maxLiquidatorDepositAssetCash.mul(vaultConfig.liquidationRate).div(vaultShareValue);

        // Use equal to so we catch potential off by one issues, the deposit amount calculated inside the if statement
        // below will round the maxLiquidatorDepositAssetCash down
        if (depositRatio >= Constants.RATE_PRECISION) {
            maxLiquidatorDepositAssetCash = vaultShareValue.divInRatePrecision(vaultConfig.liquidationRate);
        }
    }

    /// @notice Settles a vault account that has a position in a matured vault.
    /// @param vaultAccount the account's position in the vault
    /// @param vaultConfig configuration for the given vault
    /// @param blockTime current block time
    /// @return strategyTokenClaim the amount of strategy tokens the account has left over
    function settleVaultAccount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal returns (uint256 strategyTokenClaim) {
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, vaultAccount.maturity);
        require(vaultState.isSettled, "Not Settled");

        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            vaultAccount.maturity,
            blockTime
        );

        // Value of all strategy tokens at a snapshot price from settlement. The current spot price may be
        // different but the spot price will be irrelevant post settlement. Settlement prices should be oracle
        // prices and should not be manipulate-able via flash loans. This is a requirement in strategy vault design.
        // Even if the settlement price was manipulated, it's not clear how it would be used to anyone's advantage
        // here since all accounts in the pool will face the same price.
        int256 totalStrategyTokenValueAtSettlement = vaultState.totalStrategyTokens.toInt()
            .mul(vaultState.settlementStrategyTokenValue)
            .div(Constants.INTERNAL_TOKEN_PRECISION);

        int256 totalAccountValue = _getTotalAccountValueAtSettlement(
            vaultAccount,
            vaultState,
            vaultConfig,
            settlementRate,
            totalStrategyTokenValueAtSettlement
        );

        // Returns the asset cash and strategy token claims the account has on the settled maturity
        int256 assetCashClaim;
        (assetCashClaim, strategyTokenClaim) = _getAccountClaimsOnSettledMaturity(
            vaultConfig,
            vaultState,
            settlementRate,
            totalAccountValue,
            totalStrategyTokenValueAtSettlement
        );

        // Update the vault account in memory
        vaultAccount.fCash = 0;
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(assetCashClaim);
        vaultAccount.vaultShares = 0;
        vaultAccount.maturity = 0;
    }

    /// @notice Returns the total account value at settlement
    function _getTotalAccountValueAtSettlement(
        VaultAccount memory vaultAccount, 
        VaultState memory vaultState, 
        VaultConfig memory vaultConfig,
        AssetRateParameters memory settlementRate,
        int256 totalStrategyTokenValueAtSettlement
    ) private returns (int256 totalAccountValue) {
        // This is the total value of all vault shares at settlement as the sum of cash and strategy token
        // assets held in the vault maturity using prices snapshot at settlement. Any future prices changes
        // on these assets will not be relevant in our calculations so there is no incentive to "game" when
        // users settle their positions.
        int256 totalVaultShareValueAtSettlement = totalStrategyTokenValueAtSettlement
            .add(settlementRate.convertToUnderlying(vaultState.totalAssetCash.toInt()));

        // If there are secondary borrow currencies, adjust the totalVaultShareValue and the totalAccountValue
        // accordingly. vaultShareValue will increase as a function of the totalfCashBorrowed prior to settlement
        // and each account's value will decrease in accordance with the secondary fCash they owed.
        if (vaultConfig.hasSecondaryBorrows()) {
            VaultAccountSecondaryDebtShareStorage storage s = 
                LibStorage.getVaultAccountSecondaryDebtShare()[vaultAccount.account][vaultConfig.vault];
            
            int256 vaultShareValueAdjustment;
            int256 accountValueAdjustment;
            (vaultShareValueAdjustment, accountValueAdjustment) = _getSecondaryBorrowAdjustment(
                vaultConfig.vault,
                vaultState.maturity,
                vaultConfig.secondaryBorrowCurrencies[0],
                s.accountDebtSharesOne
            );
            totalVaultShareValueAtSettlement = totalVaultShareValueAtSettlement.add(vaultShareValueAdjustment);
            totalAccountValue = totalAccountValue.sub(accountValueAdjustment);
            
            (vaultShareValueAdjustment, accountValueAdjustment) = _getSecondaryBorrowAdjustment(
                vaultConfig.vault,
                vaultState.maturity,
                vaultConfig.secondaryBorrowCurrencies[1],
                s.accountDebtSharesTwo
            );
            totalVaultShareValueAtSettlement = totalVaultShareValueAtSettlement.add(vaultShareValueAdjustment);
            totalAccountValue = totalAccountValue.sub(accountValueAdjustment);

            // Clear secondary all secondary borrow storage , these debt counters are no longer relevant
            // after accounting for the adjustment
            delete LibStorage.getVaultAccountSecondaryDebtShare()[vaultAccount.account][vaultConfig.vault];
        }

        // The account's value at settlement is used to determine how much resulting shares of cash and
        // strategy tokens it is allowed to withdraw from the pool of assets.
        // totalAccountValue = vaultShares * settlementVaultShareValue + fCash (fCash is negative)
        //      + secondaryBorrowAdjustments (negative)
        totalAccountValue = 
            totalAccountValue.add(
                vaultAccount.vaultShares.toInt().mul(totalVaultShareValueAtSettlement)
                    .div(vaultState.totalVaultShares.toInt())
                .add(vaultAccount.fCash)
            );

        // If the total account value is negative than it is insolvent at settlement. This can happen if
        // the vault as a whole has repaid its debts but one of the accounts in the vault does not have
        // sufficient assets to repay its share of debts. If that account is attempting to settle (unlikely),
        // then clear its claims on the pool and attempt to recover the cash balance from the account by marking
        // it on the temporary cash balance. If the account is attempting to exit, it will be unable to redeem
        // any strategy tokens (there would be no claim) and then the protocol would attempt to transfer tokens
        // from the account. If the account is attempting to enter, this insolvency would be net off against any
        // borrowing or deposits. An account cannot roll with a matured position.
        if (totalAccountValue < 0) {
            vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
                settlementRate.convertFromUnderlying(totalAccountValue)
            );
            totalAccountValue = 0;
        }
    }
    
    function _getSecondaryBorrowAdjustment(
        address vault,
        uint256 maturity,
        uint16 currencyId,
        uint256 accountDebtShares
    ) internal view returns (
        int256 vaultShareValueAdjustment,
        int256 accountValueAdjustment
    ) {
        if (currencyId == 0) return (0, 0);

        VaultSecondaryBorrowStorage storage balance = 
            LibStorage.getVaultSecondaryBorrow()[vault][maturity][currencyId];
        uint256 totalfCashBorrowedInPrimary = balance.totalfCashBorrowedInPrimarySnapshot;
        uint256 totalAccountDebtShares = balance.totalAccountDebtShares;
        
        if (accountDebtShares > 0)  {
            // If accountDebtShares > 0 then totalAccountDebt shares cannot be zero so we
            // will not encounter a div by zero here.
            accountValueAdjustment = accountDebtShares
                .mul(totalfCashBorrowedInPrimary)
                .div(totalAccountDebtShares).toInt();
        }

        vaultShareValueAdjustment = int256(totalfCashBorrowedInPrimary);
    }


    /// @notice Returns the account's claims on a settled maturity. Resolves any shortfalls due to insolvent
    /// accounts within the same maturity.
    function _getAccountClaimsOnSettledMaturity(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        AssetRateParameters memory settlementRate,
        int256 totalAccountValue,
        int256 totalStrategyTokenValueAtSettlement
    ) private returns (int256 assetCashClaim, uint256 strategyTokenClaim) {
        {
            // Represents any asset cash in surplus of what is required to repay total fCash debt
            int256 residualAssetCashBalance = vaultState.totalAssetCash.toInt()
                .add(settlementRate.convertFromUnderlying(vaultState.totalfCash));
                
            // Represents the total value of the vault at settlement after repaying fCash debt
            int256 settledVaultValue = settlementRate.convertToUnderlying(residualAssetCashBalance)
                .add(totalStrategyTokenValueAtSettlement);
            
            // If the vault is insolvent (meaning residualAssetCashBalance < 0), it is necessarily
            // true that totalStrategyTokens == 0 (meaning all tokens were sold in an attempt to
            // repay the debt). That means settledVaultValue == residualAssetCashBalance, strategyTokenClaim == 0
            // and assetCashClaim == totalAccountValue. Accounts that are still solvent will be paid from the
            // reserve, accounts that are insolvent will have a totalAccountValue == 0.
            if (settledVaultValue != 0) {
                strategyTokenClaim = totalAccountValue.mul(vaultState.totalStrategyTokens.toInt())
                    .div(settledVaultValue).toUint();

                assetCashClaim = totalAccountValue.mul(residualAssetCashBalance)
                    .div(settledVaultValue);
            }
        } 

        // Decrement counters for settled assets that have been distributed, resolving any shortfalls
        // if the counters decrease to zero.
        VaultSettledAssetsStorage storage settledAssets = LibStorage.getVaultSettledAssets()
            [vaultConfig.vault][vaultState.maturity];
        uint256 remainingStrategyTokens = settledAssets.remainingStrategyTokens;
        int256 remainingAssetCash = settledAssets.remainingAssetCash;
        
        if (remainingStrategyTokens < strategyTokenClaim) {
            // If there are insufficient strategy tokens to repay the account, we convert it to a cash claim at the
            // settlement value. This is an unfortunate consequence that solvent accounts face if there is a single
            // account insolvency. The initial accounts to settle will be ok but the last account to settle will have to
            // take their profits in cash, not strategy tokens.
            assetCashClaim = assetCashClaim.add(settlementRate.convertFromUnderlying(
                (strategyTokenClaim - remainingStrategyTokens).toInt() // overflow checked above
                    .mul(vaultState.settlementStrategyTokenValue)
                    .div(Constants.INTERNAL_TOKEN_PRECISION)
            ));
            strategyTokenClaim = remainingStrategyTokens;

            // Clear the remaining strategy tokens
            remainingStrategyTokens = 0;
        } else {
            // Underflow checked above
            remainingStrategyTokens = remainingStrategyTokens - strategyTokenClaim;
        }
        // based on the logic above, we cannot underflow or overflow uint80
        settledAssets.remainingStrategyTokens = uint80(remainingStrategyTokens);
        
        // This is purely a defensive check, this should always be true based on the logic above
        require(assetCashClaim >= 0);
        // Since the assetCashClaim calculation above rounds down, there should never be a situation where the
        // assetCashClaim goes into shortfall due to a rounding error.
        if (remainingAssetCash < assetCashClaim) {
            // If remaining asset cash < 0 then we don't try to pull more cash from the reserve to cover it
            // in whole, we just pull the portion to cover what's required for this account to exit.
            int256 shortfall = remainingAssetCash > 0 ? assetCashClaim - remainingAssetCash : assetCashClaim;
            
            // It is possible that asset cash raised is not sufficient to cover the cash claim, there's nothing
            // we can do about that at this point. If there is a governance action to recover the rest of the cash
            // than the account could wait until that is completed. However, we don't revert here to allow solvent
            // accounts to withdraw whatever they can if they want to.
            int256 assetCashRaised = VaultConfiguration.resolveShortfallWithReserve(
                vaultConfig.vault, vaultConfig.borrowCurrencyId, shortfall, vaultState.maturity
            );

            if (remainingAssetCash > 0) {
                // Here the account gets what is left in the cash pool and what was raised
                assetCashClaim = remainingAssetCash.add(assetCashRaised);
                remainingAssetCash = 0;
                settledAssets.remainingAssetCash = 0;
            } else {
                // If remaining asset cash is negative then the account only gets what is raised
                assetCashClaim = assetCashRaised;
            }
        } else {
            // remainingAssetCash and assetCashClaim are always positive in this branch
            remainingAssetCash = remainingAssetCash.sub(assetCashClaim);
            settledAssets.remainingAssetCash = remainingAssetCash.toInt80();
        }

        emit VaultSettledAssetsRemaining(
            vaultConfig.vault,
            vaultState.maturity,
            remainingAssetCash,
            remainingStrategyTokens
        );
    }
}

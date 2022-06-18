// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {VaultAccount, VaultAccountStorage, TradeActionType} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {TradingAction} from "../../external/actions/TradingAction.sol";
import {DateTime} from "../markets/DateTime.sol";

import {CashGroup, CashGroupParameters, Market, MarketParameters} from "../markets/CashGroup.sol";
import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {TokenType, Token, TokenHandler, AaveHandler} from "../balances/TokenHandler.sol";

import {VaultConfig, VaultConfiguration} from "./VaultConfiguration.sol";
import {VaultStateLib, VaultState} from "./VaultState.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

library VaultAccountLib {
    using VaultConfiguration for VaultConfig;
    using VaultStateLib for VaultState;
    using AssetRate for AssetRateParameters;
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Returns a single account's vault position
    function getVaultAccount(address account, VaultConfig memory vaultConfig)
        internal
        view
        returns (VaultAccount memory vaultAccount)
    {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultConfig.vault];

        // fCash is negative on the stack
        vaultAccount.fCash = -int256(uint256(s.fCash));
        vaultAccount.maturity = s.maturity;
        vaultAccount.vaultShares = s.vaultShares;
        vaultAccount.account = account;
        vaultAccount.tempCashBalance = 0;
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
        // accounts that become insolvent or require manual settlements which will require expensive
        // transactions.
        require(vaultAccount.fCash == 0 || vaultConfig.minAccountBorrowSize <= vaultAccount.fCash.neg(), "Min Borrow");

        s.fCash = vaultAccount.fCash.neg().toUint().toUint80();
        s.vaultShares = vaultAccount.vaultShares.toUint80();
        s.maturity = vaultAccount.maturity.toUint32();
    }

    /**
     * @notice Settles a vault account that has a position in a matured vault.
     * @param vaultAccount the account's position in the vault
     * @param vaultConfig configuration for the given vault
     * @param blockTime current block time
     * @return strategyTokenClaim the amount of strategy tokens the account has left over
     */
    function settleVaultAccount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal returns (uint256) {
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

        int256 accountShareOfSettledPool = _getAccountShareOfSettledPool(
            vaultAccount,
            vaultState,
            settlementRate,
            totalStrategyTokenValueAtSettlement
        );

        // Calculate the amount of strategy tokens and cash the account has a claim over. In order to do
        // this we calculate two factors to determine the proportional claims of the account.
        //   - residualAssetCashBalance is any asset cash above what is required to repay the
        //     totalfCash debt. All accounts have a proportional claim on this relative to their value at
        //     settlement.
        //
        //       residualAssetCashBalance = totalAssetCash - totalfCash
        //
        //   - settledUnderlyingValue is the post settlement value of the vault. This is the total amount of
        //     value that accounts can withdraw after settlement.
        //
        //       settledUnderlyingValue = totalAssetCash - totalfCash + strategyTokenValue
    
        int256 residualAssetCashBalance = vaultState.totalAssetCash.toInt()
            .add(settlementRate.convertFromUnderlying(vaultState.totalfCash));
            
        int256 settledUnderlyingValue = settlementRate.convertToUnderlying(residualAssetCashBalance)
            .add(totalStrategyTokenValueAtSettlement);
        
        int256 strategyTokenClaim = accountShareOfSettledPool
            .mul(vaultState.totalStrategyTokens.toInt())
            .div(settledUnderlyingValue);

        int256 cashClaim = accountShareOfSettledPool.mul(residualAssetCashBalance).div(settledUnderlyingValue);

        // Update the vault account in memory
        vaultAccount.fCash = 0;
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(cashClaim);
        vaultAccount.vaultShares = 0;
        vaultAccount.maturity = 0;

        // NOTE: we do not update vault state after it is settled since the totalStrategyToken
        // and totalAssetCash values we use in this calculation should be snapshots of the state
        // at settlement. The vault account is cleared of its positions. If exiting, the vault will
        // redeem all of its strategyTokens to its temp cash balance. If entering, the strategyTokenClaim
        // will be deposited into the target maturity.
        return strategyTokenClaim.toUint();
    }

    function _getAccountShareOfSettledPool(
        VaultAccount memory vaultAccount, 
        VaultState memory vaultState, 
        AssetRateParameters memory settlementRate,
        int256 totalStrategyTokenValueAtSettlement
    ) private pure returns (int256 accountShareOfSettledPool) {
        // This is the total value of all vault shares at settlement as the sum of cash and strategy token
        // assets held in the vault share pool using prices snapshot at settlement. Any future prices changes
        // on these assets will not be relevant in our calculations so there is no incentive to "game" when
        // users settle their positions.

        int256 settlementVaultShareValue = totalStrategyTokenValueAtSettlement
            .add(settlementRate.convertToUnderlying(vaultState.totalAssetCash.toInt()));

        // The account's share of the settled pool is used to determine how much resulting shares of cash
        // and strategy tokens it is allowed to withdraw from the pool of assets.
        // accountShareOfSettledPool = vaultShares * settlementVaultShareValue + fCash (fCash is negative)
        accountShareOfSettledPool = 
            vaultAccount.vaultShares.toInt().mul(settlementVaultShareValue)
                .div(vaultState.totalVaultShares.toInt())
            .add(vaultAccount.fCash);

        // TODO: re-examine this....
        // The only way for an account value to be negative here is due to a protocol insolvency where
        // the maturity has been settled but there is not enough cash to repay the debts. In this case,
        // there would be no strategy tokens remaining and so an insolvent account would not have a sufficient
        // share of asset cash to net off its debts. Add this insolvency to the account's temp cash balance
        // and zero out the value at settlement. If the account is attempting to enter or exit the vault,
        // this will net off their insolvency against any deposit (attempt to have the account repay their
        // own insolvency).
        if (accountShareOfSettledPool < 0) {
            vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
                settlementRate.convertFromUnderlying(accountShareOfSettledPool)
            );
            accountShareOfSettledPool = 0;
        }
    }

    function borrowAndEnterVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 maturity,
        uint256 fCashToBorrow,
        uint32 maxBorrowRate,
        bytes calldata vaultData,
        uint256 strategyTokenDeposit
    ) internal {
        // The vault account can only be increasing their borrow position or not have one set. If they
        // are increasing their position they will be in the current maturity. We won't update the
        // maturity in this method, it will be updated when we enter the maturity pool at the end
        // of the parent method borrowAndEnterVault
        require(vaultAccount.maturity == maturity || vaultAccount.fCash == 0);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, maturity);

        // Borrows fCash and puts the cash balance into the vault account's temporary cash balance
        if (fCashToBorrow > 0) {
            _borrowIntoVault(
                vaultAccount,
                vaultConfig,
                vaultState,
                maturity,
                SafeInt256.toInt(fCashToBorrow).neg(),
                maxBorrowRate,
                block.timestamp
            );
        }

        // Migrates the account from its old pool to the new pool if required, updates the current
        // pool and deposits asset tokens into the vault
        vaultState.enterMaturityPool(vaultAccount, vaultConfig, strategyTokenDeposit, vaultData);

        // Set the vault state and account in storage and check the vault's collateral ratio
        vaultState.setVaultState(vaultConfig.vault);
        setVaultAccount(vaultAccount, vaultConfig);
        // If the account is not using any leverage (fCashToBorrow == 0) we don't check the collateral ratio, no matter
        // what the amount is the collateral ratio will increase. This is useful for accounts that want to quickly and cheaply
        // deleverage their account without paying down debts.
        if (fCashToBorrow > 0) {
            vaultConfig.checkCollateralRatio(vaultState, vaultAccount.vaultShares, vaultAccount.fCash);
        }
    }

    /**
     * @notice Borrows fCash to enter a vault, checks the collateral ratio and pays the nToken fee
     * @dev Updates vault fCash in storage, updates vaultAccount in memory
     * @param vaultAccount the account's position in the vault
     * @param vaultConfig configuration for the given vault
     * @param maturity the maturity to enter for the vault
     * @param fCash amount of fCash to borrow from the market, must be negative
     * @param maxBorrowRate maximum annualized rate to pay for the borrow
     * @param blockTime current block time
     */
    function _borrowIntoVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 maturity,
        int256 fCash,
        uint32 maxBorrowRate,
        uint256 blockTime
    ) private {
        require(fCash < 0); // dev: fcash must be negative

        int256 assetCashBorrowed  = executeTrade(
            vaultConfig.borrowCurrencyId,
            maturity,
            fCash,
            maxBorrowRate,
            vaultConfig.maxBorrowMarketIndex,
            blockTime
        );
        require(assetCashBorrowed > 0, "Borrow failed");

        updateAccountfCash(vaultAccount, vaultConfig, vaultState, fCash, assetCashBorrowed);

        // Ensure that we are above the minimum borrow size. Accounts smaller than this are not profitable
        // to unwind if we need to liquidate.
        require(vaultConfig.minAccountBorrowSize <= vaultAccount.fCash.neg(), "Min Borrow");

        // Will reduce the tempCashBalance based on the assessed vault fee
        uint256 timeToMaturity = maturity.sub(blockTime);
        vaultConfig.assessVaultFees(vaultAccount, fCash, timeToMaturity);
    }

    /**
     * @notice Allows an account to exit a vault term prematurely by lending fCash.
     * @dev Updates vault fCash in storage, updates vaultAccount in memory.
     * @param vaultAccount the account's position in the vault
     * @param vaultConfig configuration for the given vault
     * @param fCash amount of fCash to lend from the market, must be positive and cannot
     * lend more than the account's debt
     * @param minLendRate minimum rate to lend at
     * @param blockTime current block time
     */
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
        
        // Returns the cost in asset cash terms to lend an offsetting fCash position
        // so that the account can exit. assetCashRequired is negative here.
        int256 assetCashCostToLend  = executeTrade(
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
            assetCashCostToLend = vaultConfig.assetRate.convertFromUnderlying(fCash).neg(); // this is a negative number
        }
        require(assetCashCostToLend <= 0);

        updateAccountfCash(vaultAccount, vaultConfig, vaultState, fCash, assetCashCostToLend);
    }

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
        vaultState.totalfCash = vaultState.totalfCash.add(netfCash);

        // Updates the total borrow capacity
        VaultConfiguration.updateUsedBorrowCapacity(vaultConfig.vault, vaultConfig.borrowCurrencyId, netfCash);
    }

    function calculateDeleverageAmount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        int256 vaultShareValue
    ) internal view returns (int256 maxLiquidatorDepositAssetCash, bool mustLiquidateFullAmount) {
        // In the base case, the liquidator can deleverage an account up to minCollateralRatio * VAULT_DELEVERAGE_LIMIT
        // which is a constant value. This assures that a liquidator cannot over-purchase assets on an account.
        int256 maxCollateralRatioPlusOne = vaultConfig.maxDeleverageCollateralRatio.add(Constants.RATE_PRECISION);

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

        // If an account's debtOutstanding - maxLiquidatorDeposit < maxAccountBorrowSize it may not be profitable to liquidate
        // a second time. If this occurs at the VAULT_DELEVERAGE_LIMIT then the liquidator must liquidate the account such that
        // it has no net fCash debt.
        int256 postLiquidationDebtRemaining = debtOutstanding.sub(maxLiquidatorDepositAssetCash);
        int256 minAccountBorrowSizeAssetCash = vaultConfig.assetRate.convertFromUnderlying(
            vaultConfig.minAccountBorrowSize
        );

        if (postLiquidationDebtRemaining < minAccountBorrowSizeAssetCash) {
            // If the postLiquidationDebtRemaining is negative (over liquidation) or below the minAccountBorrowSize set the
            // max deposit amount to set the fCash debt to zero.
            maxLiquidatorDepositAssetCash = debtOutstanding;
            mustLiquidateFullAmount = true;
        }
    }

    /**
     * @notice Executes a trade on the AMM.
     * @param currencyId id of the vault borrow currency
     * @param maturity maturity to lend or borrow at
     * @param netfCashToAccount positive if lending, negative if borrowing
     * @param rateLimit 0 if there is no limit, otherwise is a slippage limit
     * @param blockTime current time
     * @return netAssetCash amount of cash to credit to the account
     */
    function executeTrade(
        uint16 currencyId,
        uint256 maturity,
        int256 netfCashToAccount,
        uint32 rateLimit,
        uint256 maxBorrowMarketIndex,
        uint256 blockTime
    ) internal returns (int256 netAssetCash) {
        uint8 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        require(maxMarketIndex <= maxBorrowMarketIndex); // @dev: cannot borrow past market index
        (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(maxMarketIndex, maturity, blockTime);
        require(!isIdiosyncratic);

        // fCash is restricted from being larger than uint88 inside the trade module
        uint256 fCashAmount = uint256(netfCashToAccount.abs());
        require(fCashAmount < type(uint88).max);

        // Encodes trade data for the TradingAction module
        bytes32 trade = bytes32(
            (uint256(uint8(netfCashToAccount > 0 ? TradeActionType.Lend : TradeActionType.Borrow)) << 248) |
            (uint256(marketIndex) << 240) |
            (uint256(fCashAmount) << 152) |
            (uint256(rateLimit) << 120)
        );

        // Use the library here to reduce the deployed bytecode size
        netAssetCash = TradingAction.executeVaultTrade(currencyId, trade);
    }

    /**
     * @notice Deposits a specified amount from the account
     * @param vaultAccount vault account object
     * @param transferFrom address to transfer the tokens from
     * @param borrowCurrencyId the currency id to transfer
     * @param _depositAmountExternal the amount to deposit in external precision
     * @param useUnderlying if true then use the underlying token
     */
    function depositIntoAccount(
        VaultAccount memory vaultAccount,
        address transferFrom,
        uint16 borrowCurrencyId,
        uint256 _depositAmountExternal,
        bool useUnderlying
    ) internal {
        if (_depositAmountExternal == 0) return;
        int256 depositAmountExternal = SafeInt256.toInt(_depositAmountExternal);

        Token memory assetToken = TokenHandler.getAssetToken(borrowCurrencyId);
        int256 assetAmountExternal;

        if (useUnderlying) {
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(borrowCurrencyId);
            // This is the actual amount of underlying transferred
            int256 underlyingAmountExternal = underlyingToken.transfer(
                transferFrom,
                borrowCurrencyId,
                depositAmountExternal
            );

            // This is the actual amount of asset tokens minted
            assetAmountExternal = assetToken.mint(
                borrowCurrencyId,
                SafeInt256.toUint(underlyingAmountExternal)
            );
        } else {
            if (assetToken.tokenType == TokenType.aToken) {
                // Handles special accounting requirements for aTokens
                depositAmountExternal = AaveHandler.convertToScaledBalanceExternal(
                    borrowCurrencyId,
                    depositAmountExternal
                );
            }

            assetAmountExternal = assetToken.transfer(
                transferFrom,
                borrowCurrencyId,
                depositAmountExternal
            );
        }

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
            assetToken.convertToInternal(assetAmountExternal)
        );
    }

    /**
     * @notice Transfers into and out of an account's temporary cash balance
     * @param vaultAccount vault account object
     * @param vaultConfig the current vault configuration
     * @param useUnderlying if true then use the underlying token
     */
    function transferTempCashBalance(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        bool useUnderlying
    ) internal {
        uint16 borrowCurrencyId = vaultConfig.borrowCurrencyId;
        Token memory assetToken = TokenHandler.getAssetToken(borrowCurrencyId);
        // If tempCashBalance > 0 then we want to transfer it back to the user, and the netTransferAmount will be < 0,
        // considered from the Notional perspective.
        // If tempCashBalance < 0 then we want to pull tokens from the account and then netTransferAmount will be > 0,
        // considered from the Notional perspective.
        int256 netTransferAmountExternal = assetToken.convertToExternal(vaultAccount.tempCashBalance.neg());

        if (netTransferAmountExternal < 0) {
            if (useUnderlying) {
                assetToken.redeem(borrowCurrencyId, vaultAccount.account, SafeInt256.toUint(netTransferAmountExternal.neg()));
            } else {
                assetToken.transfer(vaultAccount.account, borrowCurrencyId, netTransferAmountExternal);
            }
            vaultAccount.tempCashBalance = 0;
        } else {
            int256 dustLimit = 0;
            if (useUnderlying) {
                Token memory underlyingToken = TokenHandler.getUnderlyingToken(borrowCurrencyId);
                netTransferAmountExternal = underlyingToken.convertToUnderlyingExternalWithAdjustment(
                    vaultConfig.assetRate.convertToUnderlying(vaultAccount.tempCashBalance.neg())
                );

                // There is the possibility of dust values accruing when using underlying tokens to
                // deposit into the protocol due to rounding issues between native token precision and
                // Notional 8 decimal internal precision.
                // TODO: provide some more analysis and justification here
                if (underlyingToken.decimals < Constants.INTERNAL_TOKEN_PRECISION) {
                    dustLimit = 10_000;
                } else {
                    dustLimit = 100;
                }
            }

            depositIntoAccount(
                vaultAccount,
                vaultAccount.account,
                borrowCurrencyId,
                netTransferAmountExternal.toUint(),
                useUnderlying
            );

            // Any dust cleared here will accrue to the protocol, it will always be greater than zero
            // meaning that the protocol will never lose cash as a result.
            require(0 <= vaultAccount.tempCashBalance && vaultAccount.tempCashBalance <= dustLimit);
            vaultAccount.tempCashBalance = 0;
        }
    }
}

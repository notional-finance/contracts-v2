// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    MarketParameters,
    Token,
    CashGroupParameters,
    nTokenPortfolio,
    AccountContext,
    BalanceState,
    TradeActionType,
    InterestRateParameters,
    PrimeCashFactors
} from "../global/Types.sol";
import {StorageLayoutV1} from "../global/StorageLayoutV1.sol";
import {Constants} from "../global/Constants.sol";
import {SafeInt256} from "../math/SafeInt256.sol";
import {SafeUint256} from "../math/SafeUint256.sol";

import {AccountContextHandler} from "../internal/AccountContextHandler.sol";
import {BalanceHandler} from "../internal/balances/BalanceHandler.sol";
import {TokenHandler} from "../internal/balances/TokenHandler.sol";
import {Incentives} from "../internal/balances/Incentives.sol";
import {Market} from "../internal/markets/Market.sol";
import {CashGroup} from "../internal/markets/CashGroup.sol";
import {DateTime} from "../internal/markets/DateTime.sol";
import {InterestRateCurve} from "../internal/markets/InterestRateCurve.sol";
import {PrimeRateLib} from "../internal/pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../internal/pCash/PrimeCashExchangeRate.sol";
import {nTokenSupply} from "../internal/nToken/nTokenSupply.sol";
import {nTokenHandler} from "../internal/nToken/nTokenHandler.sol";
import {nTokenCalculations} from "../internal/nToken/nTokenCalculations.sol";
import {AssetHandler} from "../internal/valuation/AssetHandler.sol";

import {MigrateIncentives} from "./MigrateIncentives.sol";
import {nTokenMintAction} from "./actions/nTokenMintAction.sol";
import {NotionalCalculations} from "../../interfaces/notional/NotionalCalculations.sol";

contract CalculationViews is StorageLayoutV1, NotionalCalculations {
    using TokenHandler for Token;
    using Market for MarketParameters;
    using PrimeRateLib for PrimeRate;
    using CashGroup for CashGroupParameters;
    using nTokenHandler for nTokenPortfolio;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    function _checkValidCurrency(uint16 currencyId) internal view {
        require(0 < currencyId && currencyId <= maxCurrencyId, "Invalid currency id");
    }

    /** General Calculation View Methods **/

    /// @notice Returns the nTokens that will be minted when some amount of asset tokens are deposited
    /// @param currencyId id number of the currency
    /// @param amountToDepositExternalPrecision amount of underlying tokens in native precision
    /// @return the amount of nTokens that will be minted
    function calculateNTokensToMint(uint16 currencyId, uint88 amountToDepositExternalPrecision)
        external
        view
        override
        returns (uint256)
    {
        _checkValidCurrency(currencyId);
        Token memory token = TokenHandler.getUnderlyingToken(currencyId);
        int256 amountToDepositInternal = token.convertToInternal(int256(amountToDepositExternalPrecision));
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioView(currencyId);

        int256 tokensToMint = nTokenMintAction.calculateTokensToMint(
            nToken,
            nToken.cashGroup.primeRate.convertFromUnderlying(amountToDepositInternal),
            block.timestamp
        );

        return tokensToMint.toUint();
    }

    /// @notice Returns the present value of the nToken's assets denominated in asset tokens
    function nTokenPresentValueAssetDenominated(uint16 currencyId) external view override returns (int256) {
        (int256 totalPrimePV, /* */) = _getNTokenPV(currencyId);
        return totalPrimePV;
    }

    /// @notice Returns the present value of the nToken's assets denominated in underlying
    function nTokenPresentValueUnderlyingDenominated(uint16 currencyId) external view override returns (int256) {
        (int256 totalPrimePV, nTokenPortfolio memory nToken) = _getNTokenPV(currencyId);
        return nToken.cashGroup.primeRate.convertToUnderlying(totalPrimePV);
    }

    function _getNTokenPV(uint16 currencyId) private view returns (int256, nTokenPortfolio memory) {
        uint256 blockTime = block.timestamp;
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioView(currencyId);

        int256 totalPrimePV = nTokenCalculations.getNTokenPrimePV(nToken, blockTime);
        return (totalPrimePV, nToken);
    }

    /// @notice Returns the fCash amount to send when given a cash amount, be sure to buffer these amounts
    /// slightly because the liquidity curve is sensitive to changes in block time
    /// @param currencyId id number of the currency
    /// @param netCashToAccount denominated in underlying terms in 1e8 decimal precision,
    //// positive for borrowing, negative for lending
    /// @param marketIndex market index of the fCash market
    /// @param blockTime the block time for when the trade will be calculated
    /// @return the fCash amount from the trade, positive when lending, negative when borrowing. Always in 8 decimals.
    function getfCashAmountGivenCashAmount(
        uint16 currencyId,
        int88 netCashToAccount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view override returns (int256) {
        _checkValidCurrency(currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        return _getfCashAmountGivenCashAmount(netCashToAccount, marketIndex, blockTime, cashGroup);
    }
        
    function _getfCashAmountGivenCashAmount(
        int88 netUnderlyingToAccount,
        uint256 marketIndex,
        uint256 blockTime,
        CashGroupParameters memory cashGroup
    ) internal view returns (int256) {
        MarketParameters memory market;
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        require(market.maturity > blockTime, "Invalid block time");
        uint256 timeToMaturity = market.maturity - blockTime;
        InterestRateParameters memory irParams = InterestRateCurve.getActiveInterestRateParameters(
            cashGroup.currencyId, marketIndex
        );

        return InterestRateCurve.getfCashGivenCashAmount(
            irParams,
            market.totalfCash,
            netUnderlyingToAccount,
            cashGroup.primeRate.convertToUnderlying(market.totalPrimeCash),
            timeToMaturity
        );
    }

    /// @notice Returns the cash amount that will be traded given an fCash amount, be sure to buffer these amounts
    /// slightly because the liquidity curve is sensitive to changes in block time
    /// @param currencyId id number of the currency
    /// @param fCashAmount amount of fCash to trade, negative for borrowing, positive for lending
    /// @param marketIndex market index of the fCash market
    /// @param blockTime the block time for when the trade will be calculated
    /// @return net asset cash amount (positive for borrowing, negative for lending) in 8 decimal precision
    /// @return underlying cash amount (positive for borrowing, negative for lending) in 8 decimal precision
    function getCashAmountGivenfCashAmount(
        uint16 currencyId,
        int88 fCashAmount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view override returns (int256, int256) {
        return _getCashAmountGivenfCashAmount(currencyId, fCashAmount, marketIndex, blockTime, 0);
    }

    function _getCashAmountGivenfCashAmount(
        uint16 currencyId,
        int88 fCashAmount,
        uint256 marketIndex,
        uint256 blockTime, 
        uint256 rateLimit
    ) internal view returns (int256, int256) {
        _checkValidCurrency(currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        require(market.maturity > blockTime, "Invalid block time");
        uint256 timeToMaturity = market.maturity - blockTime;

        // prettier-ignore
        (int256 primeCash, /* int fee */) =
            InterestRateCurve.calculatefCashTrade(market, cashGroup, fCashAmount, timeToMaturity, marketIndex);

        // Check the slippage here and revert
        if (rateLimit != 0) {
            if (fCashAmount < 0) {
                // Do not allow borrows over the rate limit
                require(market.lastImpliedRate <= rateLimit, "Trade failed, slippage");
            } else {
                // Do not allow lends under the rate limit
                require(market.lastImpliedRate >= rateLimit, "Trade failed, slippage");
            }
        }

        return (primeCash, cashGroup.primeRate.convertToUnderlying(primeCash));
    }

    /// @notice Returns the claimable incentives for all nToken balances
    /// @param account The address of the account which holds the tokens
    /// @param blockTime The block time when incentives will be minted
    /// @return Incentives an account is eligible to claim
    function nTokenGetClaimableIncentives(address account, uint256 blockTime)
        external
        view
        override
        returns (uint256)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState;
        uint256 totalIncentivesClaimable;

        if (accountContext.isBitmapEnabled()) {
            balanceState.loadBalanceStateView(account, accountContext.bitmapCurrencyId, accountContext);
            if (balanceState.storedNTokenBalance > 0) {
                address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);
                (
                    /* uint256 totalSupply */,
                    uint256 accumulatedNOTEPerNToken,
                    /* uint256 lastAccumulatedTime */
                ) = nTokenSupply.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

                uint256 incentivesToClaim = Incentives.calculateIncentivesToClaim(
                    balanceState,
                    tokenAddress,
                    accumulatedNOTEPerNToken,
                    balanceState.storedNTokenBalance.toUint()
                );
                totalIncentivesClaimable = totalIncentivesClaimable.add(incentivesToClaim);
            }
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            uint16 currencyId = uint16(bytes2(currencies) & Constants.UNMASK_FLAGS);
            balanceState.loadBalanceStateView(account, currencyId, accountContext);

            if (balanceState.storedNTokenBalance > 0) {
                address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);
                (
                    /* uint256 totalSupply */,
                    uint256 accumulatedNOTEPerNToken,
                    /* uint256 lastAccumulatedTime */
                ) = nTokenSupply.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

                uint256 incentivesToClaim = Incentives.calculateIncentivesToClaim(
                    balanceState,
                    tokenAddress,
                    accumulatedNOTEPerNToken,
                    balanceState.storedNTokenBalance.toUint()
                );
                totalIncentivesClaimable = totalIncentivesClaimable.add(incentivesToClaim);
            }

            currencies = currencies << 16;
        }

        return totalIncentivesClaimable;
    }

    /// @notice Returns the present value of the given fCash amount using Notional internal oracle rates
    /// @param currencyId id number of the currency
    /// @param maturity timestamp of the fCash maturity
    /// @param notional amount of fCash notional
    /// @param blockTime the block time for when the trade will be calculated
    /// @param riskAdjusted true if haircuts and buffers should be applied to the oracle rate
    /// @return presentValue of fCash in 8 decimal precision and underlying denomination
    function getPresentfCashValue(
        uint16 currencyId,
        uint256 maturity,
        int256 notional,
        uint256 blockTime,
        bool riskAdjusted
    ) external view override returns (int256 presentValue) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupView(currencyId);
        if (riskAdjusted) {
            presentValue = AssetHandler.getRiskAdjustedPresentfCashValue(
                cg, notional, maturity, blockTime
            );
        } else {
            presentValue = AssetHandler.getPresentfCashValue(
                notional,
                maturity,
                blockTime,
                cg.calculateOracleRate(maturity, blockTime)
            );
        }
    }

    /// @notice Returns a market index value for a given maturity
    /// @param maturity an fCash maturity
    /// @param blockTime the block time for when the trade will be calculated
    /// @return marketIndex a value between 1 and 7 that represents the marketIndex (tenor)
    /// that corresponds to the maturity. Returns 0 if there is no corresponding marketIndex
    function getMarketIndex(
        uint256 maturity,
        uint256 blockTime
    ) public pure override returns (uint8 marketIndex) {
        (
            uint256 _marketIndex,
            bool isIdiosyncratic
        ) = DateTime.getMarketIndex(Constants.MAX_TRADED_MARKET_INDEX, maturity, blockTime);

        // Market Index cannot be greater than 7 by construction
        marketIndex = isIdiosyncratic ? 0 : uint8(_marketIndex);
    }

    /// @notice Returns the amount of fCash that would received if lending deposit amount.
    /// @param currencyId id number of the currency
    /// @param depositAmountExternal amount to deposit in the token's native precision. For aTokens use
    /// what is returned by the balanceOf selector (not scaledBalanceOf).
    /// @param maturity the maturity of the fCash to lend
    /// @param minLendRate the minimum lending rate (slippage protection)
    /// @param blockTime the block time for when the trade will be calculated
    /// @param useUnderlying true if specifying the underlying token, false if specifying prime cash
    /// @return fCashAmount the amount of fCash that the lender will receive
    /// @return marketIndex the corresponding market index for the lending
    /// @return encodedTrade the encoded bytes32 object to pass to batch trade
    function getfCashLendFromDeposit(
        uint16 currencyId,
        uint256 depositAmountExternal,
        uint256 maturity,
        uint32 minLendRate,
        uint256 blockTime,
        bool useUnderlying
    ) external view override returns (
        uint88 fCashAmount,
        uint8 marketIndex,
        bytes32 encodedTrade
    ) {
        marketIndex = getMarketIndex(maturity, blockTime);
        require(marketIndex > 0);

        (
            int256 underlyingInternal,
            CashGroupParameters memory cashGroup
        ) = _convertDepositAmountToUnderlyingInternal(currencyId, depositAmountExternal, useUnderlying);
        int256 fCash = _getfCashAmountGivenCashAmount(underlyingInternal.neg().toInt88(), marketIndex, blockTime, cashGroup);
        require(0 < fCash);

        (
            encodedTrade,
            fCashAmount
        ) = _encodeLendBorrowTrade(TradeActionType.Lend, marketIndex, fCash, minLendRate);
    }

    /// @notice Returns the amount of fCash that would received if lending deposit amount.
    /// @param currencyId id number of the currency
    /// @param borrowedAmountExternal amount to borrow in the token's native precision.
    /// @param maturity the maturity of the fCash to lend
    /// @param maxBorrowRate the maximum borrow rate (slippage protection). If zero then no slippage will be applied
    /// @param blockTime the block time for when the trade will be calculated
    /// @param useUnderlying true if specifying the underlying token, false if specifying prime cash
    /// @return fCashDebt the amount of fCash that the borrower will owe, this will be stored as a negative
    /// balance in Notional
    /// @return marketIndex the corresponding market index for the lending
    /// @return encodedTrade the encoded bytes32 object to pass to batch trade
    function getfCashBorrowFromPrincipal(
        uint16 currencyId,
        uint256 borrowedAmountExternal,
        uint256 maturity,
        uint32 maxBorrowRate,
        uint256 blockTime,
        bool useUnderlying
    ) external view override returns (
        uint88 fCashDebt,
        uint8 marketIndex,
        bytes32 encodedTrade
    ) {
        marketIndex = getMarketIndex(maturity, blockTime);
        require(marketIndex > 0);

        (
            int256 underlyingInternal,
            CashGroupParameters memory cashGroup
        ) = _convertDepositAmountToUnderlyingInternal(currencyId, borrowedAmountExternal, useUnderlying);
        int256 fCash = _getfCashAmountGivenCashAmount(underlyingInternal.toInt88(), marketIndex, blockTime, cashGroup);
        require(fCash < 0);

        (
            encodedTrade,
            fCashDebt
        ) = _encodeLendBorrowTrade(TradeActionType.Borrow, marketIndex, fCash, maxBorrowRate);
    }

    /// @notice Returns the amount of underlying cash and asset cash required to lend fCash. When specifying a
    /// trade, deposit either underlying or asset tokens (not both). Asset tokens tend to be more gas efficient.
    /// @param currencyId id number of the currency
    /// @param fCashAmount amount of fCash (in underlying) that will be received at maturity. Always 8 decimal precision.
    /// @param maturity the maturity of the fCash to lend
    /// @param minLendRate the minimum lending rate (slippage protection)
    /// @param blockTime the block time for when the trade will be calculated
    /// @return depositAmountUnderlying the amount of underlying tokens the lender must deposit
    /// @return depositAmountPrimeCash the amount of prime cash tokens the lender must deposit or mint
    /// @return marketIndex the corresponding market index for the lending
    /// @return encodedTrade the encoded bytes32 object to pass to batch trade
    function getDepositFromfCashLend(
        uint16 currencyId,
        uint256 fCashAmount,
        uint256 maturity,
        uint32 minLendRate,
        uint256 blockTime
    ) external view override returns (
        uint256 depositAmountUnderlying,
        uint256 depositAmountPrimeCash,
        uint8 marketIndex,
        bytes32 encodedTrade
    ) {
        marketIndex = getMarketIndex(maturity, blockTime);
        require(marketIndex > 0);
        require(fCashAmount < uint256(int256(type(int88).max)));

        int88 fCash = int88(SafeInt256.toInt(fCashAmount));
        (
            int256 primeCash,
            int256 underlyingCashInternal
        ) = _getCashAmountGivenfCashAmount(currencyId, fCash, marketIndex, blockTime, minLendRate);

        depositAmountUnderlying = _convertToAmountExternal(currencyId, underlyingCashInternal);
        depositAmountPrimeCash = primeCash.neg().toUint();
        (encodedTrade, /* */) = _encodeLendBorrowTrade(TradeActionType.Lend, marketIndex, fCash, minLendRate);
    }

    /// @notice Returns the amount of underlying cash and asset cash required to borrow fCash. When specifying a
    /// trade, choose to receive either underlying or asset tokens (not both). Asset tokens tend to be more gas efficient.
    /// @param currencyId id number of the currency
    /// @param fCashBorrow amount of fCash (in underlying) that will be received at maturity. Always 8 decimal precision.
    /// @param maturity the maturity of the fCash to lend
    /// @param maxBorrowRate the maximum borrow rate (slippage protection)
    /// @param blockTime the block time for when the trade will be calculated
    /// @return borrowAmountUnderlying the amount of underlying tokens the borrower will receive
    /// @return borrowAmountPrimeCash the amount of prime cash tokens the borrower will receive
    /// @return marketIndex the corresponding market index for the lending
    /// @return encodedTrade the encoded bytes32 object to pass to batch trade
    function getPrincipalFromfCashBorrow(
        uint16 currencyId,
        uint256 fCashBorrow,
        uint256 maturity,
        uint32 maxBorrowRate,
        uint256 blockTime
    ) external view override returns (
        uint256 borrowAmountUnderlying,
        uint256 borrowAmountPrimeCash,
        uint8 marketIndex,
        bytes32 encodedTrade
    ) {
        marketIndex = getMarketIndex(maturity, blockTime);
        require(marketIndex > 0);
        require(fCashBorrow < uint256(int256(type(int88).max)));

        int88 fCash = int88(SafeInt256.toInt(fCashBorrow).neg());
        (
            int256 primeCash,
            int256 underlyingCashInternal
        ) = _getCashAmountGivenfCashAmount(currencyId, fCash, marketIndex, blockTime, maxBorrowRate);

        borrowAmountUnderlying = _convertToAmountExternal(currencyId, underlyingCashInternal);
        borrowAmountPrimeCash = primeCash.toUint();
        (encodedTrade, /* */) = _encodeLendBorrowTrade(TradeActionType.Borrow, marketIndex, fCash, maxBorrowRate);
    }

    /// @notice Converts an prime cash balance to an external token denomination
    /// @param currencyId the currency id of the cash balance
    /// @param primeCashBalance the signed cash balance that is stored in Notional
    /// @param convertToUnderlying true if the value should be converted to underlying
    /// @return the cash balance converted to the external token denomination
    function convertCashBalanceToExternal(
        uint16 currencyId,
        int256 primeCashBalance,
        bool convertToUnderlying
    ) external view override returns (int256) {
        // Prime cash is just 1-1 with itself, no external conversion
        if (!convertToUnderlying) return primeCashBalance;

        (PrimeRate memory pr, /* */) = PrimeCashExchangeRate
            .getPrimeCashRateView(currencyId, block.timestamp);

        int256 underlyingBalance = pr.convertToUnderlying(primeCashBalance);
        int256 externalAmount = _convertToAmountExternal(currencyId, underlyingBalance.abs()).toInt();
        return underlyingBalance < 0 ? externalAmount.neg() : externalAmount;
    }

    /// @notice Converts an underlying balance to prime cash
    /// @param currencyId the currency id of the cash balance
    /// @param underlyingExternal the underlying external token balance
    /// @return the underlying balance converted to prime cash
    function convertUnderlyingToPrimeCash(
        uint16 currencyId,
        int256 underlyingExternal
    ) external view override returns (int256) {
        (PrimeRate memory pr, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, block.timestamp);
        Token memory token = TokenHandler.getUnderlyingToken(currencyId);
        int256 underlyingInternal = token.convertToInternal(underlyingExternal);
        return pr.convertFromUnderlying(underlyingInternal);
    }

    /// @notice Converts fCash to its settled prime cash value at the specified block time
    /// @param currencyId the currency id of the fCash asset
    /// @param maturity the timestamp when the fCash asset matures
    /// @param fCashBalance signed balance of fcash
    /// @param blockTime block time to convert to settled prime value, must be greater than maturity
    /// @return signedPrimeSupplyValue amount of prime cash to be received or owed to the protocol
    function convertSettledfCash(
        uint16 currencyId,
        uint256 maturity,
        int256 fCashBalance,
        uint256 blockTime
    ) external view override returns (int256 signedPrimeSupplyValue) {
        require(maturity <= blockTime);
        (PrimeRate memory pr, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);
        return pr.convertSettledfCashView(currencyId, maturity, fCashBalance, blockTime);
    }

    /// @notice Accrues prime interest and updates state up to the current block
    function accruePrimeInterest(
        uint16 currencyId
    ) external override returns (PrimeRate memory pr, PrimeCashFactors memory factors) {
        pr = PrimeRateLib.buildPrimeRateStateful(currencyId);
        factors = PrimeCashExchangeRate.getPrimeCashFactors(currencyId);
    }

    function _convertToAmountExternal(uint16 currencyId, int256 depositAmountInternal) private view returns (uint256) {
        Token memory token = TokenHandler.getUnderlyingToken(currencyId);
        int256 amountExternal = depositAmountInternal < 0 ?
            // We have to do a special rounding adjustment for underlying internal deposits from lending.
            token.convertToUnderlyingExternalWithAdjustment(depositAmountInternal.neg()) :
            token.convertToExternal(depositAmountInternal).abs();

        return SafeInt256.toUint(amountExternal);
    }

    /// @notice Converts an external deposit amount to an internal deposit amount
    function _convertDepositAmountToUnderlyingInternal(
        uint16 currencyId,
        uint256 depositAmountExternal,
        bool useUnderlying
    ) private view returns (int256 underlyingInternal, CashGroupParameters memory cashGroup) {
        int256 depositAmount = depositAmountExternal.toInt();
        cashGroup = CashGroup.buildCashGroupView(currencyId);

        if (useUnderlying) {
            Token memory token = TokenHandler.getUnderlyingToken(currencyId);
            underlyingInternal = token.convertToInternal(depositAmount);
        } else {
            // In this case, depositAmount is prime cash denominated
            underlyingInternal = cashGroup.primeRate.convertToUnderlying(depositAmount);
        }
    }

    function _encodeLendBorrowTrade(
        TradeActionType actionType,
        uint8 marketIndex,
        int256 fCash,
        uint32 slippage
    ) private pure returns (bytes32 encodedTrade, uint88 fCashAmount) {
        uint256 absfCash = uint256(fCash.abs());
        require(absfCash <= uint256(type(uint88).max));

        encodedTrade = bytes32(
            (uint256(uint8(actionType)) << 248) |
            (uint256(marketIndex) << 240) |
            (uint256(absfCash) << 152) |
            (uint256(slippage) << 120)
        );

        fCashAmount = uint88(absfCash);
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address) {
        return (address(MigrateIncentives));
    }
}
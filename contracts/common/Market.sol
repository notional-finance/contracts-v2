// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "../math/SafeUInt128.sol";
import "../math/ABDKMath64x64.sol";
import "./ExchangeRate.sol";
import "./CashGroup.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";

/**
 * Market object as represented in memory
 */
struct MarketParameters {
    // Total amount of fCash available for purchase in the market.
    int totalfCash;
    // Total amount of cash available for purchase in the market.
    int totalCurrentCash;
    // Total amount of liquidity tokens (representing a claim on liquidity) in the market.
    uint totalLiquidity;
    // These factors are set when the market is instantiated by a liquidity provider via the global
    // settings and then held constant for the duration of the maturity. We cannot change them without
    // really messing up the market rates.
    uint rateAnchor;
    // This is the implied rate that we use to smooth the anchor rate between trades.
    uint lastImpliedRate;
}

library Market {
    using SafeMath for uint;
    using SafeInt256 for int;
    using SafeUInt128 for uint128;
    using CashGroup for CashGroupParameters;
    using ExchangeRate for Rate;

    // This is a constant that represents the time period that all rates are normalized by, 360 days
    uint internal constant IMPLIED_RATE_TIME = 31104000;

    // Max positive value for a ABDK64x64 integer
    uint internal constant MAX64 = 0x7FFFFFFFFFFFFFFF;
    // Number of decimal places that rates are stored in, equals 100%
    uint internal constant RATE_PRECISION = 1e6;
    uint internal constant BASIS_POINT = RATE_PRECISION / 10000;

    // This is the ABDK64x64 representation of RATE_PRECISION
    // RATE_PRECISION_64x64 = ABDKMath64x64.fromUint(RATE_PRECISION)
    int128 internal constant RATE_PRECISION_64x64 = 0xf42400000000000000000;
    // IMPLIED_RATE_TIME_64x64 = ABDKMath64x64.fromUint(IMPLIED_RATE_TIME)
    int128 internal constant IMPLIED_RATE_TIME_64x64 = 0x1da9c000000000000000000;

   /**
    * @notice The rate anchor is the initial exchange rate that a market with an equal proportion
    * of fCash and cash will be set to. It represents the implied rate continuously compounded
    * over the time to maturity. The initial gRateAnchor value is set as a governance parameter as
    * RATE_PRECISION + implied rate. We then calculate it using time to maturity via continuous
    * compounding. The formula is:
    * math.exp((timeToMaturity / IMPLIED_RATE_TIME) * (gRateAnchor - 1))
    * 
    * @dev Rate precision is set to 1e6 and we will store rate anchors as uint40. This will support
    * rate anchors up to ~1e12. This can be intereprted as ln(1e12 / 1e6) = (implied rate) * years or
    * 13.815 ~= (implied rate) * years. For reference, at 50 years we can support interest rates up to
    * 27.6%. Over 100 years, we can support interest rates up to 13.8%.
    *
    * @return uint rateAnchor value that can be stored, limited to uint40 size
    */
   function initializeRateAnchor(uint gRateAnchor, uint timeToMaturity) internal pure returns (uint) {
       // NOTE: will need to worry about overflow at around 30 years time to maturity
       int128 numerator = ABDKMath64x64.fromUInt(gRateAnchor.sub(RATE_PRECISION).mul(timeToMaturity));
       int128 expValue = ABDKMath64x64.div(numerator, IMPLIED_RATE_TIME_64x64);
       int128 expValueScaled = ABDKMath64x64.div(expValue, RATE_PRECISION_64x64);
       int128 expResult = ABDKMath64x64.exp(expValueScaled);
       int128 expResultScaled = ABDKMath64x64.mul(expResult, RATE_PRECISION_64x64);

       uint result = ABDKMath64x64.toUInt(expResultScaled);
       require(result <= type(uint40).max, "M: rate anchor overflow");

       return result;
   }
//
//    /**
//     * @notice Does the trade calculation and returns the new market state and cash amount
//     *
//     * @param marketState the current market state
//     * @param cashGroup cash group configuration parameters
//     * @param fCashAmount the fCash amount specified
//     * @param timeToMaturity number of seconds until maturity
//     * @return (new market state, cash)
//     */
//    function _tradeCalculation(
//        Market memory marketState,
//        CashGroup memory cashGroup,
//        int fCashAmount,
//        uint timeToMaturity
//    ) internal view returns (Market memory, uint128) {
//        if (fCashAmount < 0 && marketState.totalfCash < fCashAmount.neg()) {
//            // We return false if there is not enough fCash to support this trade.
//            return (marketState, 0);
//        }
//
//        // Get the new rate anchor for this market, this accounts for the anchor rate changing as we
//        // roll down to maturity. This needs to be saved to the market if we actually trade.
//        bool success;
//        (marketState.rateAnchor, success) = _getNewRateAnchor(marketState, cashGroup, timeToMaturity);
//        if (!success) return (marketState, 0);
//
//        // Calculate the exchange rate between fCash and cash the user will trade at
//        uint tradeExchangeRate;
//        (tradeExchangeRate, success) = _getExchangeRate(marketState, cashGroup, timeToMaturity, fCashAmount);
//        if (!success) return (marketState, 0);
//
//        // The fee amount will decrease as we roll down to maturity
//        uint fee = uint(cashGroup.liquidityFee).mul(timeToMaturity).div(SECONDS_IN_YEAR);
//        if (fCashAmount > 0) {
//            uint postFeeRate = tradeExchangeRate + fee;
//            // This is an overflow on the fee
//            if (postFeeRate < tradeExchangeRate) return (marketState, 0);
//            tradeExchangeRate = postFeeRate;
//        } else {
//            uint postFeeRate = tradeExchangeRate - fee;
//            // This is an underflow on the fee
//            if (postFeeRate > tradeExchangeRate) return (marketState, 0);
//            tradeExchangeRate = postFeeRate;
//        }
//
//        if (tradeExchangeRate < RATE_PRECISION) {
//            // We do not allow negative exchange rates.
//            return (marketState, 0);
//        }
//
//        // cash = fCashAmount / exchangeRate
//        // TODO: need to convert to interest bearing token terms here
//        uint128 cash = SafeCast.toUint128(uint(fCashAmount.abs()).mul(RATE_PRECISION).div(tradeExchangeRate));
//        uint128 convertedCash = ExchangeRate._convertFromUnderlying(CashGroup.assetOracle, cash);
//
//        // Update the markets accordingly.
//        if (fCashAmount > 0) {
//            if (marketState.totalCurrentCash < cash) {
//                // There is not enough cash to support this trade.
//                return (marketState, 0);
//            }
//
//            marketState.totalfCash = marketState.totalfCash.add(uint128(fCashAmount));
//            marketState.totalCurrentCash = marketState.totalCurrentCash.sub(cash);
//        } else {
//            marketState.totalfCash = marketState.totalfCash.sub(uint128(fCashAmount.abs()));
//            marketState.totalCurrentCash = marketState.totalCurrentCash.add(cash);
//        }
//
//        // Now calculate the implied rate, this will be used for future rolldown calculations.
//        uint impliedRate;
//        (impliedRate, success) = _getImpliedRate(marketState, cashGroup, timeToMaturity);
//
//        // Implied rates over 429% will overflow, this seems like a safe assumption
//        if (impliedRate > type(uint32).max) return (marketState, 0);
//        if (!success) return (marketState, 0);
//
//        marketState.lastAnnualizedRate = uint32(impliedRate);
//
//        return (marketState, cash);
//    }
//
   /**
    * @notice Rate anchors update as the market gets closer to maturity. Rate anchors are not comparable
    * across time or markets but implied rates are. The goal here is to ensure that the implied rate
    * before and after the rate anchor update is the same. Therefore, the market will trade at the same implied
    * rate that it last traded at. If these anchors do not update then it opens up the opportunity for arbitrage
    * which will hurt the liquidity providers.
    * 
    * The rate anchor will update as the market rolls down to maturity. The calculation is:
    * newAnchor = anchor - [currentImpliedRate - lastImpliedRate] * (timeToMaturity / IMPLIED_RATE_TIME)
    * where:
    * lastAnnualizedRate = ln(exchangeRate') * (IMPLIED_RATE_TIME / timeToMaturity')
    *      (calculated when the last trade in the market was made)
    * timeToMaturity = maturity - currentBlockTime
    *
    * @return the new rate anchor and a boolean that signifies success
    */
   function getNewRateAnchor(
       MarketParameters memory marketState,
       Rate memory assetRate,
       int rateScalar,
       uint timeToMaturity
   ) internal view returns (uint, bool) {
        // This is the new implied rate given the new time to maturity
        (uint impliedRate, bool success) = getImpliedRate(
           marketState,
           assetRate,
           rateScalar,
           timeToMaturity
        );

        if (!success) return (0, false);
        if (int(impliedRate) > type(int256).max) return (0, false);
        if (int(timeToMaturity) > type(int256).max) return (0, false);

        int rateDifference = int(impliedRate)
           .sub(int(marketState.lastImpliedRate))
           .mul(int(timeToMaturity))
           .div(int(IMPLIED_RATE_TIME));

        int newRateAnchor = int(marketState.rateAnchor).sub(rateDifference);

        // Rate anchors are stored as uint40 so we cannot exceed this limit
        if (newRateAnchor < 0 || newRateAnchor > type(uint40).max) return (0, false);

        return (uint(newRateAnchor), true);
   }

   /**
    * @notice Calculates the current market implied rate. This value is comparable across different
    * markets and across time while the rate anchor is specific to a single market.
    *
    * @return the implied rate and a bool that is true on success
    */
   function getImpliedRate(
       MarketParameters memory marketState,
       Rate memory assetRate,
       int rateScalar,
       uint timeToMaturity
   ) internal view returns (uint, bool) {
        // This will check for exchange rates < RATE_PRECISION
        (uint exchangeRate, bool success) = getExchangeRate(
           marketState,
           assetRate,
           rateScalar,
           timeToMaturity,
           0
        );
        if (!success) return (0, false);

        // Uses continuous compounding to calculate the implied rate:
        // ln(exchangeRate) * IMPLIED_RATE_TIME / timeToMaturity
        int128 rate = ABDKMath64x64.fromUInt(exchangeRate);
        int128 rateScaled = ABDKMath64x64.div(rate, RATE_PRECISION_64x64);
        // We will not have a negative log here because we check that exchangeRate > RATE_PRECISION
        // inside getExchangeRate
        int128 lnRateScaled = ABDKMath64x64.ln(rateScaled);
        uint lnRate = ABDKMath64x64.toUInt(ABDKMath64x64.mul(lnRateScaled, RATE_PRECISION_64x64));

        uint finalRate = lnRate
           .mul(IMPLIED_RATE_TIME)
           .div(timeToMaturity);

       return (finalRate, true);
   }

    /**
     * @dev Returns the exchange rate between fCash and cash for the given market
     *
     * Takes a market in memory and calculates the following exchange rate:
     * (1 / rateScalar) * ln(proportion / (1 - proportion)) + rateAnchor
     * where:
     * proportion = totalfCash / (totalfCash + totalCurrentCash)
     */
    function getExchangeRate(
        MarketParameters memory marketState,
        Rate memory assetRate,
        int rateScalar,
        uint timeToMaturity,
        int fCashAmount
    ) internal view returns (uint, bool) {
        // Check conditions that will result in divide by zero
        if (rateScalar == 0) return (0, false);

        if (marketState.totalfCash.add(marketState.totalCurrentCash) == 0 || marketState.totalCurrentCash == 0) {
            return (0, false);
        }

        if (fCashAmount >= marketState.totalCurrentCash) {
            // This will result in negative interest rates
            return (0, false);
        }

        int numerator = marketState.totalfCash.add(fCashAmount);
        if (numerator <= 0) return (0, false);

        int totalCashUnderlying = assetRate.convertToUnderlying(marketState.totalCurrentCash);

        // This is the proportion scaled by RATE_PRECISION
        int proportion = numerator
            .mul(int(RATE_PRECISION))
            .div(marketState.totalfCash.add(totalCashUnderlying));

        // proportion' = proportion / (1 - proportion)
        proportion = proportion
            .mul(int(RATE_PRECISION))
            .div(int(RATE_PRECISION).sub(proportion));

        (int lnProportion, bool success) = logProportion(SafeCast.toUint256(proportion));
        if (!success) return (0, false);

        // There is no potential for overflow in int256 space with the addition and subtraction here.
        // (1 / scalar) * ln(proportion') + anchor_rate
        int rate = lnProportion.div(rateScalar).add(SafeCast.toInt256(marketState.rateAnchor));
        
        // Do not succeed if interest rates fall below 1
        if (rate < int(RATE_PRECISION)) {
            return (0, false);
        } else {
            return (uint(rate), true);
        }
    }

    /**
     * @dev This method does ln((proportion / (1 - proportion)) * 1e9)
     */
    function logProportion(uint proportion) internal pure returns (int, bool) {
        // This is the max 64 bit integer for ABDKMath. This is unlikely to trip because the
        // value is 9.2e18 and the proportion is scaled by 1e9. We can hit very high levels of
        // pool utilization before this returns false.
        if (proportion > MAX64) return (0, false);

        int128 abdkProportion = ABDKMath64x64.fromUInt(proportion);
        // If abdkProportion is negative, this means that it is less than 1 and will
        // return a negative log so we exit here
        if (abdkProportion <= 0) return (0, false);

        int result = ABDKMath64x64.toUInt(ABDKMath64x64.ln(abdkProportion));

        return (result, true);
    }

}


contract MockMarket {
    using Market for MarketParameters;

    function getUint64(uint value) public pure returns (int128) {
        return ABDKMath64x64.fromUInt(value);
    }

    function getExchangeRate(
        MarketParameters memory marketState,
        Rate memory rate,
        int rateScalar,
        uint timeToMaturity,
        int fCashAmount
    ) external view returns (uint, bool) {
        return marketState.getExchangeRate(
            rate,
            rateScalar,
            timeToMaturity,
            fCashAmount
        );
    }

    function logProportion(uint proportion) external view returns (int, bool) {
        return Market.logProportion(proportion);
    }

    function initializeRateAnchor(uint gRateAnchor, uint timeToMaturity) external view returns (uint) {
       return Market.initializeRateAnchor(gRateAnchor, timeToMaturity);
    }

    function getImpliedRate(
        MarketParameters memory marketState,
        Rate memory assetRate,
        int rateScalar,
        uint timeToMaturity
    ) external view returns (uint, bool) {
        return Market.getImpliedRate(
            marketState,
            assetRate,
            rateScalar,
            timeToMaturity
        );
    }

    function getNewRateAnchor(
        MarketParameters calldata marketState,
        Rate memory assetRate,
        int rateScalar,
        uint timeToMaturity
    ) external view returns (uint, bool) {
        return marketState.getNewRateAnchor(assetRate, rateScalar, timeToMaturity);
        // assert newRateAnchor < oldRateAnchor
        // assert newRateAnchor > RATE_PRECISION
    }

//    function tradeCalculation(
//        Market calldata marketState,
//        CashGroup calldata cashGroup,
//        int fCashAmount,
//        uint timeToMaturity
//    ) external view returns (Market memory, uint128) {
//        return LiquidityCurve._tradeCalculation(marketState, cashGroup, fCashAmount, timeToMaturity);
//    }
//
//
}
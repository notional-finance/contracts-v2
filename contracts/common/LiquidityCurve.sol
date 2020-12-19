// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "../math/SafeUInt128.sol";
import "../math/ABDKMath64x64.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";

struct Market {
    // Total amount of fCash available for purchase in the market.
    uint128 totalfCash;
    // Total amount of cash available for purchase in the market.
    uint128 totalCurrentCash;
    // Total amount of liquidity tokens (representing a claim on liquidity) in the market.
    uint128 totalLiquidity;
    // These factors are set when the market is instantiated by a liquidity provider via the global
    // settings and then held constant for the duration of the maturity. We cannot change them without
    // really messing up the market rates.
    uint32 rateAnchor;
    // This is the implied annualized rate that we use to smooth the anchor rate between trades.
    uint32 lastAnnualizedRate;
}

struct CashGroup {
    uint32 liquidityFee;
    uint16 rateScalar;
}

library LiquidityCurve {
    using SafeMath for uint;
    using SafeInt256 for int;
    using SafeUInt128 for uint128;

    uint internal constant SECONDS_IN_YEAR = 31536000;

    // Max positive value for a ABDK64x64 integer
    uint internal constant MAX64 = 0x7FFFFFFFFFFFFFFF;
    uint internal constant RATE_PRECISION = 1e9;
    // This is the ABDK64x64 representation of RATE_PRECISION
    // RATE_PRECISION_64x64 = ABDKMath64x64.fromUint(RATE_PRECISION)
    int128 internal constant RATE_PRECISION_64x64 = 0x3b9aca000000000000000000;
    int128 internal constant SECONDS_IN_YEAR_64x64 = 0x1e133800000000000000000;

    // Decimal precision of the proportion
    uint internal constant PROPORTION_PRECISION = 1e18;
    // LN_PROPORTION_PRECISION = ABDK64x64.ln(ABDK64x64.fromUint(PROPORTION_PRECISION))
    int64 internal constant LN_PROPORTION_PRECISION = 0x09a667e259;

    /**
     * Returns the initial value of the rate anchor which is a governance paramater stored
     * as RATE_PRECISION + annualized rate. We normalize it to time to maturity using continuous
     * compounding. The formula is:
     * math.exp((timeToMaturity / SECONDS_IN_YEAR) * (gRateAnchor - 1))
     *
     * @return uint32 rateAnchor value that can be stored
     */
    function _initializeRateAnchor(uint gRateAnchor, uint timeToMaturity) internal pure returns (uint64) {
        // NOTE: will need to worry about overflow at around 30 years time to maturity
        int128 numerator = ABDKMath64x64.fromUInt(gRateAnchor.sub(RATE_PRECISION).mul(timeToMaturity));
        int128 expValue = ABDKMath64x64.div(numerator, SECONDS_IN_YEAR_64x64);
        int128 expValueScaled = ABDKMath64x64.div(expValue, RATE_PRECISION_64x64);
        int128 expResult = ABDKMath64x64.exp(expValueScaled);
        int128 expResultScaled = ABDKMath64x64.mul(expResult, RATE_PRECISION_64x64);

        return ABDKMath64x64.toUInt(expResultScaled);
    }

    /**
     * @notice Does the trade calculation and returns the new market state and cash amount
     *
     * @param marketState the current market state
     * @param cashGroup cash group configuration parameters
     * @param fCashAmount the fCash amount specified
     * @param timeToMaturity number of seconds until maturity
     * @return (new market state, cash)
     */
    function _tradeCalculation(
        Market memory marketState,
        CashGroup memory cashGroup,
        int fCashAmount,
        uint timeToMaturity
    ) internal view returns (Market memory, uint128) {
        if (fCashAmount < 0 && marketState.totalfCash < fCashAmount.neg()) {
            // We return false if there is not enough fCash to support this trade.
            return (marketState, 0);
        }

        // Get the new rate anchor for this market, this accounts for the anchor rate changing as we
        // roll down to maturity. This needs to be saved to the market if we actually trade.
        bool success;
        (marketState.rateAnchor, success) = _getNewRateAnchor(marketState, cashGroup, timeToMaturity);
        if (!success) return (marketState, 0);

        // Calculate the exchange rate between fCash and cash the user will trade at
        uint tradeExchangeRate;
        (tradeExchangeRate, success) = _getExchangeRate(marketState, cashGroup, timeToMaturity, fCashAmount);
        if (!success) return (marketState, 0);

        // The fee amount will decrease as we roll down to maturity
        uint fee = uint(cashGroup.liquidityFee).mul(timeToMaturity).div(SECONDS_IN_YEAR);
        if (fCashAmount > 0) {
            uint postFeeRate = tradeExchangeRate + fee;
            // This is an overflow on the fee
            if (postFeeRate < tradeExchangeRate) return (marketState, 0);
            tradeExchangeRate = postFeeRate;
        } else {
            uint postFeeRate = tradeExchangeRate - fee;
            // This is an underflow on the fee
            if (postFeeRate > tradeExchangeRate) return (marketState, 0);
            tradeExchangeRate = postFeeRate;
        }

        if (tradeExchangeRate < RATE_PRECISION) {
            // We do not allow negative exchange rates.
            return (marketState, 0);
        }

        // cash = fCashAmount / exchangeRate
        uint128 cash = SafeCast.toUint128(uint(fCashAmount.abs()).mul(RATE_PRECISION).div(tradeExchangeRate));

        // Update the markets accordingly.
        if (fCashAmount > 0) {
            if (marketState.totalCurrentCash < cash) {
                // There is not enough cash to support this trade.
                return (marketState, 0);
            }

            marketState.totalfCash = marketState.totalfCash.add(uint128(fCashAmount));
            marketState.totalCurrentCash = marketState.totalCurrentCash.sub(cash);
        } else {
            marketState.totalfCash = marketState.totalfCash.sub(uint128(fCashAmount.abs()));
            marketState.totalCurrentCash = marketState.totalCurrentCash.add(cash);
        }

        // Now calculate the implied rate, this will be used for future rolldown calculations.
        uint impliedRate;
        (impliedRate, success) = _getImpliedRate(marketState, cashGroup, timeToMaturity);

        // Implied rates over 429% will overflow, this seems like a safe assumption
        if (impliedRate > type(uint32).max) return (marketState, 0);
        if (!success) return (marketState, 0);

        marketState.lastAnnualizedRate = uint32(impliedRate);

        return (marketState, cash);
    }

    /**
     * The rate anchor will update as the market rolls down to maturity. The calculation is:
     * newAnchor = anchor - [currentImpliedRate - lastAnnualizedRate] * (timeToMaturity / SECONDS_IN_YEAR)
     * where:
     * lastAnnualizedRate = (exchangeRate' - 1) * (SECONDS_IN_YEAR / timeToMaturity')
     *      (calculated when the last trade in the market was made)
     * timeToMaturity = maturity - currentBlockTime
     * @return the new rate anchor and a boolean that signifies success
     */
    function _getNewRateAnchor(
        Market memory marketState,
        CashGroup memory cashGroup,
        uint timeToMaturity
    ) internal view returns (uint32, bool) {
        (uint impliedRate, bool success) = _getImpliedRate(marketState, cashGroup, timeToMaturity);

        if (!success) return (0, false);
        if (timeToMaturity > type(uint128).max) return (0, false);
        if (impliedRate > type(uint128).max) return (0, false);

        int rateDifference = int(impliedRate)
            .sub(marketState.lastAnnualizedRate)
            .mul(int(timeToMaturity))
            .div(int(SECONDS_IN_YEAR));

        int newRateAnchor = int(marketState.rateAnchor).sub(rateDifference);

        if (newRateAnchor < 0 || newRateAnchor > type(uint32).max) return (0, false);

        return (uint32(newRateAnchor), true);
    }

    /**
     * Calculates the current market implied rate.
     *
     * @return the implied rate and a bool that is true on success
     */
    function _getImpliedRate(
        Market memory marketState,
        CashGroup memory cashGroup,
        uint timeToMaturity
    ) internal view returns (uint, bool) {
        (uint32 exchangeRate, bool success) = _getExchangeRate(marketState, cashGroup, timeToMaturity, 0);

        if (!success) return (0, false);
        if (exchangeRate < RATE_PRECISION) return (0, false);

        // Uses continuous compounding to calculate the implied rate:
        // ln(exchangeRate) * SECONDS_IN_YEAR / timeToMaturity
        int128 rate = ABDKMath64x64.fromUInt(exchangeRate);
        int128 rateScaled = ABDKMath64x64.div(rate, RATE_PRECISION_64x64);
        // We will not have a negative log here because we check that exchangeRate > 1e9 above
        int128 lnRateScaled = ABDKMath64x64.ln(rateScaled);
        uint lnRate = ABDKMath64x64.toUInt(ABDKMath64x64.mul(lnRateScaled, RATE_PRECISION_64x64));

        uint finalRate = lnRate
            .mul(SECONDS_IN_YEAR)
            .div(timeToMaturity);

        return (finalRate, true);
    }

    /**
     * @dev It is important that this call does not revert, if it does it may prevent liquidation
     * or settlement from finishing. We return a rate of 0 to signify a failure.
     *
     * Takes a market in memory and calculates the following exchange rate:
     * (1 / G_RATE_SCALAR) * ln(proportion / (1 - proportion)) + G_RATE_ANCHOR
     * where:
     * proportion = totalfCash / (totalfCash + totalCurrentCash)
     */
    function _getExchangeRate(
        Market memory marketState,
        CashGroup memory cashGroup,
        uint timeToMaturity,
        int fCashAmount
    ) internal view returns (uint32, bool) {
        // These two conditions will result in divide by zero errors.
        if (marketState.totalfCash.add(marketState.totalCurrentCash) == 0 || marketState.totalCurrentCash == 0) {
            return (0, false);
        }

        if (fCashAmount >= marketState.totalCurrentCash) {
            // This will result in negative interest rates
            return (0, false);
        }

        // This will always be positive, we do a check beforehand in _tradeCalculation
        uint numerator = uint(int(marketState.totalfCash).add(fCashAmount));
        // This is always less than PROPORTION_PRECISION
        uint proportion = numerator
            .mul(PROPORTION_PRECISION)
            .div(marketState.totalfCash.add(marketState.totalCurrentCash));

        // proportion' = proportion / (1 - proportion)
        proportion = proportion
            .mul(PROPORTION_PRECISION)
            .div(PROPORTION_PRECISION.sub(proportion));

        // (1 / scalar) * ln(proportion') + anchor_rate
        (int abdkResult, bool success) = _abdkMath(proportion);
        if (!success) return (0, false);

        if (timeToMaturity > type(uint128).max) return (0, false);

        // The rate scalar will increase towards maturity, this will lower the impact of changes
        // to the proportion as we get towards maturity.
        int rateScalar = int(cashGroup.rateScalar).mul(int(SECONDS_IN_YEAR)).div(int(timeToMaturity));
        if (rateScalar == 0) return (0, false);
        if (rateScalar > type(uint32).max) return (0, false);

        // This is ln(1e18), subtract this to scale proportion back. There is no potential for overflow
        // in int256 space with the addition and subtraction here.
        int rate = ((abdkResult - LN_PROPORTION_PRECISION) / rateScalar) + marketState.rateAnchor;
        
        // These checks simply prevent math errors, not negative interest rates.
        if (rate < 0) {
            return (0, false);
        } else if (rate > type(uint32).max) {
            return (0, false);
        } else {
            return (uint32(rate), true);
        }
    }

    function _abdkMath(uint proportion) internal pure returns (uint64, bool) {
        // This is the max 64 bit integer for ABDKMath. Note that this will fail when the
        // market reaches a proportion of 9.2 due to the MAX64 value.
        if (proportion > MAX64) return (0, false);

        int128 abdkProportion = ABDKMath64x64.fromUInt(proportion);
        // If abdkProportion is negative, this means that it is less than 1 and will
        // return a negative log so we exit here
        if (abdkProportion <= 0) return (0, false);

        int abdkLog = ABDKMath64x64.ln(abdkProportion);
        // This is the 64x64 multiplication with the 64x64 represenation of 1e9. The max value of
        // this due to MAX64 is ln(MAX64) * 1e9 = 43668272375
        int result = (abdkLog * RATE_PRECISION_64x64) >> 64;

        if (result < ABDKMath64x64.MIN_64x64 || result > ABDKMath64x64.MAX_64x64) {
            return (0, false);
        }

        // Will pass int128 conversion after the overflow checks above. We convert to a uint here because we have
        // already checked that proportion is positive and so we cannot return a negative log.
        return (ABDKMath64x64.toUInt(int128(result)), true);
    }

}


contract MockLiquidityCurve {
    function tradeCalculation(
        Market calldata marketState,
        CashGroup calldata cashGroup,
        int fCashAmount,
        uint timeToMaturity
    ) external view returns (Market memory, uint128) {
        return LiquidityCurve._tradeCalculation(marketState, cashGroup, fCashAmount, timeToMaturity);
    }

    function getNewRateAnchor(
        Market calldata marketState,
        CashGroup calldata cashGroup,
        uint timeToMaturity
    ) external view returns (uint32, bool) {
        return LiquidityCurve._getNewRateAnchor(marketState, cashGroup, timeToMaturity);
        // assert newRateAnchor < oldRateAnchor
        // assert newRateAnchor > RATE_PRECISION
    }

    function getImpliedRate(
        Market calldata marketState,
        CashGroup calldata cashGroup,
        uint timeToMaturity
    ) external view returns (uint, bool) {
        return LiquidityCurve._getImpliedRate(marketState, cashGroup, timeToMaturity);
    }

    function getExchangeRate(
        Market memory marketState,
        CashGroup memory cashGroup,
        uint timeToMaturity,
        int fCashAmount
    ) external view returns (uint32, bool) {
        return LiquidityCurve._getExchangeRate(marketState, cashGroup, timeToMaturity, fCashAmount);
    }

    function abdkMath(uint proportion) external view returns (uint64, bool) {
        return LiquidityCurve._abdkMath(proportion);
    }

    function initializeRateAnchor(uint gRateAnchor, uint timeToMaturity) external view returns (uint64) {
        return LiquidityCurve._initializeRateAnchor(gRateAnchor, timeToMaturity);
    }

}
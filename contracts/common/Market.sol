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
    uint currencyId;
    uint maturity;

    // Total amount of fCash available for purchase in the market.
    int totalfCash;
    // Total amount of cash available for purchase in the market.
    int totalCurrentCash;
    // Total amount of liquidity tokens (representing a claim on liquidity) in the market.
    int totalLiquidity;
    // This is the implied rate that we use to smooth the anchor rate between trades.
    uint lastImpliedRate;
    // This is the oracle rate used to value fCash and prevent flash loan attacks
    uint oracleRate;
    // This is the timestamp of the previous trade
    uint previousTradeTime;
}

library Market {
    using SafeMath for uint;
    using SafeInt256 for int;
    using SafeUInt128 for uint128;
    using CashGroup for CashGroupParameters;
    using ExchangeRate for Rate;

    uint internal constant MARKET_STORAGE_SLOT = 6;
    uint internal constant LIQUIDITY_STORAGE_SLOT = 7;

    // This is a constant that represents the time period that all rates are normalized by, 360 days
    uint internal constant IMPLIED_RATE_TIME = 31104000;

    // Max positive value for a ABDK64x64 integer
    int internal constant MAX64 = 0x7FFFFFFFFFFFFFFF;
    // Number of decimal places that rates are stored in, equals 100%
    int internal constant RATE_PRECISION = 1e9;
    uint internal constant BASIS_POINT = uint(RATE_PRECISION / 10000);

    // This is the ABDK64x64 representation of RATE_PRECISION
    // RATE_PRECISION_64x64 = ABDKMath64x64.fromUint(RATE_PRECISION)
    int128 internal constant RATE_PRECISION_64x64 = 0x3b9aca000000000000000000;
    // IMPLIED_RATE_TIME_64x64 = ABDKMath64x64.fromUint(IMPLIED_RATE_TIME)
    int128 internal constant IMPLIED_RATE_TIME_64x64 = 0x1da9c000000000000000000;

    /**
     * @notice Does the trade calculation and returns the new market state and cash amount, fCash and
     * cash amounts are all specified at RATE_PRECISION.
     *
     * @param marketState the current market state
     * @param cashGroup cash group configuration parameters
     * @param fCashAmount the fCash amount specified
     * @param timeToMaturity number of seconds until maturity
     * @return (new market state, netAssetCash, netCash)
     */
    function calculateTrade(
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup,
        int fCashAmount,
        uint timeToMaturity
    ) internal view returns (MarketParameters memory, int, int) {
        if (marketState.totalfCash + fCashAmount <= 0) {
            // We return false if there is not enough fCash to support this trade.
            return (marketState, 0, 0);
        }
        int rateScalar = cashGroup.getRateScalar(timeToMaturity);
        int totalCashUnderlying = cashGroup.assetRate.convertInternalToUnderlying(marketState.totalCurrentCash);

        // This will result in a divide by zero
        if (rateScalar == 0) return (marketState, 0, 0);
        // This will result in a divide by zero
        if (marketState.totalfCash == 0 || totalCashUnderlying == 0) return (marketState, 0, 0);
        // This will result in negative interest rates
        if (fCashAmount >= totalCashUnderlying) return (marketState, 0, 0);

        // Get the rate anchor given the market state, this will establish the baseline for where
        // the exchange rate is set.
        int rateAnchor;
        {
            bool success;
            (rateAnchor, success) = getRateAnchor(
                marketState.totalfCash,
                marketState.lastImpliedRate,
                totalCashUnderlying,
                rateScalar,
                timeToMaturity
            );
            if (!success) return (marketState, 0, 0);

        }

        // Calculate the exchange rate between fCash and cash the user will trade at
        int tradeExchangeRate;
        {
            bool success;
            (tradeExchangeRate, success) = getExchangeRate(
                marketState.totalfCash,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                fCashAmount
            );
            if (!success) return (marketState, 0, 0);
        }

        if (fCashAmount > 0) {
            uint fee = cashGroup.getLiquidityFee(timeToMaturity);
            tradeExchangeRate = tradeExchangeRate.add(int(fee));
        } else {
            uint fee = cashGroup.getLiquidityFee(timeToMaturity);
            tradeExchangeRate = tradeExchangeRate.sub(int(fee));
        }

        if (tradeExchangeRate < RATE_PRECISION) {
            // We do not allow negative exchange rates.
            return (marketState, 0, 0);
        }

        return getNewMarketState(
            marketState,
            cashGroup.assetRate,
            totalCashUnderlying,
            rateAnchor,
            rateScalar,
            fCashAmount,
            tradeExchangeRate,
            timeToMaturity
        );
    }

    function getNewMarketState(
        MarketParameters memory marketState,
        Rate memory assetRate,
        int totalCashUnderlying,
        int rateAnchor,
        int rateScalar,
        int fCashAmount,
        int tradeExchangeRate,
        uint timeToMaturity
    ) internal view returns (MarketParameters memory, int, int) {
        // cash = fCashAmount / exchangeRate
        // The net cash amount will be the opposite direction of the fCash amount, if we add
        // fCash to the market then we subtract cash and vice versa. We know that tradeExchangeRate
        // is positive and greater than RATE_PRECISION here
        int netCash = fCashAmount.mul(RATE_PRECISION).div(tradeExchangeRate).neg();
        int netAssetCash = assetRate.convertInternalFromUnderlying(netCash);
        
        // Underflow on netAssetCash
        if (marketState.totalCurrentCash + netAssetCash <= 0) return (marketState, 0, 0);
        marketState.totalfCash = marketState.totalfCash.add(fCashAmount);
        marketState.totalCurrentCash = marketState.totalCurrentCash.add(netAssetCash);

        // The new implied rate will be used to set the rate anchor for the next trade
        bool success;
        (marketState.lastImpliedRate, success) = getImpliedRate(
            marketState.totalfCash,
            totalCashUnderlying.add(netCash),
            rateScalar,
            rateAnchor,
            timeToMaturity
        );
        if (!success) return (marketState, 0, 0);
        // Sets the trade time for the next oracle update
        marketState.previousTradeTime = block.timestamp;

        return (marketState, netAssetCash, netCash);
    }

    /**
     * @notice Rate anchors update as the market gets closer to maturity. Rate anchors are not comparable
     * across time or markets but implied rates are. The goal here is to ensure that the implied rate
     * before and after the rate anchor update is the same. Therefore, the market will trade at the same implied
     * rate that it last traded at. If these anchors do not update then it opens up the opportunity for arbitrage
     * which will hurt the liquidity providers.
     * 
     * The rate anchor will update as the market rolls down to maturity. The calculation is:
     * newExchangeRate = e^(lastImpliedRate * timeToMaturity / IMPLIED_RATE_TIME)
     * newAnchor = newExchangeRate - ln((proportion / (1 - proportion)) / rateScalar
     * where:
     * lastImpliedRate = ln(exchangeRate') * (IMPLIED_RATE_TIME / timeToMaturity')
     *      (calculated when the last trade in the market was made)
     *
     * @dev Due to loss of precision from dividing the implied rate will decay to a small degree if there
     * is no trading in the market at all. Our tests indicate that this degredation is limited to 0.001% of
     * the rate over a 90 day roll down period.
     *
     * @return the new rate anchor and a boolean that signifies success
     */
    function getRateAnchor(
        int totalfCash,
        uint lastImpliedRate,
        int totalCashUnderlying,
        int rateScalar,
        uint timeToMaturity
    ) internal pure returns (int, bool) {
        // This is the exchange rate at the new time to maturity
        int exchangeRate;
        {
            int128 expValue = ABDKMath64x64.fromUInt(
                // There is a bit of imprecision from this division here but if we use
                // int128 then we will get overflows so unclear how we can maintain the precision
                lastImpliedRate.mul(timeToMaturity).div(IMPLIED_RATE_TIME)
            );
            int128 expValueScaled = ABDKMath64x64.div(expValue, RATE_PRECISION_64x64);
            int128 expResult = ABDKMath64x64.exp(expValueScaled);
            int128 expResultScaled = ABDKMath64x64.mul(expResult, RATE_PRECISION_64x64);
            exchangeRate = ABDKMath64x64.toInt(expResultScaled);

            if (exchangeRate < RATE_PRECISION) return (0, false);
        }

        int rateAnchor;
        {
            int proportion = totalfCash
                .mul(RATE_PRECISION)
                .div(totalfCash.add(totalCashUnderlying));
            (int lnProportion, bool success) = logProportion(proportion);
            if (!success) return (0, false);

            rateAnchor = exchangeRate.sub(lnProportion.div(rateScalar));
        }

        return (rateAnchor, true);
   }

   /**
    * @notice Calculates the current market implied rate. 
    *
    * @return the implied rate and a bool that is true on success
    */
   function getImpliedRate(
       int totalfCash,
       int totalCashUnderlying,
       int rateScalar,
       int rateAnchor,
       uint timeToMaturity
   ) internal pure returns (uint, bool) {
        // This will check for exchange rates < RATE_PRECISION
        (int exchangeRate, bool success) = getExchangeRate(
           totalfCash,
           totalCashUnderlying,
           rateScalar,
           rateAnchor,
           0
        );
        if (!success) return (0, false);

        // Uses continuous compounding to calculate the implied rate:
        // ln(exchangeRate) * IMPLIED_RATE_TIME / timeToMaturity
        int128 rate = ABDKMath64x64.fromInt(exchangeRate);
        int128 rateScaled = ABDKMath64x64.div(rate, RATE_PRECISION_64x64);
        // We will not have a negative log here because we check that exchangeRate > RATE_PRECISION
        // inside getExchangeRate
        int128 lnRateScaled = ABDKMath64x64.ln(rateScaled);
        uint lnRate = ABDKMath64x64.toUInt(ABDKMath64x64.mul(lnRateScaled, RATE_PRECISION_64x64));

        uint impliedRate = lnRate
           .mul(IMPLIED_RATE_TIME)
           .div(timeToMaturity);

        // Implied rates over 429% will overflow, this seems like a safe assumption
        if (impliedRate > type(uint32).max) return (0, false);

       return (impliedRate, true);
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
        int totalfCash,
        int totalCashUnderlying,
        int rateScalar,
        int rateAnchor,
        int fCashAmount
    ) internal pure returns (int, bool) {
        int numerator = totalfCash.add(fCashAmount);
        if (numerator <= 0) return (0, false);

        // This is the proportion scaled by RATE_PRECISION
        int proportion = numerator
            .mul(RATE_PRECISION)
            .div(totalfCash.add(totalCashUnderlying));

        // proportion' = proportion / (1 - proportion)
        proportion = proportion
            .mul(RATE_PRECISION)
            .div(RATE_PRECISION.sub(proportion));

        (int lnProportion, bool success) = logProportion(proportion);
        if (!success) return (0, false);

        int rate = lnProportion.div(rateScalar).add(rateAnchor);
        // Do not succeed if interest rates fall below 1
        if (rate < RATE_PRECISION) {
            return (0, false);
        } else {
            return (rate, true);
        }
    }

    /**
     * @dev This method does ln((proportion / (1 - proportion)) * 1e9)
     */
    function logProportion(int proportion) internal pure returns (int, bool) {
        // This is the max 64 bit integer for ABDKMath. This is unlikely to trip because the
        // value is 9.2e18 and the proportion is scaled by 1e9. We can hit very high levels of
        // pool utilization before this returns false.
        if (proportion > MAX64) return (0, false);

        int128 abdkProportion = ABDKMath64x64.fromInt(proportion);
        // If abdkProportion is negative, this means that it is less than 1 and will
        // return a negative log so we exit here
        if (abdkProportion <= 0) return (0, false);

        int result = ABDKMath64x64.toUInt(ABDKMath64x64.ln(abdkProportion));

        return (result, true);
    }
    
    /**
     * @notice Oracle rate protects against short term price manipulation. Time window will be set to a value
     * on the order of minutes to hours. This is to protect fCash valuations from market manipulation. For example,
     * a trader could use a flash loan to dump a large amount of cash into the market and depress interest rates.
     * Since we value fCash in portfolios based on these rates, portfolio values will decrease and they may then
     * be liquidated.
     * 
     * Oracle rates are calculated when the market is loaded from storage.
     *
     * The oracle rate is a lagged weighted average over a short term price window. If we are past
     * the short term window then we just set the rate to the lastImpliedRate, otherwise we take the
     * weighted average:
     * lastImpliedRatePreTrade * (currentTs - previousTs) / timeWindow +
     *      oracleRatePrevious * (1 - (currentTs - previousTs) / timeWindow)
     */
    function updateRateOracle(
        uint previousTradeTime,
        uint lastImpliedRate,
        uint oracleRate,
        uint rateOracleTimeWindow,
        uint blockTime
    ) private pure returns (uint) {
        require(rateOracleTimeWindow > 0, "M: time window zero");

        uint timeDiff = blockTime.sub(previousTradeTime);
        if (timeDiff > rateOracleTimeWindow) {
            // If past the time window just return the lastImpliedRate
            return lastImpliedRate;
        }

        // (currentTs - previousTs) / timeWindow
        uint lastTradeWeight = timeDiff
            .mul(uint(RATE_PRECISION))
            .div(rateOracleTimeWindow);
        
        // 1 - (currentTs - previousTs) / timeWindow
        uint oracleWeight = uint(RATE_PRECISION).sub(lastTradeWeight);

        uint newOracleRate = (
            lastImpliedRate
                .mul(lastTradeWeight)
                .add(oracleRate.mul(oracleWeight))
            ).div(uint(RATE_PRECISION));

        return newOracleRate;
    }

    function getMarketStorage(
        uint currencyId,
        uint maturity,
        bool needsLiquidity
    ) internal view returns (MarketParameters memory) {
        bytes32 slot = keccak256(abi.encode(maturity, keccak256(abi.encode(currencyId, MARKET_STORAGE_SLOT))));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        int totalLiquidity;
        if (needsLiquidity) {
            slot = keccak256(abi.encode(maturity, keccak256(abi.encode(currencyId, LIQUIDITY_STORAGE_SLOT))));

            assembly {
                totalLiquidity := sload(slot)
            }
        }

        int totalfCash = int(uint80(bytes10(data)));
        int totalCurrentCash = int(uint80(bytes10(data >> 80)));
        uint lastImpliedRate = uint(uint32(bytes4(data >> 160)));
        uint oracleRate = uint(uint32(bytes4(data >> 192)));
        uint previousTradeTime = uint(uint32(bytes4(data >> 224)));

        return MarketParameters({
            currencyId: currencyId,
            maturity: maturity,
            totalfCash: totalfCash,
            totalCurrentCash: totalCurrentCash,
            totalLiquidity: totalLiquidity,
            lastImpliedRate: lastImpliedRate,
            oracleRate: oracleRate,
            previousTradeTime: previousTradeTime
        });
    }

    function buildMarket(
        uint currencyId,
        uint maturity,
        uint blockTime,
        bool needsLiquidity,
        uint rateOracleTimeWindow
    ) internal view returns (MarketParameters memory) {
        MarketParameters memory marketState = getMarketStorage(currencyId, maturity, needsLiquidity);

        marketState.oracleRate = updateRateOracle(
            marketState.previousTradeTime,
            marketState.lastImpliedRate,
            marketState.oracleRate,
            rateOracleTimeWindow,
            blockTime
        );

        return marketState;
    }

}


contract MockMarket is StorageLayoutV1 {
    using Market for MarketParameters;

    function setMarketState(
        uint id,
        uint maturity,
        MarketStorage calldata ms,
        uint80 totalLiquidity
    ) external {
        marketStateMapping[id][maturity] = ms;
        marketTotalLiquidityMapping[id][maturity] = totalLiquidity;
    }

    function getUint64(uint value) public pure returns (int128) {
        return ABDKMath64x64.fromUInt(value);
    }

    function getExchangeRate(
        int totalfCash,
        int totalCashUnderlying,
        int rateScalar,
        int rateAnchor,
        int fCashAmount
    ) external pure returns (int, bool) {
        return Market.getExchangeRate(
            totalfCash,
            totalCashUnderlying,
            rateScalar,
            rateAnchor,
            fCashAmount
        );
    }

    function logProportion(int proportion) external pure returns (int, bool) {
        return Market.logProportion(proportion);
    }

    function getImpliedRate(
        int totalfCash,
        int totalCashUnderlying,
        int rateScalar,
        int rateAnchor,
        uint timeToMaturity
    ) external pure returns (uint, bool) {
        return Market.getImpliedRate(
            totalfCash,
            totalCashUnderlying,
            rateScalar,
            rateAnchor,
            timeToMaturity
        );
    }

    function getRateAnchor(
        int totalfCash,
        uint lastImpliedRate,
        int totalCashUnderlying,
        int rateScalar,
        uint timeToMaturity
    ) external pure returns (int, bool) {
        return Market.getRateAnchor(
            totalfCash,
            lastImpliedRate,
            totalCashUnderlying,
            rateScalar,
            timeToMaturity
        );
    }

   function calculateTrade(
       MarketParameters calldata marketState,
       CashGroupParameters calldata cashGroup,
       int fCashAmount,
       uint timeToMaturity
   ) external view returns (MarketParameters memory, int, int) {
       return marketState.calculateTrade(
           cashGroup,
           fCashAmount,
           timeToMaturity
        );
   }

   function buildMarket(
        uint currencyId,
        uint maturity,
        uint blockTime,
        bool needsLiquidity,
        uint rateOracleTimeWindow
    ) public view returns (MarketParameters memory) {
        return Market.buildMarket(
            currencyId,
            maturity,
            blockTime,
            needsLiquidity,
            rateOracleTimeWindow
        );
    }

}
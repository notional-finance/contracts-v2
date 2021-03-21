// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "../math/ABDKMath64x64.sol";
import "./AssetRate.sol";
import "./CashGroup.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * Market object as represented in memory
 */
struct MarketParameters {
    bytes32 storageSlot;
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
    // Used to determine if the market has been updated
    bytes1 storageState;
}

struct SettlementMarket {
    bytes32 storageSlot;
    // Total amount of fCash available for purchase in the market.
    int totalfCash;
    // Total amount of cash available for purchase in the market.
    int totalCurrentCash;
    // Total amount of liquidity tokens (representing a claim on liquidity) in the market.
    int totalLiquidity;
    // Un parsed market data used for storage
    bytes32 data;
}

library Market {
    using SafeMath for uint;
    using SafeInt256 for int;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;

    bytes1 private constant STORAGE_STATE_NO_CHANGE = 0x00;
    bytes1 private constant STORAGE_STATE_UPDATE_LIQUIDITY = 0x01;
    bytes1 private constant STORAGE_STATE_UPDATE_TRADE = 0x02;
    bytes1 internal constant STORAGE_STATE_INITIALIZE_MARKET = 0x03; // Both settings are set

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
     * @notice Used to add liquidity to a market, assuming that it is initialized. If not then
     * this method will revert and the market must be initialized via the perpetual token.
     *
     * @return (new market state, liquidityTokens, negative fCash position generated)
     */
    function addLiquidity(
        MarketParameters memory marketState,
        int assetCash
    ) internal pure returns (int, int) {
        require(marketState.totalLiquidity > 0, "M: zero liquidity");
        if (assetCash == 0) return (0, 0);
        require(assetCash > 0); // dev: negative asset cash

        int liquidityTokens = marketState.totalLiquidity.mul(assetCash).div(marketState.totalCurrentCash);
        // No need to convert this to underlying, assetCash / totalCurrentCash is a unitless proportion.
        int fCash = marketState.totalfCash.mul(assetCash).div(marketState.totalCurrentCash);

        marketState.totalLiquidity = marketState.totalLiquidity.add(liquidityTokens);
        marketState.totalfCash = marketState.totalfCash.add(fCash);
        marketState.totalCurrentCash = marketState.totalCurrentCash.add(assetCash);
        marketState.storageState = marketState.storageState | STORAGE_STATE_UPDATE_LIQUIDITY;

        return (liquidityTokens, fCash.neg());
    }

    /**
     * @notice Used to remove liquidity from a market, assuming that it is initialized.
     *
     * @return (new market state, liquidityTokens, negative fCash position generated)
     */
    function removeLiquidity(
        MarketParameters memory marketState,
        int tokensToRemove
    ) internal pure returns (int, int) {
        if (tokensToRemove == 0) return (0, 0);
        require(tokensToRemove > 0); // dev: negative tokens to remove

        int assetCash = marketState.totalCurrentCash.mul(tokensToRemove).div(marketState.totalLiquidity);
        int fCash = marketState.totalfCash.mul(tokensToRemove).div(marketState.totalLiquidity);

        marketState.totalLiquidity = marketState.totalLiquidity.subNoNeg(tokensToRemove);
        marketState.totalfCash = marketState.totalfCash.subNoNeg(fCash);
        marketState.totalCurrentCash = marketState.totalCurrentCash.subNoNeg(assetCash);
        marketState.storageState = marketState.storageState | STORAGE_STATE_UPDATE_LIQUIDITY;

        return (assetCash, fCash);
    }

    /**
     * @notice Does the trade calculation and returns the new market state and cash amount, fCash and
     * cash amounts are all specified at RATE_PRECISION.
     *
     * @param marketState the current market state
     * @param cashGroup cash group configuration parameters
     * @param fCashAmount the fCash amount specified
     * @param timeToMaturity number of seconds until maturity
     * @return netAssetCash
     */
    function calculateTrade(
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup,
        int fCashAmount,
        uint timeToMaturity,
        uint marketIndex
    ) internal view returns (int) {
        if (marketState.totalfCash + fCashAmount <= 0) {
            // We return false if there is not enough fCash to support this trade.
            return 0;
        }
        int rateScalar = cashGroup.getRateScalar(marketIndex, timeToMaturity);
        int totalCashUnderlying = cashGroup.assetRate.convertInternalToUnderlying(marketState.totalCurrentCash);

        // This will result in a divide by zero
        if (rateScalar == 0) return 0;
        // This will result in a divide by zero
        if (marketState.totalfCash == 0 || totalCashUnderlying == 0) return 0;
        // This will result in negative interest rates
        if (fCashAmount >= totalCashUnderlying) return 0;

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
            if (!success) return 0;

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
            if (!success) return 0;
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
            return 0;
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
        AssetRateParameters memory assetRate,
        int totalCashUnderlying,
        int rateAnchor,
        int rateScalar,
        int fCashAmount,
        int tradeExchangeRate,
        uint timeToMaturity
    ) private view returns (int) {
        // cash = fCashAmount / exchangeRate
        // The net cash amount will be the opposite direction of the fCash amount, if we add
        // fCash to the market then we subtract cash and vice versa. We know that tradeExchangeRate
        // is positive and greater than RATE_PRECISION here
        int netCash = fCashAmount.mul(RATE_PRECISION).div(tradeExchangeRate).neg();
        int netAssetCash = assetRate.convertInternalFromUnderlying(netCash);
        
        // Underflow on netAssetCash
        if (marketState.totalCurrentCash + netAssetCash <= 0) return 0;
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
        if (!success) return 0;
        // Sets the trade time for the next oracle update
        marketState.previousTradeTime = block.timestamp;
        marketState.storageState = marketState.storageState | STORAGE_STATE_UPDATE_TRADE;

        return netAssetCash;
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
        int exchangeRate = getExchangeRateFromImpliedRate(lastImpliedRate, timeToMaturity);
        if (exchangeRate < RATE_PRECISION) return (0, false);

        int rateAnchor;
        {
            int proportion = totalfCash
                .mul(RATE_PRECISION)
                .div(totalfCash.add(totalCashUnderlying));

            proportion = proportion
                .mul(RATE_PRECISION)
                .div(RATE_PRECISION.sub(proportion));

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
     * @notice Converts an implied rate to an exchange rate given a time to maturity. The
     * formula is E = e^rt
     */
    function getExchangeRateFromImpliedRate(
        uint impliedRate,
        uint timeToMaturity
    ) internal pure returns (int) {
        int128 expValue = ABDKMath64x64.fromUInt(
            // TODO: is this still true?
            // There is a bit of imprecision from this division here but if we use
            // int128 then we will get overflows so unclear how we can maintain the precision
            impliedRate.mul(timeToMaturity).div(IMPLIED_RATE_TIME)
        );
        int128 expValueScaled = ABDKMath64x64.div(expValue, RATE_PRECISION_64x64);
        int128 expResult = ABDKMath64x64.exp(expValueScaled);
        int128 expResultScaled = ABDKMath64x64.mul(expResult, RATE_PRECISION_64x64);

        return ABDKMath64x64.toInt(expResultScaled);
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
        require(rateOracleTimeWindow > 0); // dev: update rate oracle, time window zero

        // This can occur when using a view function get to a market state in the past
        if (previousTradeTime > blockTime) return lastImpliedRate;

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

    function getSlot(
        uint currencyId,
        uint settlementDate,
        uint maturity
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(maturity, settlementDate, currencyId, "market"));
    }

    /**
     * @notice Liquidity is not required for lending and borrowing so we don't automatically read it. This method is called if we
     * do need to load the liquidity amount.
     */
    function getTotalLiquidity(MarketParameters memory market) internal view {
        int totalLiquidity;
        bytes32 slot = bytes32(uint(market.storageSlot) + 1);

        assembly { totalLiquidity := sload(slot) }
        market.totalLiquidity = totalLiquidity;
    }

    /**
     * @notice Reads a market object directly from storage. `buildMarket` should be called instead of this method
     * which ensures that the rate oracle is set properly.
     */
    function loadMarketStorage(
        MarketParameters memory market,
        uint currencyId,
        uint maturity,
        bool needsLiquidity,
        uint settlementDate
    ) private view {
        // Market object always uses the most current reference time as the settlement date
        bytes32 slot = getSlot(currencyId, settlementDate, maturity);
        bytes32 data;

        assembly { data := sload(slot) }

        market.storageSlot = slot;
        market.maturity = maturity;
        market.totalfCash = int(uint80(uint(data)));
        market.totalCurrentCash = int(uint80(uint(data >> 80)));
        market.lastImpliedRate = uint(uint32(uint(data >> 160)));
        market.oracleRate = uint(uint32(uint(data >> 192)));
        market.previousTradeTime = uint(uint32(uint(data >> 224)));
        market.storageState = STORAGE_STATE_NO_CHANGE;

        if (needsLiquidity) {
            getTotalLiquidity(market);
        } else {
            market.totalLiquidity = 0;
        }
    }

    /**
     * @notice Writes market parameters to storage if the market is marked as updated.
     */
    function setMarketStorage(MarketParameters memory market) internal {
        if (market.storageState == STORAGE_STATE_NO_CHANGE) return;
        bytes32 slot = market.storageSlot;

        if (market.storageState & STORAGE_STATE_UPDATE_TRADE != STORAGE_STATE_UPDATE_TRADE) {
            // If no trade has occured then the oracleRate on chain should not update.
            bytes32 oldData;
            assembly { oldData := sload(slot) }
            market.oracleRate = uint(uint32(uint(oldData >> 192)));
        }

        require(market.totalfCash >= 0 && market.totalfCash <= type(uint80).max); // dev: market storage totalfCash overflow
        require(market.totalCurrentCash >= 0 && market.totalCurrentCash <= type(uint80).max); // dev: market storage totalCurrentCash overflow
        require(market.lastImpliedRate >= 0 && market.lastImpliedRate <= type(uint32).max); // dev: market storage lastImpliedRate overflow
        require(market.oracleRate >= 0 && market.oracleRate <= type(uint32).max); // dev: market storage oracleRate overflow
        require(market.previousTradeTime >= 0 && market.previousTradeTime <= type(uint32).max); // dev: market storage previous trade time overflow

        bytes32 data = (
            bytes32(market.totalfCash) |
            bytes32(market.totalCurrentCash) << 80 |
            bytes32(market.lastImpliedRate) << 160 |
            bytes32(market.oracleRate) << 192 |
            bytes32(market.previousTradeTime) << 224
        );

        assembly { sstore(slot, data) }

        if (market.storageState & STORAGE_STATE_UPDATE_LIQUIDITY == STORAGE_STATE_UPDATE_LIQUIDITY) {
            require(market.totalLiquidity >= 0 && market.totalLiquidity <= type(uint80).max); // dev: market storage totalLiquidity overflow
            slot = bytes32(uint(slot) + 1);
            bytes32 totalLiquidity = bytes32(market.totalLiquidity);

            assembly { sstore(slot, totalLiquidity) }
        }
    }

    /**
     * @notice Creates a market object and ensures that the rate oracle time window is updated appropriately.
     */
    function loadMarket(
        MarketParameters memory market,
        uint currencyId,
        uint maturity,
        uint blockTime,
        bool needsLiquidity,
        uint rateOracleTimeWindow
    ) internal view {
        // Always reference the current settlement date
        uint settlementDate = CashGroup.getReferenceTime(blockTime) + CashGroup.QUARTER;
        loadMarketWithSettlementDate(
            market,
            currencyId,
            maturity,
            blockTime,
            needsLiquidity,
            rateOracleTimeWindow,
            settlementDate
        );
    }

    /**
     * @notice Creates a market object and ensures that the rate oracle time window is updated appropriately, this
     * is mainly used in the InitializeMarketAction contract.
     */
    function loadMarketWithSettlementDate(
        MarketParameters memory market,
        uint currencyId,
        uint maturity,
        uint blockTime,
        bool needsLiquidity,
        uint rateOracleTimeWindow,
        uint settlementDate
    ) internal view {
        loadMarketStorage(
            market,
            currencyId,
            maturity,
            needsLiquidity,
            settlementDate
        );

        market.oracleRate = updateRateOracle(
            market.previousTradeTime,
            market.lastImpliedRate,
            market.oracleRate,
            rateOracleTimeWindow,
            blockTime
        );
    }

    /**
     * @notice When settling liquidity tokens we only need to get half of the market paramteers and the settlement
     * date must be specified.
     */
    function getSettlementMarket(
        uint currencyId,
        uint maturity,
        uint settlementDate
    ) internal view returns (SettlementMarket memory) {
        uint slot = uint(getSlot(currencyId, settlementDate, maturity));
        int totalLiquidity;
        bytes32 data;

        assembly { data := sload(slot) }

        int totalfCash = int(uint80(uint(data)));
        int totalCurrentCash = int(uint80(uint(data >> 80)));
        // Clear the lower 160 bits, this data will be "OR'd" with the new totalfCash
        // and totalCurrentCash figures.
        data = data & 0xffffffffffffffffffffffff0000000000000000000000000000000000000000;

        slot = uint(slot) + 1;

        assembly { totalLiquidity := sload(slot) }

        return SettlementMarket({
            storageSlot: bytes32(slot - 1),
            totalfCash: totalfCash,
            totalCurrentCash: totalCurrentCash,
            totalLiquidity: int(totalLiquidity),
            data: data
        });
    }

    function setSettlementMarket(
        SettlementMarket memory market
    ) internal {
        bytes32 slot = market.storageSlot;
        bytes32 data;
        require(market.totalfCash >= 0 && market.totalfCash <= type(uint80).max); // dev: settlement market storage totalfCash overflow
        require(market.totalCurrentCash >= 0 && market.totalCurrentCash <= type(uint80).max); // dev: settlement market storage totalCurrentCash overflow
        require(market.totalLiquidity >= 0 && market.totalLiquidity <= type(uint80).max); // dev: settlement market storage totalLiquidity overflow

        data = (
            bytes32(market.totalfCash) |
            bytes32(market.totalCurrentCash) << 80 |
            bytes32(market.data)
        );

        // Don't clear the storage even when all liquidity tokens have been removed because we need to use
        // the oracle rates to initialize the next set of markets.
        assembly { sstore(slot, data) }

        slot = bytes32(uint(slot) + 1);
        bytes32 totalLiquidity = bytes32(market.totalLiquidity);
        assembly { sstore(slot, totalLiquidity) }
    }

}


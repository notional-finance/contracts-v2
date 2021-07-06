methods {
    getRateScalar(uint256 timeToMaturity) returns (int256) envfree;
    getRateOracleTimeWindow() returns (uint256) envfree;
    getLastImpliedRate() returns (uint256) envfree;
    getStoredOracleRate() returns (uint256) envfree;
    getPreviousTradeTime() returns (uint256) envfree;
    getMarketfCash() returns (int256) envfree;
    getMarketAssetCash() returns (int256) envfree;
    getMarketLiquidity() returns (int256) envfree;
    getMarketOracleRate() returns (uint256) envfree;
    MATURITY() returns (uint256) envfree;
}

definition isBetween(uint256 x, uint256 y, uint256 z) returns bool = (y <= x && x <= z) || (z <= x && x <= y);
definition absDiff(uint256 x, uint256 y) returns uint256 = x > y ? x - y : y - x;
definition basisPoint() returns uint256 = 100000;
definition QUARTER() returns uint256 = 86400 * 90;

/**
 * Oracle rates are blended into the rate window given the rate oracle time window.
 */
invariant oracleRatesAreBlendedIntoTheRateWindow(
    uint256 blockTime,
    uint256 previousTradeTime
)
    (previousTradeTime + getRateOracleTimeWindow() >= blockTime) ?
        getMarketOracleRate() == getLastImpliedRate() :
        isBetween(
            getStoredOracleRate(),
            getMarketOracleRate(),
            getLastImpliedRate()
        )

rule executeTradeMovesImpliedRates(
    int256 fCashToAccount,
    uint256 timeToMaturity
) {
    env e;
    require fCashToAccount != 0;
    require getRateScalar(timeToMaturity) > 0;
    uint256 lastImpliedRate = getLastImpliedRate();
    int256 marketfCashBefore = getMarketfCash();
    int256 marketAssetCashBefore = getMarketAssetCash();
    int256 assetCashToAccount;
    int256 assetCashToReserve;

    assetCashToAccount, assetCashToReserve = executeTrade(e, timeToMaturity, fCashToAccount);
    assert fCashToAccount > 0 ? 
        // When fCashToAccount > 0 then lending, implied rates should decrease
        lastImpliedRate > getLastImpliedRate() :
        // When fCashToAccount < 0 then borrowing, implied rates should increase
        lastImpliedRate < getLastImpliedRate(),
        "last trade rate did not move in correct direction";
    assert fCashToAccount > 0 ? assetCashToAccount < 0 : assetCashToAccount > 0, "incorrect asset cash for fCash";
    assert assetCashToReserve >= 0, "asset cash to reserve cannot be negative";
    assert getPreviousTradeTime() == e.block.timestamp, "previous trade time did not update";
    assert getMarketfCash() - fCashToAccount == marketfCashBefore, "Market fCash does not net out";
    assert getMarketAssetCash() - assetCashToAccount - assetCashToReserve == marketAssetCashBefore,
        "Market asset cash does not net out";
}

rule impliedRatesDoNotChangeOnAddLiquidity(
    int256 cashAmount
) {
    env e;
    require cashAmount > 0;
    uint256 previousTradeTime = getPreviousTradeTime();
    uint256 oracleRate = getStoredOracleRate();
    uint256 lastImpliedRate = getLastImpliedRate();
    int256 marketfCashBefore = getMarketfCash();
    int256 marketAssetCashBefore = getMarketAssetCash();
    int256 marketLiquidityBefore = getMarketLiquidity();
    require marketfCashBefore >= 0 && marketfCashBefore <= 2^80 - 1;
    require marketAssetCashBefore >= 0 && marketAssetCashBefore <= 2^80 - 1;
    require marketLiquidityBefore >= 0 && marketLiquidityBefore <= 2^80 - 1;
    require previousTradeTime >= 0 && previousTradeTime <= 2^32 - 1;
    require lastImpliedRate >= 0 && lastImpliedRate <= 2^32 - 1;
    require oracleRate >= 0 && oracleRate <= 2^32 - 1;

    int256 liquidityTokens;
    int256 fCashToAccount;
    uint8 storageState;
    liquidityTokens, fCashToAccount, storageState = addLiquidity(e, cashAmount);

    assert storageState == 1, "storage state is not set";

    int256 marketfCashAfter = getMarketfCash();
    int256 marketAssetCashAfter = getMarketAssetCash();
    int256 marketLiquidityAfter = getMarketLiquidity();
    assert getLastImpliedRate() == lastImpliedRate, "last trade rate did update";
    assert marketAssetCashBefore + cashAmount == marketAssetCashAfter, "market asset cash imbalance";
    assert fCashToAccount + marketfCashAfter == marketfCashBefore, "net fCash is not zero";
    assert liquidityTokens + marketLiquidityBefore == marketLiquidityAfter, "liquidity token imbalance";
    assert getPreviousTradeTime() == previousTradeTime, "previous trade time did update";
}

rule impliedRatesDoNotChangeOnRemoveLiquidity(
    int256 tokenAmount
) {
    env e;
    require tokenAmount > 0;
    uint256 previousTradeTime = getPreviousTradeTime();
    uint256 oracleRate = getStoredOracleRate();
    uint256 lastImpliedRate = getLastImpliedRate();
    int256 marketfCashBefore = getMarketfCash();
    int256 marketAssetCashBefore = getMarketAssetCash();
    int256 marketLiquidityBefore = getMarketLiquidity();
    require marketfCashBefore >= 0 && marketfCashBefore <= 2^80 - 1;
    require marketAssetCashBefore >= 0 && marketAssetCashBefore <= 2^80 - 1;
    require marketLiquidityBefore >= 0 && marketLiquidityBefore <= 2^80 - 1;
    require previousTradeTime >= 0 && previousTradeTime <= 2^32 - 1;
    require lastImpliedRate >= 0 && lastImpliedRate <= 2^32 - 1;
    require oracleRate >= 0 && oracleRate <= 2^32 - 1;

    require marketLiquidityBefore >= tokenAmount;

    int256 assetCash;
    int256 fCash;
    assetCash, fCash = removeLiquidity(e, tokenAmount);

    int256 marketfCashAfter = getMarketfCash();
    int256 marketAssetCashAfter = getMarketAssetCash();
    int256 marketLiquidityAfter = getMarketLiquidity();
    assert marketAssetCashBefore - assetCash == marketAssetCashAfter, "market asset cash imbalance";
    assert marketfCashBefore - fCash == marketfCashAfter, "fCash imbalance";
    assert marketLiquidityBefore - tokenAmount == marketLiquidityAfter, "liquidity token imbalance";
    assert getPreviousTradeTime() == previousTradeTime, "previous trade time did update";
    assert getLastImpliedRate() == lastImpliedRate, "last trade rate did update";
}

// The amount of slippage for a given size of trade should not change in terms of the implied rate
// over the course of the market. If this is the case then arbitrage opportunities could arise. In the V2
// liquidity curve this is not perfect so we show that the slippage is below some tolerable epsilon over
// the course of a quarter.
rule impliedRateSlippageDoesNotChangeWithTime(
    int256 fCashToAccount,
    uint256 timeDelta
) {
    env e;
    // Ensure that the block time is within the tradeable region
    require timeDelta <= QUARTER() && e.block.timestamp + timeDelta < MATURITY();
    require fCashToAccount != 0;
    uint256 timeToMaturity_first = MATURITY() - e.block.timestamp;
    uint256 timeToMaturity_second = MATURITY() - e.block.timestamp - timeDelta;
    require getRateScalar(timeToMaturity_first) > 0;
    require getRateScalar(timeToMaturity_second) > 0;

    storage initStorage = lastStorage;
    executeTrade(e, timeToMaturity_first, fCashToAccount);
    uint256 lastImpliedRate_first = getLastImpliedRate();

    executeTrade(e, timeToMaturity_second, fCashToAccount) at initStorage;
    uint256 lastImpliedRate_second = getLastImpliedRate();

    assert absDiff(lastImpliedRate_first, lastImpliedRate_second) < basisPoint(),
        "Last implied rate slippage increases with time";
}

// invariant fCashAndCashAmountsConverge
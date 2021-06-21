methods {
    getRateScalar(uint256 timeToMaturity) returns (uint256) envfree;
    getLastImpliedRate() returns (uint256) envfree;
    getStoredOracleRate() returns (uint256) envfree;
    getPreviousTradeTime() returns (uint256) envfree;
    getMarketfCash() returns (uint256) envfree;
    getMarketAssetCash() returns (uint256) envfree;
    getMarketLiquidity() returns (uint256) envfree;
    getOracleRate() returns (uint256) envfree;
}

/**
 * Oracle rates are blended into the rate window given the rate oracle time window.
 */
invariant oracleRatesAreBlendedIntoTheRateWindow(
    uint256 blockTime,
    uint256 previousTradeTime
)
    previousTradeTime + getRateOracleTimeWindow() >= blockTime ?
        getOracleRate() == getLastImpliedRate() :
        isBetween(
            getOracleRate(),
            getLastTradeRate(),
            getLastImpliedRate()
        )

rule executeTradeMovesImpliedRates(
    int256 fCashToAccount,
    uint256 timeToMaturity
) {
    env e;
    require fCashToAccount != 0;
    require getRateScalar(timeToMaturity) > 0;
    uint256 lastTradeRate = getLastTradeRate();
    uint256 marketfCashBefore = getMarketfCash();
    uint256 marketAssetCashBefore = getMarketAssetCash();

    int256 assetCashToAccount, int256 assetCashToReserve = executeTrade(e, fCashToAccount, timeToMaturity);
    assert fCashToAccount > 0 ? 
        // When fCashToAccount > 0 then lending, implied rates should decrease
        lastTradeRate > getLastTradeRate() :
        // When fCashToAccount < 0 then borrowing, implied rates should increase
        lastTradeRate < getLastTradeRate(),
        "last trade rate did not move in correct direction";
    assert fCashToAccount > 0 ? assetCashToAccount < 0 : assetCashToAccount > 0, "incorrect asset cash for fCash";
    assert assetCashToReserve >= 0, "asset cash to reserve cannot be negative";
    assert getLastTradeTime() == e.block.timestamp, "previous trade time did not update"
    assert getMarketfCash() - fCashToAccount == marketfCashBefore, "Market fCash does not net out";
    assert getMarketAssetCash() - assetCashToAccount - assetCashToReserve == marketAssetCashBefore,
        "Market asset cash does not net out";
}

rule impliedRatesDoNotChangeOnAddLiquidity(
    uint256 cashAmount
) {
    env e;
    require getMarketProportion > 0;
    uint256 lastTradeTime = getLastTradeRate();
    uint256 lastTradeRate = getLastTradeRate();
    uint256 marketProportion = getMarketProportion();

    addLiquidity(e, cashAmount);
    assert getLastTradeTime() == lastTradeTime, "previous trade time did update"
    assert getLastTradeRate() == lastTradeRate, "last trade rate did update"
    assert getMarketProportion() == marketProportion, "market proportion changed on add liquidity"
}

rule impliedRatesDoNotChangeOnRemoveLiquidity(
    uint256 tokenAmount
) {
    env e;
    uint256 marketLiquidityBefore = getMarketLiquidity();
    require marketLiquidityBefore >= tokenAmount;
    uint256 lastTradeTime = getLastTradeRate();
    uint256 lastTradeRate = getLastTradeRate();
    uint256 marketProportion = getMarketProportion();

    removeLiquidity(e, tokenAmount);
    assert getLastTradeTime() == lastTradeTime, "previous trade time did update"
    assert getLastTradeRate() == lastTradeRate, "last trade rate did update"
    // Check this or it will fail on remove down to zero
    assert marketLiquidityBefore > tokenAmount =>
        getMarketProportion() == marketProportion, "market proportion changed on remove liquidity"
}

// invariant impliedRateSlippageDoesNotChangeWithTime (not entirely true....)
// invariant fCashAndCashAmountsConverge
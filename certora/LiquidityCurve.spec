/**
 * Build a harness that is just a single market which you can add / remove / lend / borrow on
 */

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

rule impliedRatesIncreaseWithBorrowing(
    int256 fCashToAccount,
    uint256 timeToMaturity
) {
    env e;
    require fCashAmount < 0;
    require getRateScalar(timeToMaturity) > 0;
    uint256 lastTradeRate = getLastTradeRate();

    // TODO: encode market index in the function
    executeTrade(e, fCashToAccount, timeToMaturity);
    assert getLastTradeTime() == e.block.timestamp, "previous trade time did not update"
    assert lastTradeRate < getLastTradeRate(), "last trade rate did not increase";
}

rule impliedRatesDecreaseWithLending(
    int256 fCashToAccount,
    uint256 timeToMaturity
) {
    env e;
    require fCashAmount > 0;
    require getRateScalar(timeToMaturity) > 0;
    uint256 lastTradeRate = getLastTradeRate();

    // TODO: encode market index in the function
    executeTrade(e, fCashToAccount, timeToMaturity);
    assert getLastTradeTime() == e.block.timestamp, "previous trade time did not update"
    assert lastTradeRate > getLastTradeRate(), "last trade rate did not decrease"
}

rule impliedRatesDoNotChangeOnLiquidity(
    uint256 cashAmount
) {
    env e;
    uint256 lastTradeTime = getLastTradeRate();
    uint256 lastTradeRate = getLastTradeRate();

    // TODO: encode market index in the function
    addLiquidity(e, cashAmount);
    assert getLastTradeTime() == lastTradeTime, "previous trade time did update"
    assert getLastTradeRate() == lastTradeRate, "last trade rate did update"
}

rule impliedRatesDoNotChangeOnLiquidity(
    uint256 cashAmount
) {
    env e;
    require getMarketCashAmount() >= cashAmount;
    uint256 lastTradeTime = getLastTradeRate();
    uint256 lastTradeRate = getLastTradeRate();

    // TODO: encode market index in the function
    removeLiquidity(e, cashAmount);
    assert getLastTradeTime() == lastTradeTime, "previous trade time did update"
    assert getLastTradeRate() == lastTradeRate, "last trade rate did update"
}


// invariant slippageDecreasesWithTimeToMaturity
// invariant fCashAndCashAmountsConverge

// not sure if this belongs here...
// rule cashBalancesRemainInBalance()
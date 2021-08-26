methods {
    getRateScalar(uint256 timeToMaturity) returns (int256) envfree;
    getRateOracleTimeWindow() returns (uint256) envfree;
    getLastImpliedRate() returns (uint256) envfree;
    getPreviousTradeTime() returns (uint256) envfree;
    getMarketfCash() returns (int256) envfree;
    getMarketAssetCash() returns (int256) envfree;
    getMarketLiquidity() returns (int256) envfree;
    getMarketOracleRate() returns (uint256) envfree;
    MATURITY() returns (uint256) envfree;
    executeTrade(uint256 timeToMaturity, int256 fCashToAccount) returns (int256,int256) envfree;
    getStoredOracleRate() returns (uint256);

   a_minus_b(int256 a, int256 b) returns (int256) envfree;
   a_plus_b(int256 a, int256 b) returns (int256) envfree;
   isEqual(int256 a, int256 b) returns (bool) envfree;

    // Market
    ////////////////

    // getExchangeRateFactors((bytes32,uint256,int256,int256,int256,uint256,uint256,uint256,bytes1),(uint256,uint256,(address,int256,int256),bytes32),uint256,uint256) => NONDET
     _getExchangeRate(int256,int256,int256,int256,int256) => NONDET
    // getImpliedRate(int256,int256,int256,int256,uint256) => NONDET

}

definition isBetween(uint256 x, uint256 y, uint256 z) returns bool = (y <= x && x <= z) || (z <= x && x <= y);
definition absDiff(uint256 x, uint256 y) returns uint256 = x > y ? x - y : y - x;
definition basisPoint() returns uint256 = 100000;
definition QUARTER() returns uint256 = 86400 * 90;

///
/// Oracle rates are blended into the rate window given the rate oracle time window.
///

invariant oracleRatesAreBlendedIntoTheRateWindow(env e)
    (e.block.timestamp - getPreviousTradeTime() > getRateOracleTimeWindow()) ?
        getMarketOracleRate() == getLastImpliedRate() :
        isBetween(
            getStoredOracleRate(e),
            getMarketOracleRate(),
            getLastImpliedRate()
        )


rule oracleRatesBlandedIntoRateWindow(method f){
env e;

uint marketOracleRate_1 = getMarketOracleRate();
uint lastImpliedRate_1 = getLastImpliedRate();
uint previousTradeTime_1 = getPreviousTradeTime();
uint rateOracleTimeWindow_1 = getRateOracleTimeWindow();
uint storedOracleRate_1 = getStoredOracleRate(e);

require e.block.timestamp > previousTradeTime_1;

// require (e.block.timestamp - previousTradeTime_1 > rateOracleTimeWindow_1 =>
        // marketOracleRate_1 == lastImpliedRate_1, "require 1_");
// require (e.block.timestamp - previousTradeTime_1 <= rateOracleTimeWindow_1 =>
        // isBetween(storedOracleRate_1,marketOracleRate_1,lastImpliedRate_1), "require 2_");

// calldataarg args;
// f(e,args);

    int256 fCashToAccount;
    uint256 timeToMaturity;
    int256 assetCashToAccount;
    int256 assetCashToReserve;
    require fCashToAccount != 0;
    require getRateScalar(timeToMaturity) > 0;

    assetCashToAccount,assetCashToReserve = executeTrade( timeToMaturity, fCashToAccount);
    require (assetCashToReserve >= 0, "asset cash to reserve cannot be negative");

uint marketOracleRate_2 = getMarketOracleRate();
uint lastImpliedRate_2 = getLastImpliedRate();
uint previousTradeTime_2 = getPreviousTradeTime();
uint rateOracleTimeWindow_2 = getRateOracleTimeWindow();
uint storedOracleRate_2 = getStoredOracleRate(e);

require (fCashToAccount < 0 => lastImpliedRate_1 > lastImpliedRate_2,"last trade rate did not move in correct direction");

// require 
//         lastImpliedRate_1 > 0 && lastImpliedRate_2 > 0 &&
//         marketOracleRate_1 > 0 && marketOracleRate_2 > 0 &&
//         previousTradeTime_1 > 0 && previousTradeTime_2 > 0 &&
//         rateOracleTimeWindow_1 > 0 && rateOracleTimeWindow_2 > 0 &&
//         storedOracleRate_1 > 0 && storedOracleRate_2 > 0;

require (e.block.timestamp > previousTradeTime_2, "previous trade time did not update");

require lastImpliedRate_2 != 0;

assert (e.block.timestamp - previousTradeTime_2 > rateOracleTimeWindow_2 =>
        marketOracleRate_2 == lastImpliedRate_2, "assert 1_");
// assert (e.block.timestamp - previousTradeTime_2 <= rateOracleTimeWindow_2 =>
        // isBetween(storedOracleRate_2,marketOracleRate_2,lastImpliedRate_2), "assert 2_");
}

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

    assetCashToAccount, assetCashToReserve = executeTrade( timeToMaturity, fCashToAccount);
    require assetCashToAccount != 0 && assetCashToReserve != 0;
    require (fCashToAccount < 0 => lastImpliedRate > getLastImpliedRate(),"last trade rate did not move in correct direction");
    
    // assert fCashToAccount > 0 ? 
    //     // When fCashToAccount > 0 then lending, implied rates should decrease
    //     lastImpliedRate > getLastImpliedRate() :
    //     // When fCashToAccount < 0 then borrowing, implied rates should increase
    //     lastImpliedRate < getLastImpliedRate(),
    //     "last trade rate did not move in correct direction";

    require (fCashToAccount > 0 ? assetCashToAccount < 0 : assetCashToAccount > 0, "incorrect asset cash for fCash");
    int256 marketfCashAfter = getMarketfCash();
    int256 marketAssetCashAfter = getMarketAssetCash();
    require (assetCashToReserve >= 0, "asset cash to reserve cannot be negative");
    require (getPreviousTradeTime() < e.block.timestamp, "previous trade time did not update");
    // assert  to_mathint(marketfCashBefore) ==  to_mathint(fCashToAccount) + to_mathint(marketfCashAfter), "Market fCash does not net out";
   

    // require marketfCashBefore < 1000 &&
    //         marketAssetCashBefore < 1000 &&
    //         assetCashToAccount < 1000 &&
    //         assetCashToReserve < 1000 &&
    //         marketfCashAfter < 1000 &&
    //         marketAssetCashAfter < 1000;
            
    // Jeff's NEW VERSION assert getMarketAssetCash() == marketAssetCashBefore - assetCashToAccount - assetCashToReserve;
    // int256 a_minus_b_minus_c = to_int256(marketAssetCashBefore - assetCashToAccount - assetCashToReserve);
    // int256 a_minus_b_minus_c = to_int256(to_mathint(marketAssetCashBefore) - to_mathint(assetCashToAccount) - to_mathint(assetCashToReserve));
    // require a_minus_b_minus_c >= 0;
    // assert a_minus_b_minus_c == marketAssetCashAfter, //marketAssetCashBefore,
    //     "Market asset cash does not net out";
    assert to_mathint(marketAssetCashAfter) == to_mathint(marketAssetCashBefore) - to_mathint(assetCashToAccount) - to_mathint(assetCashToReserve), //marketAssetCashBefore,
        "Market asset cash does not net out";
}

rule testAssetCash(int256 fCashToAccount, uint256 timeToMaturity){
    // require timeToMaturity <= 2^255-1;
    // require timeToMaturity > 0;
    // require fCashToAccount != 0;
    int256 marketAssetCashBefore = getMarketAssetCash();
    int256 assetCashToAccount;
    int256 assetCashToReserve;
    assetCashToAccount, assetCashToReserve = executeTrade(timeToMaturity, fCashToAccount);
    // require (assetCashToReserve > 0, "asset cash to reserve cannot be negative");
    int256 marketAssetCashAfter = getMarketAssetCash();
    assert marketAssetCashAfter > marketAssetCashBefore;
}

rule impliedRatesDoNotChangeOnAddLiquidity(
    int256 cashAmount
) {
    env e;
    require cashAmount > 0;
    uint256 previousTradeTime = getPreviousTradeTime();
    uint256 oracleRate = getStoredOracleRate(e);
    uint256 lastImpliedRate = getLastImpliedRate();
    int256 marketfCashBefore = getMarketfCash();
    int256 marketAssetCashBefore = getMarketAssetCash();
    int256 marketLiquidityBefore = getMarketLiquidity();
    require marketfCashBefore >= 0 && marketfCashBefore <= to_int256(2^80 - 1);
    require marketAssetCashBefore >= 0 && marketAssetCashBefore <= to_int256(2^80 - 1);
    require marketLiquidityBefore >= 0 && marketLiquidityBefore <= to_int256(2^80 - 1);
    require previousTradeTime >= 0 && previousTradeTime <= 2^32 - 1;
    require lastImpliedRate >= 0 && lastImpliedRate <= 2^32 - 1;
    require oracleRate >= 0 && oracleRate <= 2^32 - 1;

    int256 liquidityTokens;
    int256 fCashToAccount;
    liquidityTokens, fCashToAccount = addLiquidity(e, cashAmount);


    int256 marketfCashAfter = getMarketfCash();
    int256 marketAssetCashAfter = getMarketAssetCash();
    int256 marketLiquidityAfter = getMarketLiquidity();
   assert to_mathint(marketfCashBefore) - to_mathint(fCashToAccount) == to_mathint(marketfCashAfter), "fCash imbalance";
    // assert getLastImpliedRate() == lastImpliedRate, "last trade rate did update";
    // assert to_mathint(marketAssetCashBefore) + to_mathint(cashAmount) == to_mathint(marketAssetCashAfter), "market asset cash imbalance";
    // assert to_mathint(liquidityTokens) + to_mathint(marketLiquidityBefore) == to_mathint(marketLiquidityAfter), "liquidity token imbalance";
    // assert getPreviousTradeTime() == previousTradeTime, "previous trade time did update ";
}

rule impliedRatesDoNotChangeOnRemoveLiquidity(
    int256 tokenAmount
) {
    env e;
    require tokenAmount > 0;
    uint256 previousTradeTime = getPreviousTradeTime();
    uint256 oracleRate = getStoredOracleRate(e);
    uint256 lastImpliedRate = getLastImpliedRate();
    int256 marketfCashBefore = getMarketfCash();
    int256 marketAssetCashBefore = getMarketAssetCash();
    int256 marketLiquidityBefore = getMarketLiquidity();
    require marketfCashBefore >= 0 && marketfCashBefore <= to_int256(2^80 - 1);
    require marketAssetCashBefore >= 0 && marketAssetCashBefore <= to_int256(2^80 - 1);
    require marketLiquidityBefore >= 0 && marketLiquidityBefore <= to_int256(2^80 - 1);
    require previousTradeTime >= 0 && previousTradeTime <= 2^32 - 1;
    require lastImpliedRate >= 0 && lastImpliedRate <= 2^32 - 1;
    require oracleRate >= 0 && oracleRate <= 2^32 - 1;

    require marketLiquidityBefore >= tokenAmount;

    int256 assetCash;
    int256 fCashToAccount;
    assetCash, fCashToAccount = removeLiquidity(e, tokenAmount);

    require fCashToAccount != 0;

    int256 marketfCashAfter = getMarketfCash();
    int256 marketAssetCashAfter = getMarketAssetCash();
    int256 marketLiquidityAfter = getMarketLiquidity();
    uint256 previousTradeTimeAfter = getPreviousTradeTime();
    uint256 lastImpliedRateAfter = getLastImpliedRate();
    assert to_mathint(marketAssetCashBefore) - to_mathint(assetCash) == to_mathint(marketAssetCashAfter), "market asset cash imbalance";
    assert to_mathint(marketfCashBefore) - to_mathint(fCashToAccount) == to_mathint(marketfCashAfter), "fCash imbalance";
    assert to_mathint(marketLiquidityBefore) - to_mathint(tokenAmount) == to_mathint(marketLiquidityAfter), "liquidity token imbalance";
    assert previousTradeTimeAfter == previousTradeTime, "previous trade time did update";
    assert lastImpliedRateAfter == lastImpliedRate, "last trade rate did update";
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
    executeTrade(timeToMaturity_first, fCashToAccount);
    uint256 lastImpliedRate_first = getLastImpliedRate();

    executeTrade(timeToMaturity_second, fCashToAccount) at initStorage;
    uint256 lastImpliedRate_second = getLastImpliedRate();

    require lastImpliedRate_first < 1000000 && lastImpliedRate_second < 1000000;

    assert absDiff(lastImpliedRate_first, lastImpliedRate_second) < basisPoint(),
        "Last implied rate slippage increases with time";
}


rule sanity(method f) {
    env e;
    calldataarg args;
    f(e,args);
    assert false;
}

methods {
    getPresentValue(int256, uint256, uint256, uint256) returns (int256) envfree
}

definition isBetween(uint256 x, uint256 y, uint256 z) returns bool = (y <= x && x <= z) || (z <= x && x <= y);

// SLOAD hooks
hook Sload cashGroup {
    require(oracleRate == 0)
    require(fCashHaircut == x)
    require(debtBuffer == x)
    require(liquidityTokenHaircut == 100)

hook Sload market {
    require(market.totalfCash == 1000e9)
    require(market.totalAssetCash == 1000e9)
    require(market.totalLiquidity == 1000e9)
}


// This requires multi markets, should be in a valuation spec
invariant idiosyncraticOracleRatesAreBetweenOnChainRates(
    uint256 currencyId,
    uint256 maturity,
    uint256 shortMarketIndex,
    uint256 longMarketIndex
)
    isBetween(
        maturity,
        getMaturityAtMarketIndex(currencyId, shortMarketIndex),
        getMaturityAtMarketIndex(currencyId, longMarketIndex),
    ) => 
    isBetween(
        getOracleRateAtMaturity(currencyId, maturity),
        getOracleAtMarketIndex(currencyId, shortMarketIndex),
        getOracleAtMarketIndex(currencyId, longMarketIndex)
    )

rule presentValueIsLessThanFutureValue(
    int256 notional,
    uint256 maturity,
    uint256 oracleRate
) {
    require notional != 0;
    // TODO: requires for timestamps (todo, with and without haircuts)
    int256 pv = getPresentValue(notional, maturity, e.block.timestamp, oracleRate);

    // Absolute value of PV is less than Notional value always
    assert notional > 0 ? pv < notional : notional < pv;
}

rule liquidityTokenValueMatchesClaims(
    int256 fCashNotional,
    int256 tokens,
    uint256 totalfCash,
    uint256 totalAssetCash,
    uint256 totalLiquidity,
    uint8 tokenHaircut
) {

}

rule portfolioIsAlwaysSorted {

}

rule freeCollateralAccountsForAllAssetsAndBalances {
    // todo: need to havoc eth rates and nToken PV
}

methods {
    getPresentValue(int256, uint256, uint256, uint256) returns (int256) envfree
}

definition isBetween(uint256 x, uint256 y, uint256 z) returns bool = (y <= x && x <= z) || (z <= x && x <= y);

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
    // TODO: requires for timestamps
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

rule portfolioValueIsSumOfAssets {

}

rule freeCollateralAccountsForAllAssetsAndBalances {

}

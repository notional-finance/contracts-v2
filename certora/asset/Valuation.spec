methods {
    getPresentValue(int256, uint256, uint256, uint256) returns (int256) envfree
}

definition abs(int256 x) returns int256 = x >= 0 ? x : -1 * x;
definition isBetween(uint256 x, uint256 y, uint256 z) returns bool = (y <= x && x <= z) || (z <= x && x <= y);
// PV basis points are defined in 5 basis point increments up to the max uint8 value.
definition BASIS_POINT() returns uint256 = 100000;
definition MAX_PV_BASIS_POINTS() returns uint256 = BASIS_POINT() * 5 * 255;

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
    ), "idiosyncratic oracle rate is not between market rates"

rule presentValueIsLessThanFutureValue(
    int256 notional,
    uint256 maturity,
    uint256 oracleRate,
    uint256 blockTime
) {
    require notional != 0;
    require 0 < g_getDebtBuffer() && g_getDebtBuffer() <= MAX_PV_BASIS_POINTS();
    require 0 < g_getfCashHaircut() && g_getfCashHaircut() <= MAX_PV_BASIS_POINTS();
    require MIN_TIMESTAMP() <= blockTime;
    // If the timestamp is greater than the maturity than the method should revert.
    int256 pv = getPresentValue(notional, maturity, blockTime, oracleRate, false);
    int256 adjustedPV = getPresentValue(notional, maturity, blockTime, oracleRate, true);

    // PV must be the same sign as notional
    assert notional > 0 ? pv > 0 : pv < 0, "pv is not the same sign as notional"
    // Pv is always closer to zero than notional
    assert abs(pv) < abs(notional), "abs of pv is not less than abs of notional";
    // Adjusted PV is always less than pv. Positive values are haircut down, negative values are buffered lower
    assert adjustedPV < pv, "adjusted pv is greater than pv";
}

rule liquidityTokenValueAssetCashClaim(
    int256 tokenAmount,
    uint8 marketIndex,
    uint256 blockTime
) {
    env e;
    require g_getTokenHaircut(marketIndex) <= 100;
    require MIN_MARKET_INDEX() <= marketIndex && marketIndex <= MAX_MARKET_INDEX();
    uint256 totalAssetCash = getMarketAssetCash(marketIndex);
    uint256 totalLiquidity = getMarketLiquidity(marketIndex);
    int256 assetCashClaim;
    int256 haircutAssetCashClaim;

    assetCashClaim, _ = getLiquidityTokenValue(marketIndex, tokenAmount, 0, blockTime, false);
    haircutAssetCashClaim, _ = getLiquidityTokenValue(marketIndex, tokenAmount, 0, blockTime, true);

    assert (totalAssetCash * tokenAmount) / totalLiquidity == assetCashClaim, "asset cash claim is not proportional to total liquidity";
    assert (haircutAssetCashClaim * 100) / assetCashClaim == g_getTokenHaircut(marketIndex), "haircut asset cash claim is incorrect";
}

rule liquidityTokenValuefCashResidual(
    int256 fCash,
    int256 tokenAmount,
    uint8 marketIndex,
    uint256 blockTime
) {
    require g_getTokenHaircut(marketIndex) <= 100;
    // Set the oracle rate and discount buffers to zero so that we just get the notional value of the residual
    require getOracleRateAtMarketIndex(currencyId, marketIndex) == 0;
    require g_getDebtBuffer() == 0;
    require g_getfCashHaircut() == 0;
    require MIN_MARKET_INDEX() <= marketIndex && marketIndex <= MAX_MARKET_INDEX();
    uint256 totalfCash = getMarketfCash(marketIndex)
    uint256 totalLiquidity = getMarketLiquidity(marketIndex)
    int256 fCashResidual;
    int256 haircutfCashResidual;

    _, fCashResidual = getLiquidityTokenValue(marketIndex, tokenAmount, fCash, blockTime, false);
    _, haircutfCashResidual = getLiquidityTokenValue(marketIndex, tokenAmount, fCash, blockTime, true);

    assert ((totalfCash * tokenAmount) / totalLiquidity + fCash) == fCashResidual, "fCash residual is not net off properly";
    assert (haircutfCashResidual * 100) / fCashResidual == g_getTokenHaircut(marketIndex), "haircut fCash residual is incorrect";
}

rule liquidityTokenValuefCashDiscount(
    int256 fCash,
    int256 tokenAmount,
    uint8 marketIndex,
    uint256 blockTime
) {
    require g_getTokenHaircut(marketIndex) <= 100;
    require MIN_MARKET_INDEX() <= marketIndex && marketIndex <= MAX_MARKET_INDEX();
    uint256 totalfCash = getMarketfCash(marketIndex);
    uint256 totalLiquidity = getMarketLiquidity(marketIndex);
    uint256 oracleRate = getOracleRateAtMarketIndex(currencyId, marketIndex);
    int256 residualfCash = ((totalfCash * tokenAmount) / totalLiquidity + fCash);
    int256 residualfCashHaircut = (((totalfCash * tokenAmount) / totalLiquidity + fCash)) * g_getTokenHaircut(marketIndex) / 100;

    int256 fCashResidualPV;
    int256 haircutfCashResidualPV;
    _, fCashResidualPV = getLiquidityTokenValue(marketIndex, tokenAmount, fCash, blockTime, false);
    _, haircutfCashResidualPV = getLiquidityTokenValue(marketIndex, tokenAmount, fCash, blockTime, false);

    // This present value is not risk adjusted
    assert fCashResidualPV == getPresentValue(residualfCash, maturity, blockTime, oracleRate, false);
    // This present value is risk adjusted
    assert haircutfCashResidualPV == getPresentValue(residualfCashHaircut, maturity, blockTime, oracleRate, true);
}

// TODO: move these into a separate file
// @given presentValueIsLessThanFutureValue
rule bitmapifCashValuationSumOfAssets {
    // set a ghost that AssetHandler.getPresentValue returns notional
}

rule bitmapifCashValuationHasDebt {
    // set a ghost that AssetHandler.getPresentValue returns notional
}

invariant nTokenPortfolioAssets { 
    // nToken must only have cash balance for its given currency
    // nToken must have 1 liquidity token for every market
    // nToken must only have 1 fCash asset for each liquidity token
    // nToken must only have 1 residual asset at -90 days from fCash asset
}

/** Free Collateral **/
rule freeCollateralVisitsAllCashBalances {
    // set a flag on sload that the value was loaded?
}

rule freeCollateralNetsOffLocalAssetValues {
    require cashBalance < 0 || netPortfolioValue < 0 || nTokenValue < 0;
    // portfolio with multiple assets in the same currency should net off
    int256 netLocalValue = cashBalance + netPortfolioValue + nTokenValue
    fc = freeCollateral(account)
    assert fc == netLocalValue * ethRate * bufferOrHaircut(fc)
}

rule variousFreeCollateralMethodsMatchReturnValues {
    // todo
}
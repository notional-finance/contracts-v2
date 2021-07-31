/**
 * Set of rules and invariants to ensure that the valuation framework that calculates
 * free collateral works properly. The valuation framework can be thought of as the
 * following formula (implemented in internal/valuation/FreeCollateral.sol):
 *   ethDenominatedFC = sum([
 *      convertToETH(
 *         cashBalance + 
 *         discountToPresentValue(nTokenBalance) +
 *         discountToPresentValue(portfolio)
 *      )
 *      for each currency
 *  ])
 *
 * hasDebt flags are also updated as a result of these calculations:
 *  - inside _getBitmapPortfolioValue
 *  - last lines of getFreeCollateralStateful
 * 
 * Component functions include:
 *  - convertToETH: internal/valuation/ExchangeRate.sol
 *  - discountToPresentValue(nTokenBalance): internal/valuation/FreeCollateral.sol#_getNTokenHaircutAssetPV
 *    NOTE: this method will simply call the two methods below to get the value of the nToken portfolio.
 *
 *  These are implemented in two different ways for different portfolios:
 *  - discountToPresentValue(portfolio): internal/valuation/AssetHandler.sol#getNetCashGroupValue
 *  - discountToPresentValue(portfolio): internal/portfolio/BitmapAssetsHandler.sol#getifCashNetPresentValue
 *
 * Looking at discounting to present value, there are two potential types of assets:
 *  - fCash: present value = notional * e ^ (oracleRate +/- (debt buffer or haircut) * time)
 *      - Depend on the current market oracle rate
 *  - liquidity token's value is split into two components:
 *      - fCash claim: net off against negative fCash
 *      - asset cash claim: is already in present value terms
 *      - Depend on the current market state
 *
 * An approach to proving the valuation framework is correct may be to break down
 * each one of these components and show a proof that they are correct individually
 * and then compose them together.
 */

invariant convertToETHBuffersAndHaircuts {
    // show that balances > 0 will be haircut
    // show that balances < 0 will be buffered
}

rule getBitmapPortfolioValueSetsDebtFlag {
    // if any ifCash asset is < 0 then hasDebt will be set to true
    // else will be set to false
}

rule getFreeCollateralSetsCashDebt {
    // if any cash debt is < 0 then hasCashDebt will be set to true
    // else will be set to false
}

/**
 * Present value calculations have a long chain of logic they follow:
 *  - market.getOracleRate()
 *  - cashGroup.calculateOracleRate()
 *  - assetHandler.getRiskAdjustedPresentValue()
 *     - cashGroup.getDebtBuffer or cashGroup.getfCashHaircut
 */

// rule oracleRatesAreBlendedIntoTheRateWindow will cover `getOracleRate`

// This should show that the oracle rate is the linear interpolation between two on chain rates.
invariant calculateOracleRateIsBetweenOnChainRates(
    uint256 currencyId,
    uint256 maturity,
    uint256 shortMarketIndex,
    uint256 longMarketIndex
)
    isBetween(
        maturity,
        getMaturityAtMarketIndex(shortMarketIndex, blockTime),
        getMaturityAtMarketIndex(longMarketIndex, blockTime),
    ) => 
    isBetween(
        calculateOracleRate(currencyId, maturity),
        calculateOracleRate(currencyId, getMaturityAtMarketIndex(shortMarketIndex, blockTime)),
        calculateOracleRate(currencyId, getMaturityAtMarketIndex(longMarketIndex, blockTime))
    )

// For any given asset and oracle rate, the absolute present value of a shorted dated asset will
// always be less than the absolute present value of a longer dated asset.
rule presentValueDecreasesForLongerMaturities(
    int256 notional,
    uint256 maturity,
    uint256 maturityDelta,
    uint256 oracleRate,
    method f
) filtered { f -> f.name == "getPresentValue" || f.name == "getRiskAdjustedPresentValue"} {
    require notional != 0;
    env e;
    int256 shorterPV = f(notional, maturity, e.block.timestamp, oracleRate);
    int256 longerPV = f(notional, maturity + maturityDelta, e.block.timestamp, oracleRate);

    // PV cannot change signs as a result of this calculation
    assert notional > 0 => shorterPV > 0 && longerPV > 0 && shorterPV < longerPV;
    assert notional < 0 => shorterPV < 0 && longerPV < 0 && longerPV < shorterPV;
}

rule riskAdjustedLiquidityTokenValueMatchesClaims(
    int256 fCashNotional,
    uint256 tokens,
    uint256 totalfCash,
    uint256 totalAssetCash,
    uint256 totalLiquidity,
    uint8 tokenHaircut,
    uint256 maturity,
    uint256 oracleRate
) {
    require tokenHaircut <= 100;
    env e;

    int assetCashClaim, int pv = getLiquidityTokenValue(
        fCashNotional,
        tokens,
        totalfCash,
        totalAssetCash,
        totalLiquidity,
        tokenHaircut,
        oracleRate,
        true // risk adjusted
    );

    int netfCash = (totalfCash * tokens * tokenHaircut) / (100 * totalLiquidity) + fCashNotional;
    int assetCash = (totalAssetCash * tokens * tokenHaircut) / (100 * totalLiquidity);
    assert pv == getRiskAdjustedPresentValue(netfCash, maturity, e.block.timestamp, oracleRate);
    assert assetCashClaim == assetCash;
}

rule liquidityTokenValueMatchesClaims(
    int256 fCashNotional,
    uint256 tokens,
    uint256 totalfCash,
    uint256 totalAssetCash,
    uint256 totalLiquidity,
    uint256 maturity,
    uint256 oracleRate
) {
    env e;

    int assetCashClaim, int pv = getLiquidityTokenValue(
        fCashNotional,
        tokens,
        totalfCash,
        totalAssetCash,
        totalLiquidity,
        0, // Haircut is irrelevant
        oracleRate,
        false // non risk adjusted
    );

    int netfCash = (totalfCash * tokens) / (totalLiquidity) + fCashNotional;
    int assetCash = (totalAssetCash * tokens) / (totalLiquidity);
    assert pv == getPresentValue(netfCash, maturity, e.block.timestamp, oracleRate);
    assert assetCashClaim == assetCash;
}

// We require that the portfolio is always sorted when loaded from storage
invariant portfolioIsAlwaysSorted (address account)
    // Get portfolio from harness and test if assets are sorted, do this
    // inside a harness
    assert checkSortedPortfolio(account)

// Set up a portfolio such that every asset's value is equal to 1e8 and then assert
rule netCashGroupValueAccountsForAllAssets() {
    // These need to be assumed within the code somehow:
    // require getLiquidityTokenValue == 1
    // require calculateOracleRate == 0;
    // require getRiskAdjustedPresentValue == 1;
    // require assetRate == 0.02

    uint256 currencyId = getPortfolioCurrencyIdAtIndex(portfolioIndex);
    // Ensure that the portfolio index starts at a border between assets
    require portfolioIndex == 0 || getPortfolioCurrencyIdAtIndex(portfolioIndex - 1) != currencyId;
    
    int256 assetPV, uint256 newIndex = getNetCashGroupValue(currencyId, portfolioIndex);

    assert portfolioIndex < newIndex;
    assert getPortfolioCurrencyIdAtIndex(newIndex) != currencyId;
    // Every asset should be valued at 1 and the asset cash to pv conversion rate should be 50:1
    // so therefore the assetPV should equal the number of assets multiplied by 50
    assert assetPV == (newIndex - portfolioIndex) * 50;
}

rule ifCashNetPresentValueAccountsForAllAssets() {
    // require calculateOracleRate == 0;
    // require getRiskAdjustedPresentValue == 1;

    // If each asset is valued at 1 then the total value should be the number of assets
    int256 underlyingPV = getifCashNetPresentValue(account);
    assert underlyingPV == getNumBitmapAssets(account);
}

rule freeCollateralAccountsAccountsForAllAssets {
    // TODO: Not sure how to prove this, need to account for netting and looping mainly
}

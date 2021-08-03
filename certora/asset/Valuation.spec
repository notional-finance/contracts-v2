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
methods {
    getMaturityAtMarketIndex(uint256 marketIndex, uint256 blockTime) returns (uint256) envfree;
    calculateOracleRate(uint256 maturity, uint256 blockTime) returns (uint256) envfree;
    getMarketValues() returns (uint256, uint256, uint256, uint256) envfree;
    getLiquidityHaircut(uint256 assetType) returns (uint256) envfree;
    getPresentValue(int256 notional, uint256 maturity, uint256 blockTime, uint256 oracleRate) returns (int256) envfree;
    getRiskAdjustedPresentValue(int256 notional, uint256 maturity, uint256 blockTime, uint256 oracleRate) returns (int256) envfree;
    getLiquidityTokenValue(int256 fCashNotional, uint256 tokens, uint256 assetType, uint256 blockTime, bool riskAdjusted) returns (int256, int256) envfree;
    checkPortfolioSorted(address account) returns (bool) envfree;
    getPortfolioCurrencyIdAtIndex(address account, uint256 index) returns (uint256) envfree;
    getNetCashGroupValue(address account, uint256 portfolioIndex, uint256 blockTime) returns (int256, uint256) envfree;
    getifCashNetPresentValue(address account, uint256 blockTime, bool riskAdjusted) returns (int256) envfree;
    getNumBitmapAssets(address account) returns (int256) envfree;
}

definition isBetween(uint256 x, uint256 y, uint256 z) returns bool = (y <= x && x <= z) || (z <= x && x <= y);

// invariant convertToETHBuffersAndHaircuts {
//     // show that balances > 0 will be haircut
//     // show that balances < 0 will be buffered
// }

// rule getBitmapPortfolioValueSetsDebtFlag {
//     // if any ifCash asset is < 0 then hasDebt will be set to true
//     // else will be set to false
// }

// rule getFreeCollateralSetsCashDebt {
//     // if any cash debt is < 0 then hasCashDebt will be set to true
//     // else will be set to false
// }

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
    uint256 longMarketIndex,
    uint256 blockTime
)
    isBetween(
        maturity,
        getMaturityAtMarketIndex(shortMarketIndex, blockTime),
        getMaturityAtMarketIndex(longMarketIndex, blockTime)
    ) => 
    isBetween(
        calculateOracleRate(currencyId, maturity),
        calculateOracleRate(currencyId, getMaturityAtMarketIndex(shortMarketIndex, blockTime)),
        calculateOracleRate(currencyId, getMaturityAtMarketIndex(longMarketIndex, blockTime))
    )

// For any given asset and oracle rate, the absolute present value of a shorted dated asset will
// always be less than the absolute present value of a longer dated asset. The formula is:
// pv = notional * e ^ (-oracleRate * time)
rule presentValueDecreasesForLongerMaturities(
    int256 notional,
    uint256 maturity,
    uint256 maturityDelta,
    uint256 oracleRate
) {
    require notional != 0;
    env e;
    int256 shorterPV = getPresentValue(notional, maturity, e.block.timestamp, oracleRate);
    int256 longerPV = getPresentValue(notional, maturity + maturityDelta, e.block.timestamp, oracleRate);

    // Present value cannot change signs as a result of this calculation
    assert notional > 0 => shorterPV > 0 && longerPV > 0 && shorterPV <= longerPV;
    assert notional < 0 => shorterPV < 0 && longerPV < 0 && longerPV <= shorterPV;
}

// The same holds for risk adjusted assets.
rule riskAdjustedPresentValueDecreasesForLongerMaturities(
    int256 notional,
    uint256 maturity,
    uint256 maturityDelta,
    uint256 oracleRate
) {
    require notional != 0;
    env e;
    int256 shorterPV = getRiskAdjustedPresentValue(notional, maturity, e.block.timestamp, oracleRate);
    int256 longerPV = getRiskAdjustedPresentValue(notional, maturity + maturityDelta, e.block.timestamp, oracleRate);

    // PV cannot change signs as a result of this calculation
    assert notional > 0 => shorterPV > 0 && longerPV > 0 && shorterPV <= longerPV;
    assert notional < 0 => shorterPV < 0 && longerPV < 0 && longerPV <= shorterPV;
}

// Whenever we do a risk adjustment to the present value, it must be that the risk adjusted value is
// less than or equal to the non risk adjusted present value
rule riskAdjustedPresentValueIsLessThanPresentValue(
    int256 notional,
    uint256 maturity,
    uint256 oracleRate
) {
    require notional != 0;
    env e;
    int256 pv = getPresentValue(notional, maturity, e.block.timestamp, oracleRate);
    int256 riskAdjustedPV = getRiskAdjustedPresentValue(notional, maturity, e.block.timestamp, oracleRate);

    assert riskAdjustedPV <= pv;
}

// A liquidity token has a proportional claim on totalfCash and totalLiquidity in a particular market. When valuing the
// liquidity token, there may be a negative fCash asset in the portfolio which must be net off against the positive fCash
// claim of the liquidity token first. A percentage based risk adjustment is applied (0 <= tokenHaircut <= 100). This haircut
// will decrease the value of both cash claim and fCash claim proportionally.
rule riskAdjustedLiquidityTokenValueMatchesClaims(int256 fCashNotional, uint256 tokens, uint256 assetType) {
    env e;
    uint256 totalfCash;
    uint256 totalAssetCash;
    uint256 totalLiquidity;
    uint256 maturity;
    totalfCash, totalAssetCash, totalLiquidity, maturity = getMarketValues();
    require (totalLiquidity >= tokens);

    uint256 tokenHaircut;
    tokenHaircut = getLiquidityHaircut(assetType);
    require tokenHaircut <= 100;

    uint256 oracleRate;
    oracleRate = calculateOracleRate(maturity, e.block.timestamp);

    int assetCashClaim;
    int pv;
    assetCashClaim, pv = getLiquidityTokenValue(
        fCashNotional,
        tokens,
        assetType,
        e.block.timestamp,
        true // risk adjusted
    );

    mathint netfCash = (totalfCash * tokens * tokenHaircut) / (100 * totalLiquidity) + to_mathint(fCashNotional);
    mathint assetCash = (totalAssetCash * tokens * tokenHaircut) / (100 * totalLiquidity);
    // TODO: need to convert to int somehow
    // assert pv == getRiskAdjustedPresentValue(netfCash, maturity, e.block.timestamp, oracleRate);
    assert to_mathint(assetCashClaim) == assetCash;
}

rule liquidityTokenValueMatchesClaims(int256 fCashNotional, uint256 tokens, uint256 assetType) {
    env e;
    uint256 totalfCash;
    uint256 totalAssetCash;
    uint256 totalLiquidity;
    uint256 maturity;
    totalfCash, totalAssetCash, totalLiquidity, maturity = getMarketValues();
    require (totalLiquidity >= tokens);

    uint256 oracleRate;
    oracleRate = calculateOracleRate(maturity, e.block.timestamp);

    int assetCashClaim;
    int pv;

    assetCashClaim, pv = getLiquidityTokenValue(
        fCashNotional,
        tokens,
        assetType,
        e.block.timestamp,
        false // non risk adjusted
    );

    mathint netfCash = (totalfCash * tokens) / (totalLiquidity) + to_mathint(fCashNotional);
    mathint assetCash = (totalAssetCash * tokens) / (totalLiquidity);
    // TODO: need to convert to int somehow
    // assert pv == getPresentValue(netfCash, maturity, e.block.timestamp, oracleRate);
    assert to_mathint(assetCashClaim) == assetCash;
}

// We require that the portfolio is always sorted when loaded from storage
invariant portfolioIsAlwaysSorted (address account)
    // Get portfolio from harness and test if assets are sorted, do this
    // inside a harness
    checkPortfolioSorted(account)

// TODO: below here I'm not sure how we actually do this
// Set up a portfolio such that every asset's value is equal to 1e8 and then assert
rule netCashGroupValueAccountsForAllAssets(
    address account,
    uint256 portfolioIndex
) {
    env e;
    // TODO: need to make these asumptions in the code
    // require getLiquidityTokenValue == 1
    // require calculateOracleRate == 0;
    // require getRiskAdjustedPresentValue == 1;
    // require assetRate == 0.02

    uint256 currencyId = getPortfolioCurrencyIdAtIndex(account, portfolioIndex);
    // Ensure that the portfolio index starts at a border between assets
    require portfolioIndex == 0 || getPortfolioCurrencyIdAtIndex(account, portfolioIndex - 1) != currencyId;
    int assetPV;
    uint newIndex;
    
    assetPV, newIndex = getNetCashGroupValue(account, portfolioIndex, e.block.timestamp);

    assert portfolioIndex < newIndex;
    assert getPortfolioCurrencyIdAtIndex(account, newIndex) != currencyId;
    // Every asset should be valued at 1 and the asset cash to pv conversion rate should be 50:1
    // so therefore the assetPV should equal the number of assets multiplied by 50
    assert to_mathint(assetPV) == (newIndex - portfolioIndex) * 50;
}

rule ifCashNetPresentValueAccountsForAllAssets(address account) {
    env e;
    // TODO: need to make these asumptions in the code
    // require calculateOracleRate == 0;
    // require getRiskAdjustedPresentValue == 1;

    // If each asset is valued at 1 then the total value should be the number of assets
    int256 underlyingPV = getifCashNetPresentValue(account, e.block.timestamp, true);
    assert underlyingPV == getNumBitmapAssets(account);
}

// rule freeCollateralAccountsAccountsForAllAssets {
//     // TODO: Not sure how to prove this, need to account for netting and looping mainly
// }

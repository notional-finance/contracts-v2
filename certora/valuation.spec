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

// what are the invariants here?
// calculate portfolio (asset, nToken, bitmap) value when oracle rates are zero
// calculate the pv of a single asset
// decompose liquidity tokens into components, must be equal
// calculate fc when all exchange rates are 1
// calculate exchange rates...
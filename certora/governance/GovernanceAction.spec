/**
 * Ensures all the governance action getters and setters act approporiately.
 */
methods {
    getMaxCurrencyId() returns (uint16) envfree
    getCurrencyId(address tokenAddress) returns (uint16) envfree
    getCurrency(uint16 currencyId) returns ((address, bool, int256, uint8), (address, bool, int256, uint8)) envfree
    getRateStorage(uint16 currencyId) returns ((address, uint8, bool, uint8, uint8, uint8), (address, uint8)) envfree
    getInitializationParameters(uint16 currencyId) returns (int256[], int256[]) envfree
    getDepositParameters(uint16 currencyId) returns (int256[], int256[]) envfree
    nTokenAddress(uint16 currencyId) returns (address) envfree
    getMaxMarketIndex(uint16 currencyId) returns (uint256) envfree
    getNTokenAccount(address tokenAddress) returns (bytes6, uint256) envfree
    getOwner() returns (address) envfree
}

definition MAX_MARKET_INDEX() returns uint256 = 7;

rule updateDepositParametersSetsProperly(
    uint16 currencyId,
    uint32[] _depositShares,
    uint32[] _leverageThresholds
) {
    env e;
    require getMaxMarketIndex() <= MAX_MARKET_INDEX();
    require _depositShares.length == getMaxMarketIndex();
    require _depositShares.length == _leverageThresholds.length;
    updateDepositParameters(currencyId, _depositShares, _leverageThresholds);
    // TODO: move the checking into solidity and return a bool on success.
    int256[] depositShares, int256[] leverageThresholds = getDepositParameters(currencyId)
}
// Basically the same as above
// rule updateInitializationParametersSetsProperly;

rule updateIncentiveEmissionRateSetsProperly(
    uint16 currencyId,
    uint32 newEmissionRate,
    address nTokenAddress
) {
    env e;
    require nTokenAddress(currencyId) == nTokenAddress;
    updateIncentiveEmissionRate(currencyId, newEmissionRate);
    _, uint256 incentiveEmissionRate = getNTokenAccount(nTokenAddress);
    assert incentiveEmissionRate == newEmissionRate;
}
// Basically the same as above
// rule updateCollateralParametersSetsProperly;

// rule cannotListDuplicateCurrencies;
// rule cannotOverrideListedCurrency;
// rule listingCurrenciesSetsTokenProperly;
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
    getOwner() returns (address) envfree
}

definition MAX_MARKET_INDEX() returns uint256 = 7;

rule updateDepositParametersSetsProperly(
    uint16 currencyId,
    uint32[] depositShares,
    uint32[] leverageThresholds
) {
    env e;
    require depositShares.length <= MAX_MARKET_INDEX();
    require depositShares.length == leverageThresholds.length;

}
// rule updateInitializationParametersSetsProperly;
// rule updateIncentiveEmissionRateSetsProperly;
// rule updateCollateralParametersSetsProperly;

// rule cannotListDuplicateCurrencies;
// rule cannotOverrideListedCurrency;
// rule listingCurrenciesSetsTokenProperly;
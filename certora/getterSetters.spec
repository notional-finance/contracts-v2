methods {
    getNextSettleTime(address account) returns (uint40) envfree
    getHasDebt(address account) returns (uint8) envfree
    getAssetArrayLength(address account) returns (uint8) envfree
    getBitmapCurrency(address account) returns (uint16) envfree
    getActiveCurrencies(address account) returns (uint144) envfree
}

rule getAndSetAccountContext(
    address account,
    uint40 nextSettleTime,
    uint8 hasDebt,
    uint8 assetArrayLength,
    uint16 bitmapCurrencyId,
    uint144 activeCurrencies
) {
    env e;
    setAccountContext(e, account, nextSettleTime, hasDebt, assetArrayLength, bitmapCurrencyId, activeCurrencies);
    assert getNextSettleTime(account) == nextSettleTime;
    assert getHasDebt(account) == hasDebt;
    assert getAssetArrayLength(account) == assetArrayLength;
    assert getBitmapCurrency(account) == bitmapCurrencyId;
    assert getActiveCurrencies(account) == activeCurrencies;
}


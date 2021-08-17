methods {
    getAssetsBitmap(address account, uint256 currencyId) returns (bytes32) envfree;
    getifCashNotional(address account, uint256 currencyId, uint256 maturity) returns (int256) envfree;
}

// PASSES
rule accountContextSetsProperly() {
    env e;
    calldataarg arg;
    assert verifySetAccountContext(e, arg);
}

// PASSES
rule setsAssetBitmapProperly(
    address account,
    uint256 currencyId,
    bytes32 bitmap
) {
    env e;
    setAssetsBitmap(e, account, currencyId, bitmap);
    assert getAssetsBitmap(account, currencyId) == bitmap;
}

// TODO: not working
rule setsBitmapfCashProperly(
    address account,
    uint256 currencyId,
    uint256 maturity,
    uint256 nextSettleTime,
    int256 notional
) {
    env e;
    int256 setNotional;
    setNotional = setifCashAsset(e, account, currencyId, maturity, nextSettleTime, notional);

    assert setNotional == getifCashNotional(account, currencyId, maturity);
}

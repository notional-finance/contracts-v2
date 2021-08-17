methods {
    getAssetsBitmap(address account, uint256 currencyId) returns (bytes32) envfree;
    verifyfCashNotional(address account, uint256 currencyId, uint256 maturity, int256 notional) returns (bool) envfree;
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
    require maturity > nextSettleTime;

    int256 setNotional;
    setNotional = setifCashAsset(e, account, currencyId, maturity, nextSettleTime, notional);

    assert verifyfCashNotional(account, currencyId, maturity, setNotional);
}

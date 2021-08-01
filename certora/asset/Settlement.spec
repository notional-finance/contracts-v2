methods {
    getBitmapCurrencyId(address account) returns (uint256) envfree;
    getSettlementRate(uint256 currencyId, uint256 maturity) returns (int256) envfree;
    getCashBalance(address account, uint256 currencyId) returns (int256) envfree;
    getNumSettleableAssets(address account, uint256 blockTime) returns (uint256) envfree;
    getAmountToSettle(uint256 currencyId, address account, uint256 blockTime) returns (int256) envfree;
    getNumAssets(address account) returns (uint256) envfree;
}

rule settleAssetsDeletesSettleableAssets(address account) {
    env e;
    settleAccount(e, account);
    assert getNumSettleableAssets(account, e.block.timestamp) == 0;
}

rule settlementRatesAreNeverReset(address account, uint256 currencyId, uint256 maturity) {
    env e;
    // TODO: how do you loop over maturities here?
    int256 settlementRateBefore = getSettlementRate(currencyId, maturity);
    settleAccount(e, account);
    int256 settlementRateAfter = getSettlementRate(currencyId, maturity);

    // Settlement rates must always be set after settling accounts
    assert settlementRateAfter > 0;
    // If settlement rates were set before, then they must not change after
    assert settlementRateBefore == 0 => settlementRateBefore == settlementRateAfter;
}

rule assetsConvertToCashAtSettlementRate(address account, uint256 currencyId) {
    env e;
    int256 cashBefore = getCashBalance(currencyId, account);
    // This should get the amount of cash back, would we really be proving anything
    // with this approach? It's quite circular if we need to write another harness...
    int256 amountToSettle = getAmountToSettle(currencyId, account, e.block.timestamp);
    settleAccount(e, account);
    int256 cashAfter = getCashBalance(currencyId, account);

    assert cashAfter - cashBefore == amountToSettle;
}

rule settlingBitmapAssetsDoesNotLoseTrack(address account) {
    env e;
    // This is only true for bitmap currencies, it's mostly true for array portfolios but there
    // is an edge case where liquidity tokens net off against fCash exactly.
    require getBitmapCurrencyId(account) != 0;
    uint256 numAssets;
    uint256 numSettleAssets;
    numAssets = getNumAssets(account);
    numSettleAssets = getNumSettleableAssets(account, e.block.timestamp);

    settleAccount(e, account);
    assert getNumAssets(account) == numAssets - numSettleAssets;
    assert getNumSettleableAssets(account, e.block.timestamp) == 0;
}
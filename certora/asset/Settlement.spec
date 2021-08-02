methods {
    getBitmapCurrencyId(address account) returns (uint256) envfree;
    getSettlementRate(uint256 currencyId, uint256 maturity) returns (int256) envfree;
    getCashBalance(address account, uint256 currencyId) returns (int256) envfree;
    getNumSettleableAssets(address account, uint256 blockTime) returns (uint256) envfree;
    getAmountToSettle(uint256 currencyId, address account, uint256 blockTime) returns (int256) envfree;
    getNumAssets(address account) returns (uint256) envfree;
}

// `getNumSettleableAssets` will return the number of assets that are eligible for settlement on an account.
// This will be the number of assets with settlement dates less than the block time. After settlement we want
// to ensure that none of the assets remain in the account (they must be deleted and converted into a cash amount)
rule settleAssetsDeletesSettleableAssets(address account) {
    env e;
    settleAccount(e, account);
    assert getNumSettleableAssets(account, e.block.timestamp) == 0;
}

// Settlement rates are the exchange rate between fCash and "cash balance" at maturity. Each currency id and
// maturity will have a settlement rate set for it by the first account to settle an asset at that maturity.
// Once a settlement rate is set then it can never be reset to another value. If a settlement rate is zero
// before an asset is settled then it must be some non-zero value afterwards.
rule settlementRatesAreNeverReset(address account, uint256 currencyId, uint256 maturity) {
    env e;
    require maturity < e.block.timestamp;
    // TODO: need to specify that the asset that is being settled exists at the maturity provided here.
    int256 settlementRateBefore = getSettlementRate(currencyId, maturity);
    settleAccount(e, account);
    int256 settlementRateAfter = getSettlementRate(currencyId, maturity);

    // Settlement rates must always be set after settling accounts
    assert settlementRateAfter > 0;
    // If settlement rates were set before, then they must not change after
    assert settlementRateBefore == 0 => settlementRateBefore == settlementRateAfter;
}

// The intent of a rule like this is to ensure that when we settle fCash or liquidity tokens
// we do the correct calculation to return the settlement balance. The settlement balance for fCash
// will simply be an asset cash amount based on the settlement rate. The settlement logic for liquidity
// tokens has two potential outcomes. We may want to have three separate rules for this.
// rule assetsConvertToCashAtSettlementRate(address account, uint256 currencyId) {
//     env e;
//     int256 cashBefore = getCashBalance(currencyId, account);
//     // This should get the amount of cash back, would we really be proving anything
//     // with this approach? It's quite circular if we need to write another harness...
//     int256 amountToSettle = getAmountToSettle(currencyId, account, e.block.timestamp);
//     settleAccount(e, account);
//     int256 cashAfter = getCashBalance(currencyId, account);
//     assert cashAfter - cashBefore == amountToSettle;
// }

// When we settle a bitmap type portfolio it is important that we do not lose track of any of the
// assets. A bitmap portfolio has a bitmap that tracks an index of what maturities the account holds
// fCash assets. The bitmap is structured relative to the `nextSettleTime` on an account context such that
// the first 90 bits refer to 1 day offsets, then 6 day offsets, etc. When we settle such a portfolio we
// must ensure that all the assets referred to by the bitmap continue to be tracked properly.
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
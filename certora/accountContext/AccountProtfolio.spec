methods {
  getNextSettleTime(address account) returns (uint40) envfree
  getHasDebt(address account) returns (uint8) envfree
  getAssetArrayLength(address account) returns (uint8) envfree
  getBitmapCurrency(address account) returns (uint16) envfree
  getActiveCurrencies(address account) returns (uint144) envfree
  getAssetsBitmap(address account) returns (uint256) envfree
  getSettlementDate(uint256 assetType, uint256 maturity) returns (uint256) envfree
  getMaturityAtBitNum(address account, uint256 bitNum) returns (uint256) envfree
  getifCashNotional(address account, uint256 currencyId, uint256 maturity) returns (int256) envfree
  getCashBalance(address account, uint256 currencyId) returns (int256) envfree
  getNTokenBalance(address account, uint256 currencyId) returns (int256) envfree
  getLastClaimTime(address account, uint256 currencyId) returns (uint256) envfree
  getLastClaimSupply(address account, uint256 currencyId) returns (uint256) envfree
  
  addArrayAsset(
    address account,
    uint256 currencyId,
    uint256 maturity,
    uint256 assetType,
    int256 notional
  ) envfree
  addBitmapAsset(
    address account,
    uint256 maturity,
    int256 notional
  ) envfree
  finalizeCashBalance(
    address account,
    uint256 currencyId,
    int256 netCashChange,
    int256 netAssetTransferInternalPrecision,
    bool redeemToUnderlying
  ) envfree
  setBalanceStorageForSettleCashDebt(
    address account,
    uint256 currencyId,
    int256 amountToSettleAsset
  ) envfree

}

rule sanity(method f) {
    env e;
    calldataarg args;
    f(e,args);
    assert false;
}





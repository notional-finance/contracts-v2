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
  ) 
  
  finalizeCashBalance(
    address account,
    uint256 currencyId,
    int256 netCashChange,
    int256 netAssetTransferInternalPrecision,
    bool redeemToUnderlying
  ) 
  
  setBalanceStorageForSettleCashDebt(
    address account,
    uint256 currencyId,
    int256 amountToSettleAsset
  ) envfree

}

/* Rules that verify the basic load/store assemble operations */ 


definition getActiveMasked(address account, uint144 index) returns uint144 =
    (getActiveCurrencies(account) >> (128 - index * 16)) & 0x00000000000000000000000000000000ffff;
definition getActiveUnmasked(address account, uint144 index) returns uint144 =
    (getActiveCurrencies(account) >> (128 - index * 16)) & 0x000000000000000000000000000000003fff;
definition hasCurrencyMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000004000 == 0x000000000000000000000000000000004000);
definition hasPortfolioMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000008000 == 0x000000000000000000000000000000008000);
definition hasValidMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000008000 == 0x000000000000000000000000000000008000) ||
    (getActiveMasked(account, index) & 0x000000000000000000000000000000004000 == 0x000000000000000000000000000000004000) ||
    (getActiveMasked(account, index) & 0x00000000000000000000000000000000c000 == 0x00000000000000000000000000000000c000);


rule sanity(method f) {
    env e;
    calldataarg args;
    f(e,args);
    assert false;
}



rule integrityOfAddArrayAsset()
{
  address account;
  uint256 currencyId;
  uint256 maturity;
  uint256 assetType;
  int256 notional;
  
  uint8 assetLengthBefore = getAssetArrayLength(account);
  
  addArrayAsset(account, currencyId, maturity, assetType, notional);
    
  uint8 assetLengthAfter = getAssetArrayLength(account);

  assert(assetLengthAfter == assetLengthBefore  || assetLengthAfter == assetLengthBefore + 1);
  /*assert false;*/
}





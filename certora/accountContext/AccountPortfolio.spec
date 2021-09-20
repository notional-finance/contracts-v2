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
  getStoredAsset(address account, uint256 index)  returns (uint256) envfree
  
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


/**** valid state properties ****/



/*	
	Rule: Non zero assetArrayLength  
 	Description: `bitmapCurrencyId` is set to zero when asset array is being used. 
	Formula: 
		AccountContext.assetArrayLength > 0 => AccountContext.bitmapCurrencyId=0 
  Status: 
      * verified  https://vaas-stg.certora.com/output/23658/6df073943b3a499a2813?anonymousKey=dac1710ba6df5086ff8ce2090ff796a7bf8eca1f
      * tested with a bug in enableBitmapForAccount, removed require accountContext.assetArrayLength == 0
      https://vaas-stg.certora.com/output/23658/64c67519c9b507b64fb4/?anonymousKey=089b56af0d756368edf406a140357ebc9b258be2

*/


invariant nonZeroAssetArrayLength(address account) 
      getAssetArrayLength(account) > 0 => getBitmapCurrency(account) == 0



/*	
	Rule: integrity of assetArrayLength  
 	Description: `bitmapCurrencyId` is set to zero when asset array is being used. 
	Formula: 
		i < AccountContext.assetArrayLength <=>  PortfolioState.storedAssets[i] != 0
  Status: 
  status:  https://vaas-stg.certora.com/output/23658/e20bb0ee33abd383f0d3?anonymousKey=107fbde9c6c588e1d76c9665cd5f71710e144f3c
    timeout on finalizeCashBalance(address,uint256,int256,int256,bool)

*/

invariant integrityAssetArrayLength(address account, uint256 i) 
      getAssetArrayLength(account) > i <=> getStoredAsset(account,i) == 0






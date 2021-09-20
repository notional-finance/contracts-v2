methods {
  getAssetArrayLength(address account) returns (uint8) envfree
  getBitmapCurrency(address account) returns (uint16) envfree
  getStoredAsset(address account, uint256 index)  returns (uint256) envfree
}

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






using DummyERC20ImplCToken as tokenB
using DummyERC20Impl as tokenA
using AccountAction as accountAction
// todo: use SymbolicCERC20 

methods {
    // harnessed
    depositAssetToken(address account, int256 assetAmountExternal, bool forceTransfer) returns (int256, int256)
    depositUnderlyingToken(address account, int256 underlyingAmountExternal) returns (int256) 

    // getters
    tokenA.balanceOf(address) returns (uint) envfree
    tokenB.balanceOf(address) returns (uint) envfree

    getCurrencyId() returns (uint256) envfree
    getStoredCashBalance() returns (int256) envfree
    getStoredNTokenBalance() returns (int256) envfree
    getNetCashChange() returns (int256) envfree
    getNetAssetTransferInternalPrecision() returns (int256) envfree
    getNetNTokenTransfer() returns (int256) envfree
    getNetNTokenSupplyChange() returns (int256) envfree
    getLastClaimTime() returns (uint256) envfree
    getLastClaimSupply() returns (uint256) envfree

    // dispatchers
    transfer(address,uint) => DISPATCHER(true)
    balanceOf(address) => DISPATCHER(true)
    transferFrom(address,address,uint) => DISPATCHER(true)
    mint(uint256) => DISPATCHER(true)
    mint() => DISPATCHER(true)
    // accountAction
    accountAction.depositAssetToken(address,uint16,uint256)

    // summaries
    getToken(uint256 x,bool b) => chosenTokenAssetOrUnderlying(b); //DISPATCHER(true)


}

ghost chosenToken() returns address;
ghost chosenTokenAssetOrUnderlying(bool) returns address {
    axiom chosenTokenAssetOrUnderlying(true) != chosenTokenAssetOrUnderlying(false);
}


rule integrity_depositAssetToken_old(address account, int256 assetAmountExternal, bool forceTransfer) {
    require account != currentContract;
    require account != tokenB;
    require chosenToken() == tokenB;
    require tokenA != tokenB;
 
 env e;
    require e.msg.sender == account;
    // require tokenB.erc20A(e) == tokenA; // The underlying token of B is A

    require forceTransfer; // otherwise no transfer will occur and will await finalize
    
    uint _balanceA = tokenA.balanceOf(account);
    uint _balanceB = tokenB.balanceOf(account);
    depositAssetToken(e,account, assetAmountExternal, forceTransfer);
    uint balanceA_ = tokenA.balanceOf(account);
    uint balanceB_ = tokenB.balanceOf(account);

    assert balanceA_ == _balanceA - to_mathint(assetAmountExternal) ||
           balanceB_ == _balanceB - to_mathint(assetAmountExternal);
    // if !forceTransfer, check netAssetTransferInternalPrecision
}

rule integrity_depositAssetToken(address account, uint256 assetAmountExternal, uint16 currencyId) {
    require account != currentContract;
    require account != accountAction;
    require account != tokenB;
    require chosenToken() == tokenB;
    require tokenA != tokenB;
    
    env e;
    require e.msg.sender == account;
    require tokenB.erc20A(e) == tokenA; // The underlying token of B is A

    uint _balanceA = tokenA.balanceOf(account);
    uint _balanceB = tokenB.balanceOf(account);
    accountAction.depositAssetToken(e, account, currencyId, assetAmountExternal);
    uint balanceA_ = tokenA.balanceOf(account);
    uint balanceB_ = tokenB.balanceOf(account);

    assert _balanceA == balanceA_ + to_mathint(assetAmountExternal) ||
           _balanceB == balanceB_ + to_mathint(assetAmountExternal);
}
rule deposit_underlyingToken(address account, int256 underlyingAmountExternal){
    require account != currentContract;
    require account != tokenA;
    require chosenToken() == tokenA || chosenToken() == tokenB;
    require tokenA != tokenB;

    env e;
    require e.msg.sender == account;
    require tokenB.erc20A(e) == tokenA; // The underlying token of B is A
 
    int _netCachChange = getNetCashChange();    
    int256 assetTokensReceivedInternal = depositUnderlyingToken(e,account,underlyingAmountExternal);
    int netCachChange_ = getNetCashChange();

    assert to_mathint(netCachChange_) == to_mathint(_netCachChange) + to_mathint(assetTokensReceivedInternal);
    // assert false;
}

rule underlying_doesnot_change(address account, int256 underlyingAmountExternal)
{
    require account != currentContract;
    require chosenToken() == tokenA;
    require tokenA != tokenB;
    
    // tokenA is underlying
    // tokenB is cToken
    env e;
    require tokenB.erc20A(e) == tokenA; // The underlying token of B is A
    require e.msg.sender == account;

    // uint256 startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));
    uint256 startingBalance = tokenA.balanceOf(currentContract);
    int256 assetTokensReceivedInternal = depositUnderlyingToken(e,account,underlyingAmountExternal);
    uint256 endBalance = tokenA.balanceOf(currentContract);
    
    assert startingBalance == endBalance;
}
   
// exploratory
function invokeArbitrary(method f) {
    env e;
    calldataarg arg;
    f(e, arg);
}

rule checkCurrencyIdChange(method f) {
    uint pre = getCurrencyId();
    invokeArbitrary(f);
    uint post = getCurrencyId();
    assert pre == post;
}

rule checkStoredCashBalance(method f) {
    int pre = getStoredCashBalance();
    invokeArbitrary(f);
    int post = getStoredCashBalance();
    assert pre == post;
}

rule checkStoredNTokenBalance(method f) {
    int pre = getStoredNTokenBalance();
    invokeArbitrary(f);
    int post = getStoredNTokenBalance();
    assert pre == post;
}

rule checkNetCashChange(method f) {
    int pre = getNetCashChange();
    invokeArbitrary(f);
    int post = getNetCashChange();
    assert pre == post;
}

rule checkNetAssetTransferInternalPrecision(method f) {
    int pre = getNetAssetTransferInternalPrecision();
    invokeArbitrary(f);
    int post = getNetAssetTransferInternalPrecision();
    assert pre == post;
}

rule checkNetNTokenTransfer(method f) {
    int pre = getNetNTokenTransfer();
    invokeArbitrary(f);
    int post = getNetNTokenTransfer();
    assert pre == post;
}

rule checkNetNTokenSupplyChange(method f) {
    int pre = getNetNTokenSupplyChange();
    invokeArbitrary(f);
    int post = getNetNTokenSupplyChange();
    assert pre == post;
}

rule checkLastClaimTime(method f) {
    uint pre = getLastClaimTime();
    invokeArbitrary(f);
    uint post = getLastClaimTime();
    assert pre == post;
}

rule checkLastClaimSupply(method f) {
    uint pre = getLastClaimSupply();
    invokeArbitrary(f);
    uint post = getLastClaimSupply();
    assert pre == post;
}

// sanity
rule sanity(method f) {
    invokeArbitrary(f);
    assert false;
}
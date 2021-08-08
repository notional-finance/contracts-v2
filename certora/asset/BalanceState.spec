using DummyERC20A as token

methods {
    // harnessed
    depositAssetToken(address account, int256 assetAmountExternal, bool forceTransfer) returns (int256, int256) envfree
    depositUnderlyingToken(
        address account,
        int256 underlyingAmountExternal
    ) returns (int256) envfree

    // getters
    token.balanceOf(address) returns (uint) envfree

    // dispatchers
    transfer(address,uint) => DISPATCHER(true)
    balanceOf(address) => DISPATCHER(true)
    transferFrom(address,address,uint) => DISPATCHER(true)
}

rule integrity_depositAssetToken(address account, int256 assetAmountExternal, bool forceTransfer) {
    uint _balance = token.balanceOf(account);

    depositAssetToken(account, assetAmountExternal, forceTransfer);

    uint balance_ = token.balanceOf(account);

    assert balance_ == _balance + to_mathint(assetAmountExternal);
}
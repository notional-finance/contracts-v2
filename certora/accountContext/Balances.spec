// definition SIGNED_INT_TO_MATHINT(uint256 x) returns mathint = x >= 2^255 ? x - 2^256 : x;

rule depositsMustIncreaseCashBalance(address account, uint256 depositAmount) {
    env e;
    int256 cashBalance = getCashBalance(account);
    deposit(e, account, depositAmount);
    // check balanceOf ERC20 on account and contract

    assert cashBalance + depositAmount == getCashBalance(account);
}

rule withdrawsMustDecreaseCashBalance {
    env e;
    int256 cashBalance = getCashBalance(account);

}

rule cannotWithdrawToNegativeCashBalance {

}

rule cannotWithdrawToNegativeFreeCollateral {

}

rule contractCannotHoldUnderlyingAssets {

}

rule mintingNTokensMustIncreaseBalanceAndSupply {

}

rule redeemNTokensMustDecreaseBalanceAndSupply {

}

rule transferNTokensMustNotChangeTotalSupply {

}

rule cannotHaveNegativeNTokenBalance {

}

rule nTokenBalanceChangeMustMintIncentives {

}
/**
 * All end user actions are exposed via the following external methods:
 *  - AccountAction.enableBitmapCurrency
 *  - AccountAction.settleAccount
 *  - AccountAction.depositUnderlyingToken
 *  - AccountAction.depositAssetToken
 *  - AccountAction.withdraw
 *  - BatchAction.batchBalanceAction
 *      - DepositAsset
 *      - DepositUnderlying
 *      - DepositAssetAndMintNToken
 *      - DepositUnderlyingAndMintNToken
 *      - RedeemNToken
 *      - ConvertCashToNToken
 *  - BatchAction.batchBalanceAndTradeAction
 *      - All balance actions above and also includes trades:
 *          - Lend
 *          - Borrow
 *          - AddLiquidity
 *          - RemoveLiquidity
 *          - PurchaseNTokenResidual
 *          - SettleCashDebt
 *  - nTokenRedeemAction.nTokenRedeem
 *
 * This excludes liquidation actions. For each action we must ensure that the following
 * will hold:
 *   - Net system wide fCash remains at zero. fCash balances can change during all
 *     the trading actions and all the nToken actions.
 *   - All system cash balances net off to the underlying. This should be proven inside Balance.spec
 *   - AccountContext is stored properly during updates.
 *   - Accounts requiring settlement will be settled during any action (except deposit actions)
 */

/** IMPORTANT: Account context invariants (see Portfolio.spec) must hold for all these actions */

// If an account has assets that must be settled, they must be settled for all methods except those
// that are filtered below. We can provide a method that tells us if the account should be settled.
rule accountsRequiringSettlementAreSettled(address account, method f)
    filtered (f -> f.name != "depositUnderlyingToken" && f.name != "depositAssetToken" && f.name != "enableBitmapCurrency") {
    require shouldAccountBeSettled(account) == true;
    env e;
    /// FIXME: can we even parse out account from calldata args?
    calldataarg args;
    f(e, args);
    assert shouldAccountBeSettled(account)) == false;
}

/**
 * Trading Action Harness for testing net fCash is zero and net cash is zero
 */
rule assetsFromTradingNetsOff(address account, uint256 currencyId) {
    int256 reserveBalanceBefore = getReserveBalance(currencyId);
    // FIXME: how to define portfolio state and trades?
    int256 netCash;
    _, netCash = executeTradesArrayBatch(account, currencyId, portfolioState, trades);

    int256 reserveBalanceAfter = getReserveBalance(currencyId);
    int256 reserveBalanceIncrease = reserveBalanceAfter - reserveBalanceBefore;
    assert reserveBalanceIncrease >= 0;

    // For lend, borrow, addLiquidity, removeLiquidity
    assert netCash = netCashToMarket - reserveBalanceIncrease;
}

rule assetsFromSettleCashDebt(address account, uint256 currencyId) {

}

rule assetsFromPurchaseResidual(address account, uint256 currencyId) {

}

/** Mint nToken and Redeem nToken */

// Minting nTokens should always increase the present value of that particular nToken, the user
// is adding additional cash into the nToken portfolio
rule nTokenMintIncreasesPresentValue(uint256 currencyId, uint256 amountToDeposit) {
    env e;
    require amountToDeposit > 0;

    int256 nTokenPVBefore = getNTokenPV(currencyId);
    nTokenMint(e, currencyId, amountToDeposit);
    int256 nTokenPVAfter = getNTokenPV(currencyId);

    assert nTokenPVAfter > nTokenPVBefore;
}

 
// Redeeming nTokens should always decrease the present value of that particular nToken, the user
// is removing cash from the nToken portfolio
rule nTokenRedeemDecreasesPresentValue(uint256 currencyId, uint96 tokensToRedeem, bool sellTokenAssets) {
    env e;
    require tokensToRedeem > 0;

    int256 nTokenPVBefore = getNTokenPV(currencyId);
    nTokenRedeem(e, currencyId, tokensToRedeem, sellTokenAssets);
    int256 nTokenPVAfter = getNTokenPV(currencyId);

    assert nTokenPVAfter < nTokenPVBefore;
}

// Ensure that nToken exactly 1 liquidity token per fCash market
invariant nTokenPortfolioStructure(uint256 currencyId)
    getNTokenPortfolioLength(currencyId) == getMaxMarkets(currencyId) && nTokenOnlyHasLiquidityTokens(currencyId)
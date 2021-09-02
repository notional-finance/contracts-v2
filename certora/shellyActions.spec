/*
 * This spec needs to be checked on external contracts that potentially invoke getAccountContext:
 * - FreeCollateralExternal
 * - Views
 * - AccountAction
 * - BatchAction
 * - ERC1155Action
 * - nTokenAction
 * - nTokenRedeemAction
 * - TradingAction
 * - LiquidateCurrencyAction
 * - LiquidatefCashAction
 *
 * Non external:
 * - LiquidationHelpers
 */

// Tracks the open reads to account context
ghost g_readsToAccountContext(address) returns uint256;
ghost g_writesToAccountContext(address) returns uint256;

// Sets a counter for every read of the account context
hook Sload  uint256 v (slot 1000001) [KEY address account] STORAGE {
    havoc g_readsToAccountContext assuming 
        g_readsToAccountContext@new(account) == g_readsToAccountContext@old(account) + 1 && (
            forall address a. (a != account) => g_readsToAccountContext@new(a) == g_readsToAccountContext@old(a)
        );
}

hook Sstore (slot 1000001) [KEY address account] uint256 v STORAGE {
    havoc g_writesToAccountContext assuming 
        g_writesToAccountContext@new(account) == g_writesToAccountContext@old(account) + 1 && (
            forall address a. (a != account) => g_writesToAccountContext@new(a) == g_writesToAccountContext@old(a)
        );
}


rule accountContextMustBeReadAndWrittenExactlyOnce(address account, method f) {
    require forall address a. g_readsToAccountContext(a) == 0;
    require forall address a. g_writesToAccountContext(a) == 0;
    env e;

    calldataarg args;
    f(e, args);

    assert forall address a. g_readsToAccountContext(a) == g_writesToAccountContext(a) && g_readsToAccountContext(a) <= 1;
}
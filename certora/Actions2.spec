// Tracks the open reads to account context
ghost g_readsToAccountContext(address) returns uint256;
ghost g_writesToAccountContext(address) returns uint256;

// Sets a counter for every read of the account context
hook Sload (slot 1000001) [KEY address account] uint256 v STORAGE {
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

rule accountsCannotEndWithNegativeFreeCollateral(address account, method f)
    filtered (f -> f.name != "depositUnderlyingToken" && f.name != "depositAssetToken" && f.name != "enableBitmapCurrency") {
    env e;

    // FIXME: maybe create a function summary that fc is negative
    calldataarg args;
    f(e, args);

    require f.reverted;
}

rule accountContextMustBeReadAndWrittenExactlyOnce(address account, method f) {
    env e;

    calldataarg args;
    f(e, args);

    assert forall address a => g_readsToAccountContext(a) == g_writesToAccountContext(a) && g_readsToAccountContext(a) <= 1;
}
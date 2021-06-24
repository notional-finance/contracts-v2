methods {
    getNextSettleTime(address account) returns (uint40) envfree
    getHasDebt(address account) returns (uint8) envfree
    getAssetArrayLength(address account) returns (uint8) envfree
    getBitmapCurrency(address account) returns (uint16) envfree
    getActiveCurrencies(address account) returns (uint144) envfree
    getAssetsBitmap(address account) returns (uint256) envfree
}

/* Helper methods for active currencies */
definition getActiveMasked(address account, uint144 index) returns uint144 =
    (getActiveCurrencies(account) >> (128 - index * 16)) & 0x00000000000000000000000000000000ffff;
definition getActiveUnmasked(address account, uint144 index) returns uint144 =
    (getActiveCurrencies(account) >> (128 - index * 16)) & 0x000000000000000000000000000000003fff;
definition hasCurrencyMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000004000 == 0x000000000000000000000000000000004000);
definition hasValidMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000008000 == 0x000000000000000000000000000000008000) ||
    (getActiveMasked(account, index) & 0x000000000000000000000000000000004000 == 0x000000000000000000000000000000004000) ||
    (getActiveMasked(account, index) & 0x00000000000000000000000000000000c000 == 0x00000000000000000000000000000000c000);

definition MAX_CURRENCIES() returns uint256 = 0x3fff;
definition MAX_TIMESTAMP() returns uint256 = 2^32 - 1;
// Cannot have timestamps less than 90 days
definition MIN_TIMESTAMP() returns uint256 = 7776000;

/**
 * If an account enables a bitmap portfolio it cannot strand assets behind such that the system
 * becomes blind to them.
 */
rule enablingBitmapCannotLeaveBehindAssets(address account, uint256 currencyId) {
    env e;
    require currencyId <= MAX_CURRENCIES();
    require e.block.timestamp >= MIN_TIMESTAMP();
    require e.block.timestamp <= MAX_TIMESTAMP();
    uint16 bitmapCurrencyId = getBitmapCurrency(account);
    uint8 assetArrayLength = getAssetArrayLength(account);
    uint256 assetsBitmap = getAssetsBitmap(account);
    require bitmapCurrencyId != 0 => assetArrayLength == 0;
    // Cannot set bitmap currency to 0 if it is already 0, will revert
    require bitmapCurrencyId == 0 => currencyId > 0;
    // Prevents invalid starting state
    require bitmapCurrencyId == 0 => assetsBitmap == 0x0000000000000000000000000000000000000000000000000000000000000000;

    enableBitmapForAccount@withrevert(e, account, currencyId, e.block.timestamp);
    // In these cases the account has active assets or cash debts
    assert (
        assetArrayLength != 0 ||
        assetsBitmap != 0x0000000000000000000000000000000000000000000000000000000000000000
    ) => lastReverted;
}

/**
 * When a bitmap portfolio is active, it cannot ever have any assets in its array. If this occurs then
 * there will be assets that are not accounted for during the free collateral check.
 */
invariant bitmapPortfoliosCannotHaveAssetArray(address account)
    getBitmapCurrency(account) != 0 => getAssetArrayLength(account) == 0

/**
 * Active currency flags are always sorted and cannot be double counted, if this occurs then there
 * will be currencies that are double counted during the free collateral check.
 *
 * This check ensures that any two indexes of the active currencies byte vector are not duplicated
 * and sorted properly.
 */
invariant activeCurrenciesAreNotDuplicatedAndSorted(address account, uint144 i, uint144 j)
    (0 <= i && j == i + 1 && j < 9) =>
        // If the current slot is zero then the next slot must also be zero
        (
            getActiveMasked(account, i) == 0 ? getActiveMasked(account, j) == 0 :
                hasValidMask(account, i) && (
                    // The next slot may terminate
                    getActiveMasked(account, j) == 0 ||
                    // Or it may have a value which must be greater than the current value
                    (hasValidMask(account, j) && getActiveUnmasked(account, i) < getActiveUnmasked(account, j))
                )
        )

/**
 * If a bitmap currency is set then it cannot also be in active currencies or it will be considered a duplicate
 */
invariant bitmapCurrencyIsNotDuplicatedInActiveCurrencies(address account, uint144 i)
    0 <= i && i < 9 && getBitmapCurrency(account) != 0 &&
        (
            // When a bitmap is enable it can only have currency masks in the active currencies bytes
            (hasCurrencyMask(account, i) && getActiveUnmasked(account, i) == 0) ||
                getActiveMasked(account, i) == 0
        ) => getActiveUnmasked(account, i) != getBitmapCurrency(account)

// rule activeCurrencyBalanceFlagsMatchesActual { }
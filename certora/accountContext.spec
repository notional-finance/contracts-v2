methods {
    getAccountContextSlot(address account) returns (uint256) envfree
    getNextSettleTime(address account) returns (uint40) envfree
    getHasDebt(address account) returns (uint8) envfree
    getAssetArrayLength(address account) returns (uint8) envfree
    getBitmapCurrency(address account) returns (uint16) envfree
    getActiveCurrencies(address account) returns (uint144) envfree
    getAssetsBitmap(address account) returns (bytes32) envfree
}

/* Unpack account context */
// definition unpackAccountNextSettleTime(bytes32 b) returns uint40 = 
//     b & 0x00000000000000000000000000000000000000000000ffffffffffffffffffff;
// definition unpackAccountHasDebt(bytes32 b) returns bytes1 =
//     (b & 0x000000000000000000000000000000000000000000ff00000000000000000000) << 208;
// definition unpackAccountArrayLength(bytes32 b) returns uint8 = 
//     (b & 0x0000000000000000000000000000000000000000ff0000000000000000000000) >> 48;
// definition unpackAccountBitmapId(bytes32 b) returns uint16 =
//     (b & 0x000000000000000000000000000000000000ffff000000000000000000000000) >> 56;
// definition unpackActiveCurrencies(bytes32 b) returns bytes18 = 
//     (b & 0xffffffffffffffffffffffffffffffffffff0000000000000000000000000000) << 40;

// /* Unpack each active currency */
// definition activeCurrency1(bytes18 c) returns uint16 =
//     (c & 0xffff00000000000000000000000000000000) >> 128;
// definition activeCurrency2(bytes18 c) returns uint16 =
//     (c & 0x0000ffff0000000000000000000000000000) >> 112;
// definition activeCurrency3(bytes18 c) returns uint16 =
//     (c & 0x00000000ffff000000000000000000000000) >> 96;
// definition activeCurrency4(bytes18 c) returns uint16 =
//     (c & 0x000000000000ffff00000000000000000000) >> 80;
// definition activeCurrency5(bytes18 c) returns uint16 =
//     (c & 0x0000000000000000ffff0000000000000000) >> 64;
// definition activeCurrency6(bytes18 c) returns uint16 =
//     (c & 0x00000000000000000000ffff000000000000) >> 48;
// definition activeCurrency7(bytes18 c) returns uint16 =
//     (c & 0x000000000000000000000000ffff00000000) >> 32;
// definition activeCurrency8(bytes18 c) returns uint16 =
//     (c & 0x0000000000000000000000000000ffff0000) >> 16;
// definition activeCurrency9(bytes18 c) returns uint16 =
//     (c & 0x00000000000000000000000000000000ffff);

// /* Helper methods for active currencies */
definition unmaskCurrency(uint16 c) returns uint16 = (c & 0x3FFF);
definition currencyActiveInPortfolio(uint16 c) returns bool = (c & 0x8000) == 0x8000;
definition currencyActiveInBalances(uint16 c) returns bool = (c & 0x4000) == 0x4000;
definition MAX_CURRENCIES() returns uint256 = 0x3fff;
definition MAX_TIMESTAMP() returns uint256 = 2^32 - 1;

// 200000000000000000000000000000000083b000000000000000000 

rule enableBitmapPortfolios(address account, uint256 currencyId) {
    env e;
    require currencyId <= MAX_CURRENCIES();
    // require e.timestamp <= MAX_TIMESTAMP();
    require getAccountContextSlot(account) == 0;
    require getNextSettleTime(account) == 0;
    require getActiveCurrencies(account) == 0x000000000000000000000000000000000000;
    require getHasDebt(account) == 0x00;
    require getAssetsBitmap(account) == 0x0000000000000000000000000000000000000000000000000000000000000000;
    require getBitmapCurrency(account) == 0;
    require getAssetArrayLength(account) == 0;
    // require getBitmapCurrency(account) != 0 => getAssetArrayLength(account) == 0;
    // requireInvariant bitmapPortfoliosCannotHaveAssetArray(account);

    enableBitmapForAccount(e, account, currencyId, 1623857408);
    assert getBitmapCurrency(account) != 0 => getAssetArrayLength(account) == 0;
}

/**
 * When a bitmap portfolio is active, it cannot ever have any assets in its array. If this occurs then
 * there will be assets that are not accounted for during the free collateral check.
invariant bitmapPortfoliosCannotHaveAssetArray(address account)
    getBitmapCurrency(account) != 0 => getAssetArrayLength(account) == 0
 */

// /**
//  * Active currency flags are always sorted and cannot be double counted, if this occurs then there
//  * will be currencies that are double counted during the free collateral check.
//  */
// invariant activeCurrenciesAreAlwaysSortedAndNeverDuplicated {
//     _, _, _, uint16 bitmapCurrencyId, bytes18 activeCurrencies = getAccountContext(account);
//     uint16 ac1 = unmaskCurrency(activeCurrency1(activeCurrencies))
//     uint16 ac2 = unmaskCurrency(activeCurrency2(activeCurrencies))
//     uint16 ac3 = unmaskCurrency(activeCurrency3(activeCurrencies))
//     uint16 ac4 = unmaskCurrency(activeCurrency4(activeCurrencies))
//     uint16 ac5 = unmaskCurrency(activeCurrency5(activeCurrencies))
//     uint16 ac6 = unmaskCurrency(activeCurrency6(activeCurrencies))
//     uint16 ac7 = unmaskCurrency(activeCurrency7(activeCurrencies))
//     uint16 ac8 = unmaskCurrency(activeCurrency8(activeCurrencies))
//     uint16 ac9 = unmaskCurrency(activeCurrency9(activeCurrencies))

//     // When a currency is marked as zero it terminates the bitmap
//     ac1 == 0 => ac2 == 0;
//     ac2 == 0 => ac3 == 0;
//     ac3 == 0 => ac4 == 0;
//     ac4 == 0 => ac5 == 0;
//     ac5 == 0 => ac6 == 0;
//     ac6 == 0 => ac7 == 0;
//     ac7 == 0 => ac8 == 0;
//     ac8 == 0 => ac9 == 0;

//     // Require that no two currencies are duplicated
//     ac1 != 0 => ac1 < ac2 || ac2 == 0;
//     ac2 != 0 => ac2 < ac3 || ac3 == 0;
//     ac3 != 0 => ac3 < ac4 || ac4 == 0;
//     ac4 != 0 => ac4 < ac5 || ac5 == 0;
//     ac5 != 0 => ac5 < ac6 || ac6 == 0;
//     ac6 != 0 => ac6 < ac7 || ac7 == 0;
//     ac7 != 0 => ac7 < ac8 || ac8 == 0;
//     ac8 != 0 => ac8 < ac9 || ac9 == 0;

//     // A bitmap currency cannot be in the active currencies list
//     bitmapCurrencyId != 0 => (
//         ac1 != bitmapCurrencyId &&
//         ac2 != bitmapCurrencyId &&
//         ac3 != bitmapCurrencyId &&
//         ac4 != bitmapCurrencyId &&
//         ac5 != bitmapCurrencyId &&
//         ac6 != bitmapCurrencyId &&
//         ac7 != bitmapCurrencyId &&
//         ac8 != bitmapCurrencyId &&
//         ac9 != bitmapCurrencyId
//     );
// }

// hook Sstore accountContext
//     [KEY address account]
//     bytes32 b (bytes32 b_old) STORAGE {

//     uint8 assetArrayLength = unpackAccountArrayLength(b)
//     uint8 assetArrayLength_old = unpackAccountArrayLength(b_old)

//     uint16 bitmapCurrencyId = unpackAccountBitmapId(b)
// }



// Requires portfolio integration....
// rule assetArrayLengthAlwaysMatchesActual { }
// rule nextSettleTimeAlwaysReferencesMinMaturity { }
// rule hasAssetDebtFlagsAreAlwaysCorrect { }
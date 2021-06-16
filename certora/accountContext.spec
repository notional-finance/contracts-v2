/* Unpack account context */
definition unpackAccountNextSettleTime(bytes32 b) returns uint40 = 
    b & 0x00000000000000000000000000000000000000000000ffffffffffffffffffff;
definition unpackAccountHasDebt(bytes32 b) returns bytes1 =
    (b & 0x000000000000000000000000000000000000000000ff00000000000000000000) << 208;
definition unpackAccountArrayLength(bytes32 b) returns uint8 = 
    (b & 0x0000000000000000000000000000000000000000ff0000000000000000000000) >> 48;
definition unpackAccountBitmapId(bytes32 b) returns uint16 =
    (b & 0x000000000000000000000000000000000000ffff000000000000000000000000) >> 56;
definition unpackActiveCurrencies(bytes32 b) returns bytes18 = 
    (b & 0xffffffffffffffffffffffffffffffffffff0000000000000000000000000000) << 40;
definition MAX_CURRENCIES() returns uint256 = 0x3fff;

methods {
    getAccountContext(address account) returns (uint40, bytes1, uint8, uint16, bytes18) envfree;
}

rule enableBitmapPortfolios(address account, uint256 currencyId, method getAccountContext) {
    (_, _, uint8 assetArrayLength, uint16 bitmapCurrencyId, _) = getAccountContext(account);
    require assetArrayLength == 0;
    require currencyId <= MAX_CURRENCIES()

    env e;
    enableBitmapForAccount(account, currencyId, e.timestamp);

    bitmapPortfoliosCannotHaveAssetArray(account);
}

/* If the bitmap currency is set then the asset array length must always be zero */
invariant bitmapPortfoliosCannotHaveAssetArray(address account) { 
    (_, _, uint8 assetArrayLength, uint16 bitmapCurrencyId, _) = getAccountContext(account);
    bitmapCurrencyId != 0 => assetArrayLength == 0;
}

// hook Sstore accountContext
//     [KEY address account]
//     bytes32 b (bytes32 b_old) STORAGE {

//     uint8 assetArrayLength = unpackAccountArrayLength(b)
//     uint8 assetArrayLength_old = unpackAccountArrayLength(b_old)

//     uint16 bitmapCurrencyId = unpackAccountBitmapId(b)
// }


/*
invariant bitmapCurrencyCannotBeSetInActiveCurrencies(address account) { 
    (_, _, uint8 assetArrayLength, uint16 bitmapCurrencyId) = getAccountContext(account)
    bitmapCurrencyId != 0 => assetArrayLength == 0
}
*/

// rule assetArrayLengthAlwaysMatchesActual { }
// rule nextSettleTimeAlwaysReferencesMinMaturity { }
// rule hasAssetDebtFlagsAreAlwaysCorrect { }
// rule activeCurrenciesAreAlwaysSorted { }
// rule activeCurrenciesCannotBeDoubleCounted { }
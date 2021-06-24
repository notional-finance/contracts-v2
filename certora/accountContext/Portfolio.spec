/**
 * Ensures that all portfolio assets in the portfolio arrays are tracked properly on the account
 * context object (including on both the bitmap and asset array portfolios)
 */
methods {
    getNextSettleTime(address account) returns (uint40) envfree
    getHasDebt(address account) returns (uint8) envfree
    getAssetArrayLength(address account) returns (uint8) envfree
    getBitmapCurrency(address account) returns (uint16) envfree
    getActiveCurrencies(address account) returns (uint144) envfree
    getAssetsBitmap(address account) returns (uint256) envfree
    getSettlementDate(uint256 assetType, uint256 maturity) returns (uint256) envfree
    getMaturityAtBitNum(address account, uint256 bitNum) returns (uint256) envfree
    getifCashNotional(address account, uint256 currencyId, uint256 maturity) returns (int256) envfree
    getCashBalance(address account, uint256 currencyId) returns (int256) envfree
    getNTokenBalance(address account, uint256 currencyId) returns (int256) envfree
    getLastClaimTime(address account, uint256 currencyId) returns (uint256) envfree
    getLastClaimSupply(address account, uint256 currencyId) returns (uint256) envfree
}

// Tracks the bytes stored at every asset array index
// (address account, uint256 index)
ghost g_assetBytesAtIndex(address, uint256) returns bytes32;
// Tracks if a currency is active in the portfolio array
// (address account, uint256 currencyId)
ghost g_isCurrencyActive(address, uint256) returns bool;
// Tracks the minimum settlement time on an account's arrays
// (address account)
ghost g_minSettlementTime(address) returns uint256;
// Tracks if an account has a negative balance on any asset
// (address account)
ghost g_hasPortfolioDebt(address) returns bool;
// Tracks all ifCash assets set on an account
// (address account, uint256 currencyId, uint256 maturity)
ghost g_ifCashAsset(address, uint256, uint256) returns int256;

// Tracks the cash balance stored
ghost g_cashBalance(address, uint256) returns int256;
// Tracks the ntoken balance stored
ghost g_nTokenBalance(address, uint256) returns int256;
// Tracks the last claim time stored
ghost g_lastClaimTime(address, uint256) returns uint256;
// Tracks the last claim supply stored
ghost g_lastClaimSupply(address, uint256) returns uint256;
// Tracks if the account has cash debt
ghost g_hasCashDebt(address) returns bool;


// Unpacking asset array storage
definition unpackAssetCurrencyId(uint256 b) returns uint256 =
    b & 0x000000000000000000000000000000000000000000000000000000000000ffff;
definition unpackAssetMaturity(uint256 b) returns uint256 =
    (b & 0x00000000000000000000000000000000000000000000000000ffffffffff0000) >> 16;
definition unpackAssetType(uint256 b) returns uint256 =
    (b & 0x000000000000000000000000000000000000000000000000ff00000000000000) >> 56;
definition unpackAssetNotional(uint256 b) returns int256 =
    // TODO: this needs to convert to two's complement...
    (b & 0x00000000000000000000000000ffffffffffffffffffffff0000000000000000) >> 64;

// Unpacking cash balance storage
definition unpackNTokenBalance(uint256 b) returns int256 =
    // TODO: needs to do two's complement
     b & 0x00000000000000000000000000000000000000000000ffffffffffffffffffff;
definition unpackLastClaimTime(uint256 b) returns uint256 =
    (b & 0x000000000000000000000000000000000000ffffffff00000000000000000000) >> 80;
definition unpackLastClaimSupply(uint256 b) returns uint256 =
    (b & 0x0000000000000000000000ffffffffffffff0000000000000000000000000000) >> 112;
definition unpackCashBalance(uint256 b) returns int256 =
    // TODO: needs to do two's complement
    (b & 0xffffffffffffffffffffff000000000000000000000000000000000000000000) >> 168;


// Helpers for portfolio hooks
definition isAssetSet(bytes32 v) returns bool =
    v != 0x0000000000000000000000000000000000000000000000000000000000000000;
definition min(uint256 a, uint256 b) returns uint256 = a < b ? a : b;
definition isAssetBitSet(address account, uint256 bitNum) returns bool =
    (getAssetsBitmap(account) << (bitNum - 1)) & 0x8000000000000000000000000000000000000000000000000000000000000000 ==
        0x8000000000000000000000000000000000000000000000000000000000000000;

/* Helper methods for active currencies */
definition getActiveMasked(address account, uint144 index) returns uint144 =
    (getActiveCurrencies(account) >> (128 - index * 16)) & 0x00000000000000000000000000000000ffff;
definition getActiveUnmasked(address account, uint144 index) returns uint144 =
    (getActiveCurrencies(account) >> (128 - index * 16)) & 0x000000000000000000000000000000003fff;
definition hasCurrencyMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000004000 == 0x000000000000000000000000000000004000);
definition hasPortfolioMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000008000 == 0x000000000000000000000000000000008000);
definition hasValidMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000008000 == 0x000000000000000000000000000000008000) ||
    (getActiveMasked(account, index) & 0x000000000000000000000000000000004000 == 0x000000000000000000000000000000004000) ||
    (getActiveMasked(account, index) & 0x00000000000000000000000000000000c000 == 0x00000000000000000000000000000000c000);

definition MAX_CURRENCIES() returns uint256 = 0x3fff;
definition MAX_TIMESTAMP() returns uint256 = 2^32 - 1;
// Cannot have timestamps less than 90 days
definition MIN_TIMESTAMP() returns uint256 = 7776000;


// Tracking storage slots for account asset arrays
hook Sstore (slot 1000013)
    [KEY address account]
    [INDEX uint256 index]
    uint256 v STORAGE {
    // Update the asset bytes at the index
    havoc g_assetBytesAtIndex assuming g_assetBytesAtIndex@new(account, index) == v && (
        forall address a.
        forall uint256 i.
        (a != account && i != index) => g_assetBytesAtIndex@new(a, i) == g_assetBytesAtIndex@old(a, i)
    );
    
    uint256 currencyId = unpackAssetCurrencyId(v);
    // Set to true if the asset is set, false otherwise
    havoc g_isCurrencyActive assuming g_isCurrencyActive@new(account, currencyId) == isAssetSet(v) && (
        forall address a.
        forall uint256 c.
        (a != account && c != currencyId) => g_isCurrencyActive@new(a, c) == g_isCurrencyActive@old(a, c)
    );

    uint256 assetType = unpackAssetType(v);
    uint256 maturity = unpackAssetMaturity(v);
    uint256 settlementTime = getSettlementDate(assetType, maturity);
    havoc g_minSettlementTime assuming g_minSettlementTime@new(account) == min(settlementTime, g_minSettlementTime@old(account)) && (
        forall address a. (a != account) => g_minSettlementTime@new(a) == g_minSettlementTime@old(a)
    );

    int256 assetNotional = unpackAssetNotional(v);
    havoc g_hasPortfolioDebt assuming g_hasPortfolioDebt@new(account) == (assetNotional < 0) && (
        forall address a. (a != account) => g_hasPortfolioDebt@new(a) == g_hasPortfolioDebt@old(a)
    );
}

// ifCash asset storage offset
hook Sstore (slot 1000012)
    [KEY address account]
    [KEY uint256 currencyId]
    [KEY uint256 maturity]
    int256 v STORAGE {

    // Set new ifcash asset ghost
    havoc g_ifCashAsset assuming g_ifCashAsset@new(account, currencyId, maturity) == (
        forall address a.
        forall uint256 c.
        forall uint256 m.
        (a != account && c != currencyId && m != maturity) => g_ifCashAsset@new(a, c, m) == g_ifCashAsset@old(a, c, m)
    );

    // Set new portfolio debt ghost
    havoc g_hasPortfolioDebt assuming g_hasPortfolioDebt@new(account) == (v < 0) && (
        forall address a. (a != account) => g_hasPortfolioDebt@new(a) == g_hasPortfolioDebt@old(a)
    );
}

// Cash balance storage
hook Sstore (slot 1000006)
    [KEY address account]
    [KEY uint256 currencyId]
    uint256 v STORAGE {
    
    int256 cashBalance = unpackCashBalance(v);
    havoc g_cashBalance assuming g_cashBalance@new(account, currencyId) == cashBalance && (
        forall address a.
        forall uint256 c.
        (a != account && c != currencyId) => g_cashBalance@new(a, c) == g_cashBalance@old(a, c)
    );

    havoc g_hasCashDebt assuming g_hasCashDebt@new(account) == (cashBalance < 0) && (
        forall address a. (a != account) => g_hasCashDebt@new(a) == g_hasCashDebt@old(a)
    );

    int256 nTokenBalance = unpackNTokenBalance(v);
    havoc g_nTokenBalance assuming g_nTokenBalance@new(account, currencyId) == nTokenBalance && (
        forall address a.
        forall uint256 c.
        (a != account && c != currencyId) => g_nTokenBalance@new(a, c) == g_nTokenBalance@old(a, c)
    );

    uint256 lastClaimTime = unpackLastClaimTime(v);
    havoc g_lastClaimTime assuming g_lastClaimTime@new(account, currencyId) == lastClaimTime && (
        forall address a.
        forall uint256 c.
        (a != account && c != currencyId) => g_lastClaimTime@new(a, c) == g_lastClaimTime@old(a, c)
    );

    uint256 lastClaimSupply = unpackLastClaimSupply(v);
    havoc g_lastClaimSupply assuming g_lastClaimSupply@new(account, currencyId) == lastClaimSupply && (
        forall address a.
        forall uint256 c.
        (a != account && c != currencyId) => g_lastClaimSupply@new(a, c) == g_lastClaimSupply@old(a, c)
    );
}


/* Asset array length in the portfolio context must always match how the storage array is set */
invariant assetArrayLengthAlwaysMatchesActual(address account, uint256 index)
    index >= getAssetArrayLength(account) ?
            // If the index is past the end of the asset array length then it must be set to zero
            g_assetBytesAtIndex(account, index) == 0x0000000000000000000000000000000000000000000000000000000000000000 :
            // Otherwise it must not be set to zero (it must have a value)
            g_assetBytesAtIndex(account, index) != 0x0000000000000000000000000000000000000000000000000000000000000000

/* Active currencies that are set to active in the portfolio must match */
invariant activeCurrencyAssetFlagsMatchActual(address account, uint256 i)
    (0 <= i && i < 9) => (
        hasPortfolioMask(account, i) ?
            g_isCurrencyActive(account, getActiveUnmasked(account, i)) == true :
            g_isCurrencyActive(account, getActiveUnmasked(account, i)) == false
    )

/* Minimum settlement time on the account context must match what is stored on the asset array */
invariant minSettlementTimeMatchesActualForAssetArray(address account)
    getBitmapCurrency(account) == 0 => getNextSettleTime(account) == g_minSettlementTime(account)

/* Portfolio debt set on the account context must be set to true */
invariant hasPortfolioDebtMatchesActual(address account)
    (getHasDebt(account) & 0x01 == 0x01) == g_hasPortfolioDebt(account)

/* Checks if a bit is set in the bitmap then the fcash asset must match */
invariant allBitmapBitsAreValid(address account, uint256 currencyId, uint256 bitNum)
    (1 <= bitNum && bitNum <= 256) => (
        isAssetBitSet(account, bitNum) ?
            getifCashNotional(account, currencyId, getMaturityAtBitNum(account, bitNum)) ==
                g_ifCashAsset(account, currencyId, getMaturityAtBitNum(account, bitNum)) :
            getifCashNotional(account, currencyId, getMaturityAtBitNum(account, bitNum)) == 0
    )

invariant activeCurrencyBalanceFlagsMatchActual(address account, uint256 i)
    (0 <= i && i < 9) => (
        hasCurrencyMask(account, i) ?
            g_isCurrencyActive(account, getActiveUnmasked(account, i)) == true :
            g_isCurrencyActive(account, getActiveUnmasked(account, i)) == false
    )

invariant hasCashDebtMatchesActual(address account)
    (getHasDebt(account) & 0x02 == 0x02) == g_hasCashDebt(account)

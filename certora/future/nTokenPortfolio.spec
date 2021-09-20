/**
 * These invariants should hold before and after any changes to an nToken portfolio, namely on
 * Minting nTokens, Redeeming nTokens, Initializing Markets, and Sweep Cash Into Markets
 */
methods {
    getMaturityAtMarketIndex(uint256 marketIndex) returns (uint256) envfree
    getNTokenCurrency(address account) returns (uint256) envfree
}

ghost g_isCurrencyActive(address, uint256) returns bool;
ghost g_hasAssetType(address, uint256) returns bool;
ghost g_ifCashAsset(address, uint256, uint256) returns int256;
ghost g_totalNegativefCash(address) returns int256;
ghost g_cashBalance(address, uint256) returns int256;
ghost g_nTokenBalance(address, uint256) returns int256;

definition unpackAssetCurrencyId(uint256 b) returns uint256 =
    b & 0x000000000000000000000000000000000000000000000000000000000000ffff;
definition unpackAssetType(uint256 b) returns uint256 =
    (b & 0x000000000000000000000000000000000000000000000000ff00000000000000) >> 56;
definition unpackNTokenBalance(uint256 b) returns int256 =
    // TODO: needs to do two's complement
     b & 0x00000000000000000000000000000000000000000000ffffffffffffffffffff;
definition unpackCashBalance(uint256 b) returns int256 =
    // TODO: needs to do two's complement
    (b & 0xffffffffffffffffffffff000000000000000000000000000000000000000000) >> 168;

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
    havoc g_hasAssetType assuming g_hasAssetType@new(account, assetType) == g_hasAssetType@new(account, assetType) == true && (
        forall address a.
        forall uint256 t.
        (a != account && t != assetType) => g_assetTypes@new(a, t) == g_assetTypes@old(a, t)
    );
}

// ifCash asset storage offset
hook Sstore (slot 1000012)
    [KEY address account]
    [KEY uint256 currencyId]
    [KEY uint256 maturity]
    int256 v STORAGE {

    // Set new ifcash asset ghost
    havoc g_ifCashAsset assuming g_ifCashAsset@new(account, currencyId, maturity) == v && (
        forall address a.
        forall uint256 c.
        forall uint256 m.
        (a != account && c != currencyId && m != maturity) => g_ifCashAsset@new(a, c, m) == g_ifCashAsset@old(a, c, m)
    );

    // Sum the total negative fCash set on the nToken for cash withholding invariant
    // Will assume that oracle rates are equal to zero for ease of calculations
    havoc g_totalNegativefCash assuming g_totalNegativefCash@new(account) == (g_totalNegativefCash@old(account) + v) && (
        forall address a.
        (a != account) => g_totalNegativefCash@new(a) == g_totalNegativefCash@old(a)
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

    int256 nTokenBalance = unpackNTokenBalance(v);
    havoc g_nTokenBalance assuming g_nTokenBalance@new(account, currencyId) == nTokenBalance && (
        forall address a.
        forall uint256 c.
        (a != account && c != currencyId) => g_nTokenBalance@new(a, c) == g_nTokenBalance@old(a, c)
    );
}

invariant nTokenOnlyHasDesignedCurrencyAssets(address nToken, uint256 currencyId)
    (currencyId == getNTokenCurrency(nToken)) == g_isCurrencyActive(nToken, currencyId)

// nToken portfolio only has liquidity token asset types up until the max market index
invariant nTokenArrayIsSortedLiquidityTokens(address nToken, uint256 assetType)
    g_hasAssetType(nToken, assetType) <=> (1 < assetType && assetType <= getMaxMarketIndex() + 1)

// nToken portfolio has matching market fCash assets
invariant nTokenPortfolioHasMarketfCash(address nToken, uint256 marketIndex)
    1 <= marketIndex && marketIndex <= getMaxMarketIndex() =>
        g_ifCashAsset(nToken, getMaturityAtMarketIndex(marketIndex)) != 0

// nToken portfolio can have residual fCash from the previous quarter if the 1+ year markets
// are enabled
invariant nTokenPortfolioHasResidualfCash(address nToken, uint256 assetType)
    getMaxMarketIndex() >= 3 => 
        (3 <= marketIndex && marketIndex <= getMaxMarketIndex()) =>
            g_ifCashAsset(nToken, getMaturityAtMarketIndex(marketIndex) - QUARTER()) != 0

// This is only true when market rates are zero, otherwise the calculation is
// more complex because it requires discounting
invariant nTokenPortfolioHasSufficientCashWithholding(address nToken)
    g_cashBalance(nToken, getNTokenCurrency(nToken)) >= g_totalNegativefCash(nToken, getNTokenCurrency(nToken))

invariant nTokenPortfolioDoesNotHaveOtherCashBalances(address nToken, uint256 currencyId)
    (currencyId != getNTokenCurrency(nToken)) => g_cashBalance(nToken, currencyId) == 0

invariant nTokenPortfolioDoesNotHaveNTokenBalances(address nToken, uint256 currencyId)
    g_nTokenBalance(nToken, currencyId) == 0
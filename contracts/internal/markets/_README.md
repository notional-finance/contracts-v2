# Markets

Notional enables fixed rate lending and borrowing via on chain liquidity pools we call **markets**. Each currency may have a **Cash Group** which holds all the configuration related to the set of markets that
host lending and borrowing for that currency. In order to enable high capital efficiency for liquidity providers, liquidity is denominated in money market tokens (i.e. cTokens) that bear some underlying variable rate of interest. This is referred to as **asset cash** in the codebase and it has an exchange rate back to the underlying asset we call the **asset rate**

## Asset Rate

Liquidity in markets is provided (wherever possible) in asset cash, which means that it is a token that bears some amount of money market interest. fCash, however, is denominated in underlying terms such that it is a fixed amount of tokens redeemable at a fixed term. Asset rates enable the conversion of asset cash to underlying denomination for the purposes of settlement and trading.

Asset rates will change every block, therefore there are nearly identical view and stateful methods for getting asset rates (`buildAssetRateView` and `buildAssetRateStateful`). The view version should only ever be used during view methods, **never** during trading or the exchange rate will not be accurate.

When fCash settles at it's maturity, it settles to asset cash (not the underlying asset). For this to occur, we set **settlement rates** when the first fCash asset of a given maturity settles. All other fCash assets of the same maturity and currency will settle to asset cash at the same rate. Because total fCash of a maturity and currency will always net to zero, we know that the total amount of asset cash (positive and negative) will net to zero. It is not crucial that the settlement rate occurs exactly on the maturity date.

## Cash Group

All

## Invariants

- System wide fCash of a currency and maturity will net to zero

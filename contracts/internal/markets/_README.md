# Markets

Notional enables fixed rate lending and borrowing via on chain liquidity pools we call **markets**. Each currency may have a **Cash Group** which holds all the configuration related to the set of markets that
host lending and borrowing for that currency. In order to enable high capital efficiency for liquidity providers, liquidity is denominated in money market tokens (i.e. cTokens) that bear some underlying variable rate of interest. This is referred to as **asset cash** in the codebase and it has an exchange rate back to the underlying asset we call the **asset rate**

## Asset Rate

Liquidity in markets is provided (wherever possible) in asset cash, which means that it is a token that bears some amount of money market interest. fCash, however, is denominated in underlying terms such that it is a fixed amount of tokens redeemable at a fixed term. Asset rates enable the conversion of asset cash to underlying denomination for the purposes of settlement and trading.

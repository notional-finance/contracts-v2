# Settlement

Notional portfolio assets have maturities which makes them different from most ERC20 assets. fCash assets will settle at their designated maturity date and liquidity tokens settle every quarter along with their respective market. Settling assets is triggered automatically when accounts transact and determined by the `nextSettleTime` timestamp in their account context. Triggering of settlement is determined in `SettleAssetsExternal.sol` and the `mustSettleAssets.

## Settling fCash

fCash is denominated in underlying amounts but settled into **asset cash**. This means that an account with 1000 fDAI (fCash in DAI) will receive 1000 DAI worth of cDAI at maturity, given the settlement rate for that maturity. We store a single settlement rate for every maturity in a currency, guaranteeing that all fCash of the same maturity converts to asset cash at the same exchange rate. This ensures that the system always has equal positive and negative asset cash.

## Settling Liquidity Tokens

Liquidity tokens always settle at 90 day intervals when markets settle. Liquidity tokens are a claim on asset cash and fCash held in a market. A liquidity token, therefore, settles to those two components -- a positive asset cash balance and a net residual fCash position (most liquidity providers will have a negative fCash position as this is the default when providing liquidity). In addition, markets must be updated to account for the settled liquidity tokens.

The net residual fCash position does not necessarily settle at the same time as the liquidity token. A liquidity token in a 1 year market which is settled after the market closes at 9 months, will have a residual fCash asset with 9 months until maturity. This is called an **idiosyncratic fCash asset** or **ifCash** for short. This asset will stay in the liquidity provider's portfolio until it matures or is traded away.

## Settling Bitmap Assets

Bitmap portfolios can only have fCash assets so that reduces some complexity in settlement. However, due to the different time chunks updating the assets bitmap does require some specialized math and bitwise operations.

TODO: document maths here

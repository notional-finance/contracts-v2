# Outline

Notional V2 can be thought of as a state machine where user accounts and nToken accounts transition from one state to another via actions constrained by the valuation framework.

- User accounts and nToken account state must adhere to certain invariants at any given point in time and never lose track of assets.
- The valuation framework must value each asset properly and ensure that every asset in an account is properly aggregated.
- Each action must update the account state(s) properly and be constrained by the values reported by the valuation framework.
    - When trading: markets must also adhere to certain liquidity curve update rules.
    - During liquidation: liquidation must adhere to additional restrictions from the valuation framework.

## Account State

### User Account State

These invariants ensure that account state is properly handled. Account state can be updated in the following ways:

Assets can be updated via:

- Updating assets array by adding a new asset (may net off existing asset)
- Updating bitmap portfolio by adding signed fCash (may net off existing fCash)
- Settlement will convert assets into cash balances
- Transfer will transfer assets from one account to another
    - Includes liquidation and cash settlement

Cash balances and nToken balances can be updated via:

- Deposit or withdraw of cash
- Minting or redeeming nTokens, which must mint incentives
- Transferring nTokens, which must mint incentives
- Settling cash debt where a third party deposits cash into an account
- Settling assets where assets are converted to cash balances
- Liquidation which will result in a forced transfer of cash balances

Account context must adhere to these rules:

- `bitmapCurrencyId` is set to zero when asset array is being used. If it is set to any other value then the following must be true:
    - `assetArrayLength` must be zero.
    - `activeCurrencies` cannot contain the currency id set in `bitmapCurrencyId`
- `nextSettleTime` must be one of these two values:
    - If using asset arrays: the minimum settlement timestamp of all the assets in the asset array
    - If using bitmap portfolio: the UTC midnight take of the first bitmap reference
- `assetArrayLength` must match the actual number of assets stored in the array
- `hasDebt` must reconcile with the account having negative fCash assets or negative cash balances
    - `Constants.HAS_ASSET_DEBT` is set when there is a negative fCash asset
    - `Constants.HAS_CASH_DEBT` is set where there is a negative cash balance
- `activeCurrencies` is `bytes18` where each 2 bytes is a `uint16` currency id with the top two most significant bits set to denote if it is active in the portfolio or active in the cash balances.
- `activeCurrencies` must be sorted and never duplicated
- `activeCurrencies` must have corresponding `Constants.ACTIVE_IN_PORTFOLIO` and/or `Constants.ACTIVE_IN_BALANCES` flag set

### nToken Account State

nToken accounts are special because they are not tracked like normal user accounts and have special properties:

- Can never be liquidated because you cannot call FreeCollateral on an nToken account. nToken accounts have no "AccountContext" like user accounts.
- Can only ever hold cash and assets in their designated single currency (assets cannot be transferred to their account, this is prevented in ERC1155.sol).
- Their portfolio of assets is only updated during InitializeMarkets, SweepCashIntoMarkets, MintNToken and RedeemNToken.
- There can only be at most nToken account per currency

At any point in time the nToken portfolio of assets must adhere to these rules:

- Sufficient cash to cover withholding for negative idiosyncratic fCash
- There is one liquidity token for every active market
- There is one corresponding fCash asset for every active market (an edge case exists where this is exactly zero and the asset does not exist).
- There are at most (n - 2) idiosyncratic fCash assets where n is the number of liquidity tokens the nToken had in the previous quarter.

## Valuation

### Individual Asset Valuation

- fCash assets are discounted to present value, both risk adjusted and non risk adjusted
- Liquidity tokens decompose down to cash and fCash equivalents
- fCash assets and liquidity token fCash claims at the same maturity will net off before discounting
- Cash assets are converted from cToken equivalents down to underlying before converting to ETH
- nToken assets are converted to their aggregate present value

### Aggregate Asset Valuation

- All assets in the same currency are combined before converting to ETH with haircuts or buffers applied
- All cash assets are accounted for
- All portfolio assets are accounted for
- All proper haircuts are applied to nTokens and conversions to ETH

## Actions

- Deposit and Withdraw: add or remove cash from an account
- Settlement: removes assets and converts them to cash balances

### Liquidity Curve Transactions

- Trading fCash: add/remove fCash and cash from a particular market, updates account state
- Mint and Redeem nTokens: add/remove liquidity from markets, may also lend/borrow on markets

### Asset Transfers

- Transfer fCash, liquidity tokens: transfer of 
- Settle Cash Debt: force transfer of cash and assets to an account
- Purchase nToken Residual: transfer of cash and assets between nToken and an account
- Liquidation: force transfer of cash and assets when account is undercollateralized

## Miscellaneous 

- Getter/Setter methods for Governance Action
- ERC20 compliance
- Incentive emission rate
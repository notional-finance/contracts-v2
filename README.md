# Notional Contracts V2

Notional is a fixed rate lending and borrowing platform, built on Ethereum. **Fixed rates** differ from variable rates or stable rates because the interest rate **will not** change by for the term of the loan. Fixed rate loans are 25x variable rate loans in traditional financial markets because of the superior guarantees they offer. [Notional V1](https://github.com/notional-finance/contracts) first introduced our concepts of how to achieve fixed rates on Ethereum and Notional V2 extends upon those concepts to add support for fixed term loans out to 20 years. Notional V2 also introduces many improvements upon Notional V1, including superior capital efficiency, better upgradeability, and on chain governance.

## Codebase

The codebase is broken down into the following modules, each directory has a `_README.md` file that describes the module. A full protocol description can be found in WHITEPAPER.md.

```
contracts
|
└── external: all externally deployable contracts
|   └── actions: implementations of externally callable methods
|   └── adapters: adapter contracts used to interface between systems
|   └── governance: on chain governance system, forked from Compound Governor Alpha and COMP token (thanks!)
|
|       FreeCollateralExternal.sol: deployed library for checking account free collateral positions
|       Router.sol: implementation for proxy contract that delegates calls to appropriate action contract
|       SettleAssetsExternal.sol: deployed library for settling matured assets to cash
|       Views.sol: view only methods for inspecting system state
|
└── global: storage, struct and constant definitions
└── internal: shared internal libraries for handling generic system wide functionality
|   └── balances: encapsulates all internal balance and token transfer logic
|   └── liquidation: contains calculations for determining liquidation amounts
|   └── markets: contains logic for defining tradable assets and fCash liquidity curve
|   └── portfolio: handlers for account portfolios and transferring assets between them
|   └── settlement: contains logic for settling matured assets in portfolios
|   └── valuation: calculations for determining account free collateral positions
|
|       AccountContextHandler.sol: manages per account metadata
|       nTokenHandler.sol: manages nToken configuration and metadata
|
└── math: math libraries
└── mocks: mock contracts for testing internal libraries
```

# Statistics

## Code Size

| Module      | File                        | Code | Comments | Total Lines | Complexity / Line |
| :---------- | :-------------------------- | ---: | -------: | ----------: | ----------------: |
| Actions     | AccountAction.sol           |   92 |       51 |         167 |              10.9 |
| Actions     | BatchAction.sol             |  289 |       35 |         366 |              17.6 |
| Actions     | ERC1155Action.sol           |  228 |       73 |         343 |              17.1 |
| Actions     | GovernanceAction.sol        |  213 |      102 |         349 |              10.3 |
| Actions     | InitializeMarketsAction.sol |  408 |      144 |         618 |              11.5 |
| Actions     | LiquidateCurrencyAction.sol |  310 |       48 |         389 |               1.0 |
| Actions     | LiquidatefCashAction.sol    |  174 |       40 |         235 |               1.1 |
| Actions     | TradingAction.sol           |  423 |       42 |         521 |              12.5 |
| Actions     | nTokenAction.sol            |  245 |       65 |         355 |              10.6 |
| Actions     | nTokenMintAction.sol        |  220 |       52 |         307 |              15.5 |
| Actions     | nTokenRedeemAction.sol      |  211 |       51 |         301 |              14.2 |
| Adapters    | NotionalV1Migrator.sol      |  300 |       19 |         358 |               6.7 |
| Adapters    | cTokenAggregator.sol        |   35 |        6 |          52 |               2.9 |
| Adapters    | nTokenERC20Proxy.sol        |   74 |       43 |         136 |               0.0 |
| Balances    | BalanceHandler.sol          |  336 |       72 |         466 |              17.0 |
| Balances    | Incentives.sol              |   81 |       24 |         124 |              12.3 |
| Balances    | TokenHandler.sol            |  190 |       25 |         250 |              22.6 |
| External    | FreeCollateralExternal.sol  |   50 |       17 |          77 |               6.0 |
| External    | Router.sol                  |  183 |       34 |         241 |              32.8 |
| External    | SettleAssetsExternal.sol    |  106 |        9 |         132 |               6.6 |
| External    | Views.sol                   |  388 |       46 |         485 |               4.6 |
| Global      | Constants.sol               |   54 |       31 |         102 |               0.0 |
| Global      | StorageLayoutV1.sol         |   15 |       20 |          42 |               0.0 |
| Global      | Types.sol                   |  180 |      138 |         345 |               0.0 |
| Governance  | GovernorAlpha.sol           |  314 |       94 |         472 |              12.4 |
| Governance  | NoteERC20.sol               |  260 |       88 |         407 |              13.5 |
| Governance  | Reservoir.sol               |   32 |       23 |          66 |               6.2 |
| Internal    | AccountContextHandler.sol   |  180 |       47 |         268 |              29.4 |
| Internal    | nTokenHandler.sol           |  348 |       64 |         467 |               7.8 |
| Liquidation | LiquidateCurrency.sol       |  387 |       89 |         536 |              12.7 |
| Liquidation | LiquidatefCash.sol          |  332 |       68 |         455 |               9.3 |
| Liquidation | LiquidationHelpers.sol      |  175 |       27 |         229 |              13.1 |
| Markets     | AssetRate.sol               |  184 |       36 |         258 |              12.0 |
| Markets     | CashGroup.sol               |  284 |       45 |         370 |               6.3 |
| Markets     | DateTime.sol                |  139 |       19 |         189 |              28.8 |
| Markets     | Market.sol                  |  538 |      177 |         817 |              10.0 |
| Math        | ABDKMath64x64.sol           |  168 |       52 |         244 |              47.0 |
| Math        | Bitmap.sol                  |   56 |        7 |          75 |              16.1 |
| Math        | SafeInt256.sol              |   37 |       16 |          75 |              37.8 |
| Portfolio   | BitmapAssetsHandler.sol     |  232 |       16 |         288 |              15.1 |
| Portfolio   | PortfolioHandler.sol        |  301 |       46 |         398 |              20.3 |
| Portfolio   | TransferAssets.sol          |   84 |        6 |         102 |              11.9 |
| Settlement  | SettleBitmapAssets.sol      |  210 |       26 |         264 |              19.0 |
| Settlement  | SettlePortfolioAssets.sol   |  137 |       19 |         183 |              26.3 |
| Valuation   | AssetHandler.sol            |  203 |       33 |         275 |              16.7 |
| Valuation   | ExchangeRate.sol            |   70 |       23 |         108 |              14.3 |
| Valuation   | FreeCollateral.sol          |  391 |       45 |         495 |              15.9 |

## Test Coverage

TODO

## Gas Costs

TODO

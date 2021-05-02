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

TODO

## Test Coverage

TODO

## Gas Costs

TODO

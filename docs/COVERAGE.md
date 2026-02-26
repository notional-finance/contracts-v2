# Coverage Notes

- Free collateral: coverage evaluation is incomplete due to delegate calls.
- Settle assets: tests should be more deterministic to catch edge cases.
- Settle bitmap: remap bitmap flows still need explicit tests.
- Account context: add explicit tests for storage persistence and bitmap interactions.
- Bitmap assets: increase method-level branch coverage.
- Portfolio handler: increase branch coverage across state transitions.

### Invariants

- System-wide cash balances should be accounted for in either a market or stored cash balances.
- The sum of capital deposits should equal the currency balance.
- The sum of perpetual token balances should equal total supply.
- System-wide fCash at the same maturity should net to zero.
- System-wide liquidity tokens should be accounted for in markets.
- `AccountContext.hasDebt` must reconcile with balances and portfolio state.
- `AccountContext.activeCurrencies` must be set consistently after each state transition.
- `AccountContext.nextSettleTime` must remain consistent with portfolio maturities.
- `AccountContext.lastClaimTime` must update correctly after incentive claims.
- If an account has bitmap enabled, the ifCash asset bitmap must reconcile with stored assets.

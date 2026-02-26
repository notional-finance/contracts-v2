# Coverage Notes

- Free collateral: coverage evaluation is incomplete due to delegate calls.
- Settle assets: tests should be more deterministic to catch edge cases.
- Settle bitmap: remap bitmap flows still need explicit tests.
- Account context: add explicit tests for storage persistence and bitmap interactions.
- Bitmap assets: increase method-level branch coverage.
- Portfolio handler: increase branch coverage across state transitions.

### Invariants

- System wide cash balances should be accounted for in a market or a stored cash balance
- Sum of capital deposit should equal currency balance
- Sum of perpetual token balances should equal total supply

- System wide fCash of same maturity should net off to zero
- System wide liquidity tokens should be accounted for in markets

- Account context hasDebt must reconcile
- Account context active currencies must be set properly
- Account context next maturing asset
- Account context last mint time
- If has bitmap, ifCash asset map must reconcile

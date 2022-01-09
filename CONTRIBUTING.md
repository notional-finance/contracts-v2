# Contributing to Notional

:+1: Thanks for taking interest in Notional! Your contribution (big or small) will help build an open financial system for all. It's a massive undertaking and we're glad you're a part of it. :fire:

## Code of Conduct

This project and everyone participating in it is governed by the [Contributor Covenant Code of Conduct v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). By participating, you are expected to uphold this code. Please report unacceptable behavior to [support@notional.finance](mailto:support@notional.finance).

## How Can I Contribute?

### Report Bugs

Critical security issues should be reported privately to security@notional.finance or via Immunefi. In both cases they will be eligible for our bug bounty program. Gas optimizations or feature enhancements can be reported via Github issues.

### Improve Test Coverage and Documentation

Writing additional unit tests or helping improve documentation is a great way to get started in any open source project. Feel free to reach out in the "Development" channel on [Discord](https://discord.notional.finance) if you want help getting started.

### Participate in Governance

Notional V2 requires sophisticated and involved governors. If you're interested in contributing, consider participating in governance in the [Notional V2 forum](https://forum.notional.finance).

## Security Checklist

Security is paramount when contributing to a smart contract platform. Here is a (non-exhaustive) checklist of things to be aware of as you commit code (or audit) code in the Notional V2 system.

### User Input Validation

Unexpected or malicious user inputs are the easiest way to foul up a smart contract. Here is a non-exhaustive list of considerations when working with user inputs:

- If two parties are involved in a transaction, ensure that they are not the same address. Examples include: settle cash debt, liquidation, ERC1155 transfers, nToken ERC20 transfers.
- Notional Callbacks MUST validate that only the primary Notional proxy can call their callback method and that the sender supplied is the originating contract.
- The nToken account and the Notional Reserve cannot receive any assets, including ERC1155 transfers, cash balances, and nToken assets.
- Currency ID is validated in different ways. Just because a currency id is listed does not necessarily mean the action taken is also valid. When working with currency id, be mindful of validation. Here are some examples:
    - Depositing or Withdrawing from an invalid currency id will cause a revert (will attempt to transact with `address(0)`).
    - Liquidations with invalid currencies will cause the corresponding netAvailable to equal zero, which will cause a revert.
    - ERC1155 transfers with a currency that has no markets listed will fail the `_assertValidMaturity` test.
    - Attempting to trade on an invalid currency id or market index will result in loading an empty market and cause a failure.
- User storage balances are limited. Overflowing the storage bounds will revert. This is highly unlikely in a production scenario.

### Deferred Storage Updates

In some places, Notional V2 defers storage updates to either allow methods to remain as views (for calculation methods in liquidation) or for gas optimization (deferred ERC20 transfers and array portfolio updates). If improperly done, this can cause serious issues. If you are working with any methods that potentially modify storage, here is a checklist of things to consider:

- These objects have deferred storage updates: BalanceState, PortfolioState (array portfolio type), AccountContext
- These objects are updated in storage immediately: MarketParameters, BitmapPortfolio, CashGroup, all governance managed parameters.
- Whenever working with a user account, ensure that settlement occurs before loading any balances or assets.
- Settlement will return a new account context in memory. This account context must be used instead of the account context that was initially loaded. Note that this new account context is located at a different memory position as the account context that was initially loaded. Settlement DOES NOT store account contexts, instead it explicitly returns the account context to signal that it should not be ignored.
- When updating state between two counterparties, complete the full update of one party before attempting the update of the second party. This is not always possible (see: SettleCashDebt in TradingAction) but is generally recommended.

### Storage Layout

Storage layout is split between Solidity managed storage in `global/StorageLayoutV1.sol` and assembly managed storage in `global/StorageLib.sol`.

### Decimal Precision

Notional uses multiple types of decimal precision. A planned upgrade to Solidity 0.8.9+ will allow for us to use User Defined Types which will make working with multiple decimal precisions more developer friendly. Until then, these are the decimal precisions that are used:

- RATE_PRECISION (1e9): Is used to denominate interest rates and exchange rates between fCash and cash. Also used to denominate interest rate governance parameters such as fCash haircuts and buffers.
- EXCHANGE_PRECISION (1e18): Used in Compound exchange rates (asset rate) and generally used for Chainlink exchange rates (although the decimals is actually fetched via the contract).
- INTERNAL_TOKEN_PRECISION (1e8): Used to denominate all internal cash balances, nToken balances and fCash balances. Chosen to match cToken decimal denomination.
- PERCENTAGE_BASIS (1e2): Used to denominate haircuts, buffers and other governance parameters that are based on percentages. Chosen such that it fits within a single byte in storage.

### Balance Denominations

In addition to different decimal precisions, Notional also uses many different balance denominations. These different denominations CANNOT be added together. An upgrade to Solidity 0.8.9+ will help alleviate difficulties here.

- Underlying External: value of an underlying token in its native ERC20 decimal precision
- Underlying Internal: value of an underlying token in INTERNAL_TOKEN_PRECISION
- Asset External: value of an asset token in its native ERC20 token precision
- Asset Internal: value of an asset token in INTERNAL_TOKEN_PRECISION
- nToken: balance of an nToken in INTERNAL_TOKEN_PRECISION, must be converted to asset or underlying denomination using total present value and total supply.
- fCash: denominated as underlying internal, but can only be combined with fCash from other maturities after taking the present value

Most critically:
- asset token values cannot be combined with underlying token values.
- ETH exchange rates cannot be performed on asset token values.

### Re-Entrancy

Re-entrancy is possible in a few scenarios. Because storage writes are deferred, it is possible that re-entrancy can cause issues. A re-entrancy guard should be used on all methods that touch balances or call external methods (except for exceptions noted).

- Notional whitelists all ERC20 tokens and they should not be able to initiate re-entrancy calls. However, as an additional safety measure all external methods that call BalanceHandler.finalize should have a re-entrancy guard.
- ERC1155 calls a method on the fCash receiver contract which can initiate re-entrancy. This call will occur AFTER all storage is updated. ERC1155 does not have a re-entrancy guard to allow it to initiate other actions in the post transfer hook.
- ETH transfers are still done via `address.transfer()`, not the recommended `address{value: ..}.call("")` method. Currently, this continues to work and prevent re-entrancy. One of the largest contracts in value on Ethereum mainnet (WETH) also uses `address.transfer()` so any change to the gas cost of transfers would need to take this into account. If this changes, Notional can upgrade to use the `call` method.

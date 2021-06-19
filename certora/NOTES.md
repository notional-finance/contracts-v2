# Certora Verification Notes

## Questions:

## Feature requests:

- Allow handling of bytesNN
- Allow specifying bytesNN literals (0x01 for bytes1, etc) for example: `assert getHasDebt(account) == 0x01` (this currently errors if `getHasDebt` has a return type of bytes1)
- Confusing that methods does not need semicolons at end of line
- Allow specifying the contract reference for a spec in the file itself, currently this is done via the command line. With lots of harnesses this might get a bit confusing. Example syntax might be:

```
spec SpecName:path/to/HarnessName.sol {
   methods {...}
   rule {...}
   invariant {...}
}
```

- Allow for passing structs into methods. Some internal methods rely on structs being calldata so I have to change my code to allow for memory. Plus creating all these handlers results in a lot of boilerplate and potential typos.
- Allow for importing definitions. There are lot of constants and other definitions that I'd like to keep in a single file to remain DRY. Example:

```
definition MAX_TIMESTAMP() returns uint256 = 2^32 - 1;
// Cannot have timestamps less than 90 days
definition MIN_TIMESTAMP() returns uint256 = 7776000;
```

## Passing Specs:

- getAndSetAccountContext: https://prover.certora.com/output/42394/6b071c18cb0a275e912e?anonymousKey=2220f5496ccde20e2aa03287e83b918af89f5881

## Failing Specs:

### dateTime.spec

Link: https://prover.certora.com/output/42394/4145394959897cec05ac/?anonymousKey=14b782978ff254a50dff367e8dcebad2ee0f7182

- bitNumAndMaturitiesMustMatch is undecideable?
- validMarketMaturitesHaveAnIndex fails on a revert but this is the behavior that I want to see...

### accountContext.spec

Link: https://prover.certora.com/output/42394/6991dd007a609a776705/?anonymousKey=a86ae5dd7486e17fd2281892280259ac127c300e#activeCurrenciesAreNotDuplicatedAndSortedResults

- enablingBitmapCannotLeaveBehindAssets: Don't understand the calltrace, what is causing this to fail?
- bitmapPortfoliosCannotHaveAssetArray: Don't understand the calltrace, what is causing this to fail?
- bitmapCurrencyIsNotDuplicatedInActiveCurrencies: TODO: need to fix the masking
- activeCurrenciesAreNotDuplicatedAndSorted: TODO: need to fix the masking

## TODO Specs:

1. cashGroupSpec: cannot run with calldata, solidity cannot take args with memory array parameters...
1. ntoken getter setter: todo
1. liquidity curve spec: todo, add harness, last two invariants
1. valuation spec: todo, need to make harness and code invariants
   - asset value (fCash, liquidity token)
   - get portfolio value (nToken, bitmap, array) when oracle rates zre 0
   - exchange rate and asset rates are valid
   - free collateral when exchange rates are 1
1. settlement spec:
1. balance / token handler spec:
1. incentive handler spec:

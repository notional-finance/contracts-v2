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

## TODO Specs:

- dateTimeSpec: https://prover.certora.com/output/42394/4145394959897cec05ac/?anonymousKey=14b782978ff254a50dff367e8dcebad2ee0f7182

  - bitNumAndMaturitiesMustMatch is undecideable?
  - validMarketMaturitesHaveAnIndex fails on a revert but this is the behavior that I want to see...

- cashGroupSpec: cannot run with calldata, solidity cannot take args with memory array parameters...

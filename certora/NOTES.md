# Certora Verification Notes

## Questions:

- Is there a way to exclude a function from being included in invariant calculations?

```
--settings -ciMode=true     # ignores view functions

invariant I {
	preserved myFunc(uint,uint,address) with (env e) {
    require false;
  }
}
rule r(method f, uint256 x) filtered { f -> f.selector != myFunc().selector }  {
	require x > 10;
}

invariant i2 {
	preserved {
    // This requires that invariant i() is true but does not assert it....
		requireInvariant i();
	}
}
```

- Is there a way to combine invariants?
- Is there a way to decompose what the calldataargs are in this code example?
  https://github.com/Certora/CertoraProverSupplementary/blob/master/Tutorials/Lesson1/Parametric.spec

```
rule validityOfTotalFundsWithVars(method f) {
	env e;
  ...

	calldataarg arg; // any argument
  // Can I do something like this?
  uint argSlot1, bytes32 argSlot2 = arg;
  require argSlot1 > 0;
	sinvoke f(e, arg); // simulate only non reverting paths

  ...
}
```

## Feature requests:

- Would be nice to have a directory of all the prover runs for reference
- Allow handling of bytesNN
- Allow specifying bytesNN literals (0x01 for bytes1, etc) for example: `assert getHasDebt(account) == 0x01` (this currently errors if `getHasDebt` has a return type of bytes1)
- Confusing that methods does not need semicolons at end of line
- Allow specifying the contract reference for a spec in the file itself, currently this is done via the command line. With lots of harnesses this might get a bit confusing. Example syntax might be:
- save conf files...

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

### dateTime.spec

Link: https://prover.certora.com/output/42394/b3ebe7ce40a74d42ea64/?anonymousKey=37ce0b6119338d6d50b0c3c6331a141d1adfefa4

- bitNumAndMaturitiesMustMatch is timing out

### accountContext.spec

Link: https://prover.certora.com/output/42394/40b57a2db954ccf6e7d0/?anonymousKey=e9d1e62a2327a30b3133dbe63a060e4eaac45486

- activeCurrenciesAreNotDuplicatedAndSorted: might be a logic bug in the spec but I don't really understand it

## Failing Specs:

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
1. liquidation specs: todo

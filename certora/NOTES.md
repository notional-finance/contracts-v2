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

- How do i iterate over arrays (GovernanceActions.spec)
- How do i cast integers and do two's complement (Portfolio.spec)

## Feature requests:

- Why not allow named parameters in ghosts?
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

### DateTime.spec

Link: https://prover.certora.com/output/42394/b3ebe7ce40a74d42ea64/?anonymousKey=37ce0b6119338d6d50b0c3c6331a141d1adfefa4

- bitNumAndMaturitiesMustMatch is timing out

### AccountContext.spec

Link: https://prover.certora.com/output/42394/40b57a2db954ccf6e7d0/?anonymousKey=e9d1e62a2327a30b3133dbe63a060e4eaac45486

- activeCurrenciesAreNotDuplicatedAndSorted: might be a logic bug in the spec but I don't really understand it

## Failing Specs:

- OwnerGovernance.spec: cannot use bitVectorTheory and i think this causes some things to fail, need to white list methods is kind of annoying, should remove them from the report?

## TODO Specs:

1. cashGroupSpec: cannot run with calldata, solidity cannot take args with memory array parameters...
1. ntoken getter setter: how do i convert data types between integers sizes (uint32 => uint256, etc)
1. settlement spec: TODO: merge this into the account context spec
1. balance / token handler spec: TODO: merge this with the portfolio context spec using ghosts?
1. liquidity curve spec: todo, last two invariants
1. valuation spec: todo, need to make harness and code invariants
   - asset value (fCash, liquidity token)
   - get portfolio value (nToken, bitmap, array) when oracle rates zre 0
   - exchange rate and asset rates are valid
   - free collateral when exchange rates are 1
1. incentive handler spec:
1. liquidation specs: todo:
   - local net available, collateral net available, fc must increase
   - check aggregate balances do not change
1. nToken Mint / Redeem: todo
1. Initialize Markets: todo

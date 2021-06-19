# Certora Verification Notes

## Questions:

- Is there a way to exclude a function from being included in invariant calculations?
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

- This spec throws the following type error. It should be possible to do `i + 1`? Either way this does not error on the client side before submitting to the server.

```
definition getActiveMasked(address account, uint144 index) returns uint144 =
    (getActiveCurrencies(account) >> (128 - index * 16)) & 0x00000000000000000000000000000000ffff;
definition getActiveUnmasked(address account, uint144 index) returns uint144 =
    (getActiveCurrencies(account) >> (128 - index * 16)) & 0x000000000000000000000000000000003fff;
definition hasValidMask(address account, uint144 index) returns bool =
    (getActiveMasked(account, index) & 0x000000000000000000000000000000008000 == 0x000000000000000000000000000000008000) ||
    (getActiveMasked(account, index) & 0x000000000000000000000000000000004000 == 0x000000000000000000000000000000004000) ||
    (getActiveMasked(account, index) & 0x00000000000000000000000000000000c000 == 0x00000000000000000000000000000000c000);

invariant activeCurrenciesAreNotDuplicatedAndSorted(address account, uint144 i)
    0 <= i && i < i + 1 && i + 1 < 9 =>
        // If the current slot is zero then the next slot must also be zero
        getActiveMasked(account, i) == 0 ? getActiveMasked(account, i + 1) == 0 :
            hasValidMask(account, i) && (
                // The next slot may terminate
                getActiveMasked(account, i + 1) == 0 ||
                // Or it may have a value which must be greater than the current value
                (hasValidMask(account, i + 1) && getActiveUnmasked(account, i) < getActiveUnmasked(account, i + 1))
            )
Here is the job ID:
Status page: https://prover.certora.com/jobStatus/42394/f8d4357e9661b820fdff?anonymousKey=af0c4fb5d8adb5e785b8c439c6f7d45280cc6b99
Verification report: https://prover.certora.com/output/42394/f8d4357e9661b820fdff?anonymousKey=af0c4fb5d8adb5e785b8c439c6f7d45280cc6b99
Full report: https://prover.certora.com/zipOutput/42394/f8d4357e9661b820fdff?anonymousKey=af0c4fb5d8adb5e785b8c439c6f7d45280cc6b99

[main] ERROR TAC_TYPE_CHECKER - Argument tacTmp9887:int to the expression Mul(tacTmp9887:int tacTmp9890:bv256) is expected to be of type bv256 not Simple(type=int)
[main] ERROR log.Logger - Got exception A type error was found in CVLExp_i+int1 when compiling rule activeCurrenciesAreNotDuplicatedAndSorted_preserve
[main] ERROR log.Logger - analysis.TypeCheckerException: A type error was found in CVLExp_i+int1
        at analysis.TypeChecker$Companion.checkProgram(TypeChecker.kt:185)
        at vc.data.CoreTACProgram.<init>(TACProgram.kt:697)
        at vc.data.CoreTACProgram.copy(TACProgram.kt)
        at vc.data.CoreTACProgram.copy$default(TACProgram.kt)
        at vc.data.CoreTACProgram.addSink(TACProgram.kt:1256)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:46)
        at spec.CVLExpressionCompiler.compileMulExp(CVLExpressionCompiler.kt:123)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:822)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:44)
        at spec.CVLExpressionCompiler.compileSubExp(CVLExpressionCompiler.kt:92)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:829)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:44)
        at spec.CVLExpressionCompiler.compileBwRightShiftArithmeticalExp(CVLExpressionCompiler.kt:267)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:817)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:43)
        at spec.CVLExpressionCompiler.compileBwAndExp(CVLExpressionCompiler.kt:228)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:815)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:43)
        at spec.CVLExpressionCompiler.compileEqExp(CVLExpressionCompiler.kt:629)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:794)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileCondExp(CVLExpressionCompiler.kt:56)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:848)
        at spec.CVLCompiler.assumeExp(CVLCompiler.kt:612)
        at spec.CVLCompiler.assumeExp$default(CVLCompiler.kt:609)
        at spec.CVLCompiler.compileAssumeCmd(CVLCompiler.kt:905)
        at spec.CVLCompiler.compileCommand$EVMVerifier(CVLCompiler.kt:407)
        at spec.CVLCompiler.compileRule(CVLCompiler.kt:1096)
        at rules.RuleChecker.compileRuleWithCode(RuleChecker.kt:43)
        at rules.RuleChecker.singleRuleCheck(RuleChecker.kt:69)
        at rules.RuleChecker.check(RuleChecker.kt:441)
        at rules.RuleChecker.handleAllSubRules(RuleChecker.kt:428)
        at rules.RuleChecker.handleAllSubRules$default(RuleChecker.kt:427)
        at rules.RuleChecker.groupRuleCheck(RuleChecker.kt:393)
        at rules.RuleChecker.check(RuleChecker.kt:442)
        at rules.SpecChecker.check(SpecChecker.kt:110)
        at rules.SpecChecker.checkAll(SpecChecker.kt:131)
        at verifier.IntegrativeChecker.handleCVLs(IntegrativeChecker.kt:247)
        at verifier.IntegrativeChecker.runWithScene(IntegrativeChecker.kt:443)
        at verifier.IntegrativeChecker.run(IntegrativeChecker.kt:270)
        at EntryPointKt.handleCertoraScriptFlow(EntryPoint.kt:197)
        at EntryPointKt.main(EntryPoint.kt:99)
Failed to compile rule activeCurrenciesAreNotDuplicatedAndSorted_preserve due to analysis.TypeCheckerException: A type error was found in CVLExp_i+int1
[main] ERROR TAC_TYPE_CHECKER - Argument tacTmp9927:int to the expression Mul(tacTmp9927:int tacTmp9930:bv256) is expected to be of type bv256 not Simple(type=int)
[main] ERROR log.Logger - Got exception A type error was found in CVLExp_i+int1 when compiling rule activeCurrenciesAreNotDuplicatedAndSorted_instate
[main] ERROR log.Logger - analysis.TypeCheckerException: A type error was found in CVLExp_i+int1
        at analysis.TypeChecker$Companion.checkProgram(TypeChecker.kt:185)
        at vc.data.CoreTACProgram.<init>(TACProgram.kt:697)
        at vc.data.CoreTACProgram.copy(TACProgram.kt)
        at vc.data.CoreTACProgram.copy$default(TACProgram.kt)
        at vc.data.CoreTACProgram.addSink(TACProgram.kt:1256)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:46)
        at spec.CVLExpressionCompiler.compileMulExp(CVLExpressionCompiler.kt:123)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:822)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:44)
        at spec.CVLExpressionCompiler.compileSubExp(CVLExpressionCompiler.kt:92)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:829)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:44)
        at spec.CVLExpressionCompiler.compileBwRightShiftArithmeticalExp(CVLExpressionCompiler.kt:267)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:817)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:43)
        at spec.CVLExpressionCompiler.compileBwAndExp(CVLExpressionCompiler.kt:228)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:815)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileBinary(CVLExpressionCompiler.kt:43)
        at spec.CVLExpressionCompiler.compileEqExp(CVLExpressionCompiler.kt:629)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:794)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:777)
        at spec.CVLExpressionCompiler.compileCondExp(CVLExpressionCompiler.kt:56)
        at spec.CVLExpressionCompiler.compileExp(CVLExpressionCompiler.kt:848)
        at spec.CVLCompiler.compileAssertCmd(CVLCompiler.kt:917)
        at spec.CVLCompiler.compileCommand$EVMVerifier(CVLCompiler.kt:410)
        at spec.CVLCompiler.compileRule(CVLCompiler.kt:1096)
        at rules.RuleChecker.compileRuleWithCode(RuleChecker.kt:43)
        at rules.RuleChecker.singleRuleCheck(RuleChecker.kt:69)
        at rules.RuleChecker.check(RuleChecker.kt:441)
        at rules.RuleChecker.handleAllSubRules(RuleChecker.kt:428)
        at rules.RuleChecker.handleAllSubRules$default(RuleChecker.kt:427)
        at rules.RuleChecker.groupRuleCheck(RuleChecker.kt:393)
        at rules.RuleChecker.check(RuleChecker.kt:442)
        at rules.SpecChecker.check(SpecChecker.kt:110)
        at rules.SpecChecker.checkAll(SpecChecker.kt:131)
        at verifier.IntegrativeChecker.handleCVLs(IntegrativeChecker.kt:247)
        at verifier.IntegrativeChecker.runWithScene(IntegrativeChecker.kt:443)
        at verifier.IntegrativeChecker.run(IntegrativeChecker.kt:270)
        at EntryPointKt.handleCertoraScriptFlow(EntryPoint.kt:197)
        at EntryPointKt.main(EntryPoint.kt:99)
Failed to compile rule activeCurrenciesAreNotDuplicatedAndSorted_instate due to analysis.TypeCheckerException: A type error was found in CVLExp_i+int1
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
1. liquidation specs: todo

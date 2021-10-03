Declarations
UninterpFunc g_readsToAccountContext bv256 returns bv256
UninterpFunc g_writesToAccountContext bv256 returns bv256
UninterpFunc g_readsToAccountContext_old bv256 returns bv256
UninterpFunc g_writesToAccountContext_old bv256 returns bv256
import BuiltinFunc add_noofl bv256 bv256 returns bool
Variable g_readsToAccountContext uf
Variable g_writesToAccountContext uf
Variable g_readsToAccountContext_old uf
Variable g_writesToAccountContext_old uf
Variable currentContract bv256
Variable account bv256
Variable certoraTmpBool bool
Variable lastStorage!ce4604a000000000000000000000002a!0 wordmap
Variable tacS!ce4604a000000000000000000000002a wordmap
Variable lastStorage!ce4604a000000000000000000000002a!1 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!2 wordmap
Variable tacS!ce4604a000000000000000000000002a!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!3 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1000001)) wordmap
Variable tacS!ce4604a000000000000000000000002a!6!0 bv256
Variable lastStorage!ce4604a000000000000000000000002a!4 bv256
Variable lastStorage!ce4604a000000000000000000000002a!5 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=10))!0 wordmap
Variable lastStorage!ce4604a000000000000000000000002a!6 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=11)), offset=0))!0 wordmap
Variable lastStorage!ce4604a000000000000000000000002a!7 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1000009)) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!8 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!9 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=2)) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!10 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1)) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!11 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!12 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!13 wordmap
Variable tacS!ce4604a000000000000000000000002a!StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)), offset=1) wordmap
Variable lastStorage!ce4604a000000000000000000000002a!14 wordmap
Variable tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)) wordmap
Variable tacS!ce4604a000000000000000000000002a!5!0 bv256
Variable lastStorage!ce4604a000000000000000000000002a!15 bv256
Variable tacS!ce4604a000000000000000000000002a!3!0 bv256
Variable lastStorage!ce4604a000000000000000000000002a!16 bv256
Variable lastStorage!ce4604a0000000000000000000000028!0 wordmap
Variable tacS!ce4604a0000000000000000000000028 wordmap
Variable lastStorage!ce4604a0000000000000000000000028!1 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=2)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!2 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!3 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!4 wordmap
Variable tacS!ce4604a0000000000000000000000028!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!5 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1000009)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!6 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!7 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!8 wordmap
Variable tacS!ce4604a0000000000000000000000028!StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)), offset=1) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!9 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1000001)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!10 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000028!11 wordmap
Variable tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000029!0 wordmap
Variable tacS!ce4604a0000000000000000000000029 wordmap
Variable lastStorage!ce4604a0000000000000000000000029!1 wordmap
Variable tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000029!2 wordmap
Variable tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000029!3 wordmap
Variable tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000029!4 wordmap
Variable tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000029!5 wordmap
Variable tacS!ce4604a0000000000000000000000029!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)) wordmap
Variable lastStorage!ce4604a0000000000000000000000029!6 wordmap
Variable tacS!ce4604a0000000000000000000000029!MapAccess(base=Root(slot=2)) wordmap
Variable lastStorage!tacBalance wordmap
Variable tacBalance wordmap
Variable tacTmpextcodesizeCheck bool
Variable tacExtcodesize wordmap
Variable certoraAssume54731 bool
Variable certoraAssume54732 bool
Variable args bytemap
Variable e.msg.sender bv256
Variable certoraTmp2 bool
Variable certoraTmp bv256
Variable certora_balanceCheck14 bool
Variable e.msg.value bv256
Variable tacOrigS!ce4604a000000000000000000000002a!505 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!506 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!507 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!508 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!509 bv256
Variable tacOrigS!ce4604a000000000000000000000002a!510 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!511 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!512 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!513 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!514 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!515 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!516 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!517 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!518 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!519 wordmap
Variable tacOrigS!ce4604a000000000000000000000002a!520 bv256
Variable tacOrigS!ce4604a000000000000000000000002a!521 bv256
Variable tacOrigS!ce4604a0000000000000000000000028!486 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!487 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!488 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!489 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!490 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!491 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!492 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!493 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!494 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!495 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!496 wordmap
Variable tacOrigS!ce4604a0000000000000000000000028!497 wordmap
Variable tacOrigS!ce4604a0000000000000000000000029!498 wordmap
Variable tacOrigS!ce4604a0000000000000000000000029!499 wordmap
Variable tacOrigS!ce4604a0000000000000000000000029!500 wordmap
Variable tacOrigS!ce4604a0000000000000000000000029!501 wordmap
Variable tacOrigS!ce4604a0000000000000000000000029!502 wordmap
Variable tacOrigS!ce4604a0000000000000000000000029!503 wordmap
Variable tacOrigS!ce4604a0000000000000000000000029!504 wordmap
Variable tacOrigBalance!522 wordmap
Variable certora_returnSizeMatch14 bool
Variable tacCalldatabuf@14 bytemap
Variable tacCalldatasize@14 bv256
Variable args!size bv256
Variable lastHasThrown bool
Variable tacCaller@14 bv256
Variable tacCallvalue@14 bv256
Variable tacAddress@14 bv256
Variable e.msg.address bv256
Variable tacOrigin@14 bv256
Variable tacNumber@14 bv256
Variable e.block.number bv256
Variable tacTimestamp@14 bv256
Variable e.block.timestamp bv256
Variable tacTmpSrcNewValue int
Variable tacTmpTrgNewValue bv256
Variable tacTmptrgNewBalanceNoofl bool
Variable lastReverted bool
Variable certoraAssert_1 bool
Variable f.isPure bool
Variable f.isView bool
Variable f.isPayable bool
Variable f.isFallback bool
Variable tacTmp54719 bv256
Variable tacTmp54721 bv256
Variable tacTmp54722 bv256
Variable tacTmp54720 int
Variable tacTmp54718 bool
Variable tacTmp54723 bool
Variable certoraAssume54717 bool
Variable tacTmp54726 bv256
Variable tacTmp54728 bv256
Variable tacTmp54729 bv256
Variable tacTmp54727 int
Variable tacTmp54725 bool
Variable tacTmp54730 bool
Variable certoraAssume54724 bool
Variable lastHasThrown@14 bool
Variable lastReverted@14 bool
Variable R0@14 bv256
Variable B1@14 bool
Variable tacM0x40@14 bv256
Variable R2@14 bv256
Variable B3@14 bool
Variable R12@14 bv256
Variable B17@14 bool
Variable tacSighash@14 bv256
Variable B23@14 bool
Variable B35@14 bool
Variable B59@14 bool
Variable B107@14 bool
Variable B216@14 bool
Variable B555@14 bool
Variable B1202@14 bool
Variable B2024@14 bool
Variable tacM@14 bytemap
Block 0_0_0_0_0_0_0_0
AssignExpCmd f.isPure:bool false 
AssignExpCmd f.isView:bool false 
AssignExpCmd f.isPayable:bool false 
AssignExpCmd f.isFallback:bool true 
// AnnotationCmd  
AssignExpCmd currentContract:bv256 0xce4604a000000000000000000000002a 
// AnnotationCmd  
// AnnotationCmd  
AssignHavocCmd account:bv256 
AssignExpCmd certoraTmpBool:bool LAnd(Le(0x0 account:bv256) Le(account:bv256 0xffffffffffffffffffffffffffffffffffffffff)) 
AssumeCmd certoraTmpBool:bool 
// AnnotationCmd  
// AnnotationCmd  
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!0:wordmap tacS!ce4604a000000000000000000000002a:wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!1:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!2:wordmap tacS!ce4604a000000000000000000000002a!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!3:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1000001)):wordmap 
AssignExpCmd certoraTmpBool:bool LAnd(Le(0x0 tacS!ce4604a000000000000000000000002a!6!0:bv256) Le(tacS!ce4604a000000000000000000000002a!6!0:bv256 0xffffffffffffffffffffffffffffffffffffffff)) 
AssumeCmd certoraTmpBool:bool 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!4:bv256 tacS!ce4604a000000000000000000000002a!6!0:bv256 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!5:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=10))!0:wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!6:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=11)), offset=0))!0:wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!7:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1000009)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!8:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!9:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!10:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!11:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!12:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!13:wordmap tacS!ce4604a000000000000000000000002a!StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)), offset=1):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!14:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd certoraTmpBool:bool LAnd(Le(0x0 tacS!ce4604a000000000000000000000002a!5!0:bv256) Le(tacS!ce4604a000000000000000000000002a!5!0:bv256 0xffffffffffffffffffffffffffffffffffffffff)) 
AssumeCmd certoraTmpBool:bool 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!15:bv256 tacS!ce4604a000000000000000000000002a!5!0:bv256 
AssignExpCmd certoraTmpBool:bool LAnd(Le(0x0 tacS!ce4604a000000000000000000000002a!3!0:bv256) Le(tacS!ce4604a000000000000000000000002a!3!0:bv256 0xffffffffffffffffffffffffffffffffffffffff)) 
AssumeCmd certoraTmpBool:bool 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!16:bv256 tacS!ce4604a000000000000000000000002a!3!0:bv256 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!0:wordmap tacS!ce4604a0000000000000000000000028:wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!1:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!2:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!3:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!4:wordmap tacS!ce4604a0000000000000000000000028!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!5:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1000009)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!6:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!7:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!8:wordmap tacS!ce4604a0000000000000000000000028!StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)), offset=1):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!9:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1000001)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!10:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!11:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!0:wordmap tacS!ce4604a0000000000000000000000029:wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!1:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!2:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!3:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!4:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!5:wordmap tacS!ce4604a0000000000000000000000029!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!6:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd lastStorage!tacBalance:wordmap tacBalance:wordmap 
// AnnotationCmd  
// AnnotationCmd  
AssignExpCmd tacTmpextcodesizeCheck:bool Gt(Select(tacExtcodesize:wordmap 0xce4604a000000000000000000000002a) 0x0) 
AssumeCmd tacTmpextcodesizeCheck:bool 
AssignExpCmd tacTmpextcodesizeCheck:bool Gt(Select(tacExtcodesize:wordmap 0xce4604a0000000000000000000000028) 0x0) 
AssumeCmd tacTmpextcodesizeCheck:bool 
AssignExpCmd tacTmpextcodesizeCheck:bool Gt(Select(tacExtcodesize:wordmap 0xce4604a0000000000000000000000029) 0x0) 
AssumeCmd tacTmpextcodesizeCheck:bool 
// AnnotationCmd  
Block 32_0_0_0_0_0_0_0
// AnnotationCmd  
Block 33_0_0_0_0_0_0_0
AssignExpCmd certoraAssume54731:bool Forall( QVars(a:bv256) LAnd(true true Eq(Apply(g_readsToAccountContext:uf a:bv256) 0x0))) 
Block 34_0_0_0_0_0_0_0
AssumeCmd certoraAssume54731:bool 
Block 35_0_0_0_0_0_0_0
// AnnotationCmd  
Block 36_0_0_0_0_0_0_0
// AnnotationCmd  
Block 37_0_0_0_0_0_0_0
AssignExpCmd certoraAssume54732:bool Forall( QVars(a1:bv256) LAnd(true true Eq(Apply(g_writesToAccountContext:uf a1:bv256) 0x0))) 
Block 38_0_0_0_0_0_0_0
AssumeCmd certoraAssume54732:bool 
Block 39_0_0_0_0_0_0_0
// AnnotationCmd  
Block 40_0_0_0_0_0_0_0
NopCmd  
Block 41_0_0_0_0_0_0_0
NopCmd  
Block 42_0_0_0_0_0_0_0
// AnnotationCmd  
Block 53_0_0_0_0_0_0_0
// AnnotationCmd  
AssignExpCmd certoraTmpBool:bool Lt(e.msg.sender:bv256 0x10000000000000000000000000000000000000000) 
AssumeCmd certoraTmpBool:bool 
AssignExpCmd certoraTmpBool:bool Gt(e.msg.sender:bv256 0x0) 
AssignExpCmd certoraTmp2:bool Eq(e.msg.sender:bv256 0x0) 
AssignExpCmd certoraTmpBool:bool LOr(certoraTmpBool:bool certoraTmp2:bool) 
AssumeCmd certoraTmpBool:bool 
WordLoad certoraTmp:bv256 e.msg.sender:bv256 tacBalance:wordmap 
AssignExpCmd certora_balanceCheck14:bool Lt(certoraTmp:bv256 e.msg.value:bv256) 
JumpiCmd 44_0_0_0_0_0_0_0 43_0_0_0_0_0_0_0 certora_balanceCheck14:bool 
Block 43_0_0_0_0_0_0_0
NopCmd  
Block 52_0_0_0_0_0_0_0
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!505:wordmap tacS!ce4604a000000000000000000000002a:wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!506:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!507:wordmap tacS!ce4604a000000000000000000000002a!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!508:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1000001)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!509:bv256 tacS!ce4604a000000000000000000000002a!6!0:bv256 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!510:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=10))!0:wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!511:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=11)), offset=0))!0:wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!512:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1000009)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!513:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!514:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!515:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!516:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!517:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!518:wordmap tacS!ce4604a000000000000000000000002a!StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)), offset=1):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!519:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!520:bv256 tacS!ce4604a000000000000000000000002a!5!0:bv256 
AssignExpCmd tacOrigS!ce4604a000000000000000000000002a!521:bv256 tacS!ce4604a000000000000000000000002a!3!0:bv256 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!486:wordmap tacS!ce4604a0000000000000000000000028:wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!487:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!488:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!489:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!490:wordmap tacS!ce4604a0000000000000000000000028!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!491:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1000009)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!492:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!493:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!494:wordmap tacS!ce4604a0000000000000000000000028!StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)), offset=1):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!495:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1000001)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!496:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000028!497:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000029!498:wordmap tacS!ce4604a0000000000000000000000029:wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000029!499:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000029!500:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000029!501:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000029!502:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000029!503:wordmap tacS!ce4604a0000000000000000000000029!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd tacOrigS!ce4604a0000000000000000000000029!504:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd tacOrigBalance!522:wordmap tacBalance:wordmap 
// AnnotationCmd  
AssignExpCmd certora_returnSizeMatch14:bool true 
AssignExpCmd tacCalldatabuf@14:bytemap args:bytemap 
AssignExpCmd tacCalldatasize@14:bv256 args!size:bv256 
AssignExpCmd lastHasThrown:bool false 
AssignExpCmd tacCaller@14:bv256 e.msg.sender:bv256 
AssignExpCmd certoraTmpBool:bool LAnd(Le(0x0 tacCaller@14:bv256) Le(tacCaller@14:bv256 0xffffffffffffffffffffffffffffffffffffffff)) 
AssumeCmd certoraTmpBool:bool 
AssignExpCmd tacCallvalue@14:bv256 e.msg.value:bv256 
AssignExpCmd certoraTmpBool:bool Eq(tacAddress@14:bv256 e.msg.address:bv256) 
AssumeCmd certoraTmpBool:bool 
AssignExpCmd certoraTmpBool:bool LAnd(Le(0x0 tacAddress@14:bv256) Le(tacAddress@14:bv256 0xffffffffffffffffffffffffffffffffffffffff)) 
AssumeCmd certoraTmpBool:bool 
AssignExpCmd tacAddress@14:bv256 0xce4604a000000000000000000000002a 
AssignExpCmd certoraTmp:bv256 tacOrigin@14:bv256 
AssignExpCmd certoraTmpBool:bool LAnd(Le(0x0 tacOrigin@14:bv256) Le(tacOrigin@14:bv256 0xffffffffffffffffffffffffffffffffffffffff)) 
AssumeCmd certoraTmpBool:bool 
AssignExpCmd tacNumber@14:bv256 e.block.number:bv256 
AssignExpCmd tacTimestamp@14:bv256 e.block.timestamp:bv256 
AssignExpCmd tacTmpSrcNewValue:int IntSub(Select(tacBalance:wordmap e.msg.sender:bv256) e.msg.value:bv256) 
WordStore e.msg.sender:bv256 tacTmpSrcNewValue:int tacBalance:wordmap 
AssignExpCmd tacTmpTrgNewValue:bv256 Add(Select(tacBalance:wordmap 0xce4604a000000000000000000000002a) e.msg.value:bv256) 
AssignExpCmd tacTmptrgNewBalanceNoofl:bool Apply(add_noofl:bif Select(tacBalance:wordmap 0xce4604a000000000000000000000002a) e.msg.value:bv256) 
AssumeCmd tacTmptrgNewBalanceNoofl:bool 
WordStore 0xce4604a000000000000000000000002a tacTmpTrgNewValue:bv256 tacBalance:wordmap 
LabelCmd 'Invoke f args :14' 
JumpCmd [0_0_0_0_14_0_19598_0] 
Block 47_0_0_0_0_0_0_0
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!0:wordmap tacS!ce4604a000000000000000000000002a:wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!1:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!2:wordmap tacS!ce4604a000000000000000000000002a!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!3:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1000001)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!4:bv256 tacS!ce4604a000000000000000000000002a!6!0:bv256 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!5:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=10))!0:wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!6:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=11)), offset=0))!0:wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!7:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1000009)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!8:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!9:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!10:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=Root(slot=1)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!11:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!12:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!13:wordmap tacS!ce4604a000000000000000000000002a!StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)), offset=1):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!14:wordmap tacS!ce4604a000000000000000000000002a!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!15:bv256 tacS!ce4604a000000000000000000000002a!5!0:bv256 
AssignExpCmd lastStorage!ce4604a000000000000000000000002a!16:bv256 tacS!ce4604a000000000000000000000002a!3!0:bv256 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!0:wordmap tacS!ce4604a0000000000000000000000028:wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!1:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!2:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!3:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!4:wordmap tacS!ce4604a0000000000000000000000028!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!5:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1000009)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!6:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!7:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!8:wordmap tacS!ce4604a0000000000000000000000028!StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000010)), offset=0)), offset=0)), offset=1):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!9:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=Root(slot=1000001)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!10:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000028!11:wordmap tacS!ce4604a0000000000000000000000028!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!0:wordmap tacS!ce4604a0000000000000000000000029:wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!1:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000006)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!2:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000011)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!3:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000012)), offset=0)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!4:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000008)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!5:wordmap tacS!ce4604a0000000000000000000000029!ArrayAccess(base=StructAccess(base=MapAccess(base=Root(slot=1000013)), offset=0)):wordmap 
AssignExpCmd lastStorage!ce4604a0000000000000000000000029!6:wordmap tacS!ce4604a0000000000000000000000029!MapAccess(base=Root(slot=2)):wordmap 
AssignExpCmd lastStorage!tacBalance:wordmap tacBalance:wordmap 
// AnnotationCmd  
Block 45_0_0_0_0_0_0_1
NopCmd  
AssumeNotCmd lastReverted:bool 
AssumeNotCmd lastHasThrown:bool 
// AnnotationCmd  
Block 44_0_0_0_0_0_0_0
AssignExpCmd lastReverted:bool true 
AssignExpCmd lastHasThrown:bool false 
Block 54_0_0_0_0_0_0_0
// AnnotationCmd  
Block 55_0_0_0_0_0_0_0
// AnnotationCmd  
Block 56_0_0_0_0_0_0_0
AssignExpCmd certoraAssert_1:bool Forall( QVars(a2:bv256) LAnd(true true LOr(LAnd(true true LAnd(LAnd(true true Eq(Apply(g_readsToAccountContext:uf a2:bv256) Apply(g_writesToAccountContext:uf a2:bv256))) LAnd(true true Le(Apply(g_readsToAccountContext:uf a2:bv256) 0x1)))) LAnd(true true Eq(Apply(g_writesToAccountContext:uf a2:bv256) 0x0))))) 
Block 57_0_0_0_0_0_0_0
AssertCmd certoraAssert_1:bool '' 
Block 58_0_0_0_0_0_0_0
// AnnotationCmd  
Block 0_0_0_0_14_0_19598_0
LabelCmd 'Start procedure ERC1155Action-fallback' 
// AnnotationCmd  
AssignExpCmd lastHasThrown@14:bool false 
AssignExpCmd lastReverted@14:bool false 
WordLoad R0@14:bv256 tacAddress@14:bv256 tacExtcodesize:wordmap 
AssignExpCmd B1@14:bool Gt(R0@14:bv256 0x0) 
AssumeCmd B1@14:bool 
AssignExpCmd tacM0x40@14:bv256 0x80 (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol
AssignExpCmd R2@14:bv256 tacCalldatasize@14:bv256 (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol
AssignExpCmd B3@14:bool Lt(tacCalldatasize@14:bv256 0x4) 
JumpiCmd 1395_1025_0_0_14_0_19604_0 13_1025_0_0_14_0_19600_0 B3@14:bool (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol
Block 13_1025_0_0_14_0_19600_0
ByteLoad R12@14:bv256 0x0 tacCalldatabuf@14:bytemap (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol
AssignExpCmd B17@14:bool Gt(0x8167aae8 tacSighash@14:bv256) 
AssumeNotCmd B17@14:bool 
AssignExpCmd B23@14:bool Gt(0xb3094c95 tacSighash@14:bv256) 
AssumeNotCmd B23@14:bool 
AssignExpCmd B35@14:bool Gt(0xd07bc0fb tacSighash@14:bv256) 
AssumeNotCmd B35@14:bool 
AssignExpCmd B59@14:bool Gt(0xeb67b1d8 tacSighash@14:bv256) 
AssumeNotCmd B59@14:bool 
AssignExpCmd B107@14:bool Gt(0xf1e03874 tacSighash@14:bv256) 
AssumeNotCmd B107@14:bool 
AssignExpCmd B216@14:bool Eq(0xf1e03874 tacSighash@14:bv256) 
AssumeNotCmd B216@14:bool 
AssignExpCmd B555@14:bool Eq(0xf242432a tacSighash@14:bv256) 
AssumeNotCmd B555@14:bool 
AssignExpCmd B1202@14:bool Eq(0xf682bb50 tacSighash@14:bv256) 
AssumeNotCmd B1202@14:bool 
AssignExpCmd B2024@14:bool Eq(0xfe09f2f9 tacSighash@14:bv256) 
AssumeNotCmd B2024@14:bool 
JumpdestCmd 1395_1024_0_0_0_0_0_0 
AssignExpCmd lastHasThrown@14:bool false (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol
AssignExpCmd lastReverted@14:bool true (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol
// AnnotationCmd  
LabelCmd 'End procedure ERC1155Action-fallback' 
AssignExpCmd lastReverted:bool true 
AssignExpCmd lastHasThrown:bool false 
SummaryCmd(summ=ReturnSummary(ret=RevertCmd 0x0 0x0 BENIGN tacM@14:bytemap (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol), meta={})
JumpCmd [59_0_0_0_0_0_0_0] 
Block 1395_1025_0_0_14_0_19604_0
JumpdestCmd 1395_1025_0_0_14_0_19604_0 
AssignExpCmd lastHasThrown@14:bool false (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol
AssignExpCmd lastReverted@14:bool true (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol
// AnnotationCmd  
LabelCmd 'End procedure ERC1155Action-fallback' 
AssignExpCmd lastReverted:bool true 
AssignExpCmd lastHasThrown:bool false 
SummaryCmd(summ=ReturnSummary(ret=RevertCmd 0x0 0x0 BENIGN tacM@14:bytemap (507:30705:9:0xce4604a000000000000000000000002a) // .certora_config/autoFinder_ERC1155Action.sol_0/9_autoFinder_ERC1155Action.sol), meta={})
JumpCmd [59_0_0_0_0_0_0_0] 
Block 59_0_0_0_0_0_0_0
JumpCmd [47_0_0_0_0_0_0_0] 
Graph
0_0_0_0_0_0_0_0 -> 32_0_0_0_0_0_0_0
32_0_0_0_0_0_0_0 -> 33_0_0_0_0_0_0_0
33_0_0_0_0_0_0_0 -> 34_0_0_0_0_0_0_0
34_0_0_0_0_0_0_0 -> 35_0_0_0_0_0_0_0
35_0_0_0_0_0_0_0 -> 36_0_0_0_0_0_0_0
36_0_0_0_0_0_0_0 -> 37_0_0_0_0_0_0_0
37_0_0_0_0_0_0_0 -> 38_0_0_0_0_0_0_0
38_0_0_0_0_0_0_0 -> 39_0_0_0_0_0_0_0
39_0_0_0_0_0_0_0 -> 40_0_0_0_0_0_0_0
40_0_0_0_0_0_0_0 -> 41_0_0_0_0_0_0_0
41_0_0_0_0_0_0_0 -> 42_0_0_0_0_0_0_0
42_0_0_0_0_0_0_0 -> 53_0_0_0_0_0_0_0
53_0_0_0_0_0_0_0 -> 43_0_0_0_0_0_0_0 44_0_0_0_0_0_0_0
43_0_0_0_0_0_0_0 -> 52_0_0_0_0_0_0_0
52_0_0_0_0_0_0_0 -> 0_0_0_0_14_0_19598_0
47_0_0_0_0_0_0_0 -> 45_0_0_0_0_0_0_1
45_0_0_0_0_0_0_1 -> 54_0_0_0_0_0_0_0
44_0_0_0_0_0_0_0 -> 45_0_0_0_0_0_0_1
54_0_0_0_0_0_0_0 -> 55_0_0_0_0_0_0_0
55_0_0_0_0_0_0_0 -> 56_0_0_0_0_0_0_0
56_0_0_0_0_0_0_0 -> 57_0_0_0_0_0_0_0
57_0_0_0_0_0_0_0 -> 58_0_0_0_0_0_0_0
58_0_0_0_0_0_0_0 -> 
0_0_0_0_14_0_19598_0 -> 1395_1025_0_0_14_0_19604_0 13_1025_0_0_14_0_19600_0
13_1025_0_0_14_0_19600_0 -> 59_0_0_0_0_0_0_0
1395_1025_0_0_14_0_19604_0 -> 59_0_0_0_0_0_0_0
59_0_0_0_0_0_0_0 -> 47_0_0_0_0_0_0_0

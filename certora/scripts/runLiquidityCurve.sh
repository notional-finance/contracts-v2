certoraRun.py contracts/mocks/certora/LiquidityCurveHarness.sol \
 	--verify LiquidityCurveHarness:certora/asset/LiquidityCurve.spec \
 	--solc solc7.6 \
	--optimistic_loop \
 	--loop_iter 2 \
    --rule $1 \
	--cache liquidityCurveHarness \
	--settings -t=1200,-depth=1,-smt_bitVectorTheory=true,-smt_hashingScheme=plainInjectivity,-postProcessCounterExamples=true \
	--packages_path ${BROWNIE_PATH}/packages \
	--short_output	--packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
 	--solc_args "['--optimize']" --staging --msg "LiquidityCurve: $1 - $2"

#	,-postProcessCounterExamples=true
#	,-ruleSanityChecks
#	-solver=z3,
#   -smt_bitVectorTheory=true,
#   shelly/robustnessAndCalldatasize
#	alex/bv-solver-strategy 
#   -smt_hashingScheme=plainInjectivity
#   -useNonLinearArithmetic
#   --javaArgs '"-Dcvt.default.parallelism=3"'
#   --staging alex/mod-vs-bv


certoraRun contracts/mocks/certora/LiquidityCurveHarness.sol \
 	--verify LiquidityCurveHarness:certora/asset/LiquidityCurve.spec \
 	--solc solc7.6 \
	--optimistic_loop \
 	--loop_iter 1 \
    --rule $1 \
	--settings -adaptiveSolverConfig=false,-solver=z3,-smt_hashingScheme=plainInjectivity,-postProcessCounterExamples=true \
	--packages_path '/Users/gadirechlis/.brownie/packages' \
	--packages @openzeppelin=/Users/gadirechlis/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=/Users/gadirechlis/.brownie/packages/compound-finance \
 	--solc_args "['--optimize']" --staging shelly/robustnessAndCalldatasize --msg "LiquidityCurve: $1 - $2"
#   -smt_bitVectorTheory=true,
#   shelly/robustnessAndCalldatasize
#	alex/bv-solver-strategy 
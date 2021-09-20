certoraRun contracts/mocks/certora/ValuationHarness.sol \
 	--verify ValuationHarness:certora/asset/Valuation.spec \
 	--solc $SOLC/solc7.5 \
	--optimistic_loop \
 	--loop_iter 1 \
	--settings -smt_bitVectorTheory=true,-smt_hashingScheme=plainInjectivity \
	--packages_path ${BROWNIE_PATH}/packages \
	--packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --msg "valuation $1" --javaArgs '"-Dverbose.times"' --settings -enableEqualitySaturation=false

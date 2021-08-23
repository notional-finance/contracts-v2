certoraRun contracts/mocks/certora/GetterSetterHarness.sol \
 	--verify GetterSetterHarness:certora/accountContext/SetAccountContext.spec \
 	--solc solc7.6 \
	--optimistic_loop \
 	--loop_iter 1 \
	--settings -smt_bitVectorTheory=true,-smt_hashingScheme=plainInjectivity \
	--packages_path ${BROWNIE_PATH}/packages \
	--packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --msg "AccountContext - all rules bv branch"
	 

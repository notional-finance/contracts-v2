certoraRun contracts/mocks/certora/StorageHarness.sol \
 	--verify StorageHarness:certora/storage/GovernanceAction.spec \
 	--solc solc7.6 \
	--rule_sanity \
	--optimistic_loop \
 	--loop_iter 7 \
	--settings -smt_bitVectorTheory=true \
 	--packages_path ${BROWNIE_PATH}'/packages' \
 	--packages interfaces=${PWD}/interfaces @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.2-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --staging --msg "run all specs"

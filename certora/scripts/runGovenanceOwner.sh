certoraRun contracts/mocks/certora/GovernanceActionHarness.sol \
 	--verify GovernanceActionHarness:certora/governance/GovernanceOwner.spec \
 	--solc $SOLC/solc7.5 \
	--optimistic_loop \
        --loop_iter 7 \
	--settings -smt_bitVectorTheory=true,-smt_hashingScheme=plainInjectivity \
	--packages_path ${BROWNIE_PATH}/packages \
	--packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance interfaces=$PWD'/interfaces' \
 	--solc_args "['--optimize', '--optimize-runs', '200']" --staging --msg "governance owner"

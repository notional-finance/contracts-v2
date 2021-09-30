certoraRun contracts/external/actions/AccountAction.sol \
	contracts/mocks/certora/BalanceStateHarness.sol \
	contracts/mocks/certora/DummyERC20Impl.sol \
	contracts/mocks/certora/DummyERC20ImplCToken.sol \
 	--verify BalanceStateHarness:certora/asset/BalanceState.spec \
	--rule $1 \
 	--solc solc7.6 \
	--optimistic_loop \
 	--loop_iter 1 \
    --javaArgs '"-Dverbose.times"' \
    --settings -enableEqualitySaturation=false,-useNonLinearArithmetic,-depth=16,-t=50 \
	--cache BalanceHandlerNotional \
	--packages_path ${BROWNIE_PATH}/packages \
	--packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
 	--solc_args "['--optimize']" --msg "BalanceState - $1" --staging
	 
#--settings -smt_bitVectorTheory=true,-adaptiveSolverConfig=false,-solver=z3,-smt_hashingScheme=plainInjectivity \

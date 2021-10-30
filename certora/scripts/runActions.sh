echo "Usage ExternalContractName: AccountAction / ERC1155Action / nTokenAction / ..."
contract=$1
certoraRun contracts/external/actions/${contract}.sol \
	--verify ${contract}:certora/shellyActions.spec \
	--packages interfaces=${PWD}/interfaces @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
	--msg "Notional - ${contract} counting - modified portfolio handler" --staging shelly/binTAC --cache Notional5${contract} --optimistic_loop --settings "-enableEqualitySaturation=false,-s=cvc4,-adaptiveSolverConfig=false,-depth=10,-copyLoopUnroll=4,-t=100" --javaArgs '"-Dcvt.default.parallelism=6 -Dverbose.times"' --solc solc7.6

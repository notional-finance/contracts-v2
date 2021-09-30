echo "Usage ExternalContractName: AccountAction / ERC1155Action / nTokenAction / ..."
contract=$1
certoraRun contracts/external/actions/${contract}.sol \
	--verify ${contract}:certora/shellyActions.spec \
	--packages interfaces=${PWD}/interfaces @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
	--msg "Notional - ${contract} counting - modified portfolio handler pattern with nondets depth 5" --staging shelly/binTAC --cache Notional5${contract} --optimistic_loop --settings "-enableEqualitySaturation=false,-s=cvc4,-adaptiveSolverConfig=false,-m=withdraw(uint16,uint88,bool),-depth=12,-verifyTACDumps" --javaArgs '"-Dcvt.default.parallelism=4"' --solc solc7.6

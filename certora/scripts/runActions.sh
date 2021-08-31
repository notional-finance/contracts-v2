certoraRun contracts/external/actions/AccountAction.sol \
	--verify AccountAction:certora/shellyActions.spec \
	--staging shelly/specialStorageHashDetectionForNotional \
	--packages interfaces=${PWD}/interfaces @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
	--msg "Notional - Account actions counting"

echo "Usage ExternalContractName: AccountAction / ERC1155Action / nTokenAction / ..."
contract=$1
certoraRun contracts/external/actions/${contract}.sol \
	--verify ${contract}:certora/shellyActions.spec \
	--packages interfaces=${PWD}/interfaces @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
	--msg "Notional - ${contract} counting" --javaArgs '"-Dtopic.storage.analysis -Dtopic.alias.analysis"' #\
	#--staging shelly/specialStorageHashDetectionForNotional --cache Notional2${contract} \
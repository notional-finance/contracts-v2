certoraRun.py contracts/external/FreeCollateralExternal.sol \
 	--verify FreeCollateralExternal:certora/sanity.spec \
 	--solc solc7.6 \
	--optimistic_loop \
 	--loop_iter 1 \
	--settings -deleteSMTFile=false,-t=10 \
	--packages_path ${BROWNIE_PATH}/packages \
	--packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --msg "FreeCollateralExternal sanity bitVector " --javaArgs '"-Dverbose.decompiler -Dverbose.times"' 


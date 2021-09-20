certoraRun.py contracts/external/governance/NoteERC20.sol\
 	--verify NoteERC20:certora/erc20.spec \
 	--solc solc7.6 \
	--optimistic_loop \
 	--rule $1 \
	--cache NoteERC20 \
 	--loop_iter 2 \
	--packages_path ${BROWNIE_PATH}/packages \
	--packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.2-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
 	--solc_args "['--optimize']" --staging shelly/or/bummingPacking --msg "noteERC20: $1 - $2" \
	--settings -depth=8,-t=1600,-useNonLinearArithmetic

#     --rule $1 \
#   	--cache NoteERC20Harness \
#   contracts/mocks/certora/noteERC20Harness.sol
#   	--settings -t=1200,-depth=1,-smt_bitVectorTheory=true,-smt_hashingScheme=plainInjectivity \

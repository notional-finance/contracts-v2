certoraRun contracts/mocks/certora/DateTimeHarness.sol \
 	--verify DateTimeHarness:certora/asset/DateTime.spec \
 	--solc solc7.5 \
 	--optimistic_loop \
 	--loop_iter 3 \
 	--settings -smt_bitVectorTheory=true \
 	--packages_path $HOME'/.brownie/packages' \
 	--packages @openzeppelin=$HOME/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=$HOME/.brownie/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --staging --msg "Date time - bv" \
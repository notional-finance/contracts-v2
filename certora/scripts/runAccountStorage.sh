certoraRun contracts/mocks/certora/StorageHarness.sol \
 	--verify StorageHarness:certora/storage/AccountStorage.spec \
 	--solc solc7.6 \
	--rule_sanity \
	--settings -smt_bitVectorTheory=true \
 	--packages_path $HOME'/.brownie/packages' \
 	--packages interfaces=$HOME'/code/notional-finance/contracts-v2/interfaces' @openzeppelin=$HOME/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.2-solc-0.7 compound-finance=$HOME/.brownie/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --staging  --msg "run account storage"

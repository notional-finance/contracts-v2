certoraRun contracts/mocks/certora/MathHarness.sol \
 	--verify MathHarness:certora/math/Rates.spec \
 	--solc solc7.6 \
 	--packages_path $HOME'/.brownie/packages' \
 	--packages @openzeppelin=$HOME/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=$HOME/.brownie/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --staging \
	--rule $1
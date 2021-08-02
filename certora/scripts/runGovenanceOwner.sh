certoraRun contracts/mocks/certora/GovernanceActionHarness.sol \
 	--verify GovernanceActionHarness:certora/governance/GovernanceOwner.spec \
 	--solc /home/jwu/.solcx/solc-v0.7.5 \
	--settings -smt_bitVectorTheory=true,-smt_hashingScheme=plainInjectivity \
	--packages_path $HOME'/.brownie/packages' \
	--packages @openzeppelin=$HOME/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=$HOME/.brownie/packages/compound-finance interfaces=$HOME'/code/notional-finance/contracts-v2/interfaces' \
 	--solc_args "['--optimize', '--optimize-runs', '200']"

python $CERTORA/certoraRun.py contracts/mocks/certora/AccountPortfolioHarness.sol \
 	--verify AccountPortfolioHarness:certora/accountContext/Portfolio.spec \
 	--solc solc7.6 \
	--optimistic_loop \
 	--loop_iter 1 \
	--settings -smt_bitVectorTheory=true \
	--packages_path $HOME'/.brownie/packages' \
	--packages @openzeppelin=$HOME/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=$HOME/.brownie/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --staging --msg "Protfolio :all bv " 
	 

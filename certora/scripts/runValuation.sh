certoraRun contracts/mocks/certora/ValuationHarness.sol \
 	--verify ValuationHarness:certora/asset/Valuation.spec \
 	--solc /home/jwu/.solcx/solc-v0.7.5 \
	--optimistic_loop \
 	--loop_iter 1 \
	--settings -smt_bitVectorTheory=true,-smt_hashingScheme=plainInjectivity \
	--packages_path '/home/jwu/.brownie/packages' \
	--packages @openzeppelin=/home/jwu/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=/home/jwu/.brownie/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --staging alex/bv-solver-strategy
	 
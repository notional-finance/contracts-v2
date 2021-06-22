#!/bin/bash
source venv/bin/activate

# TODO: copy the latest file from .last_confs and stick it in a folder...

# certoraRun contracts/mocks/MockAggregator.sol \
# 	--verify MockAggregator:certora/hello.spec \
# 	--solc ~/.solcx/solc-v0.7.5

# certoraRun contracts/mocks/certora/GetterSetterHarness.sol \
# 	--verify GetterSetterHarness:certora/getterSetters.spec \
# 	--solc ~/.solcx/solc-v0.7.5 \
# 	--rule_sanity \
# 	--settings -smt_bitVectorTheory=true \
# 	--packages_path '/home/jwu/.brownie/packages' \
# 	--packages @openzeppelin=/home/jwu/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=/home/jwu/.brownie/packages/compound-finance \
# 	--solc_args "['--optimize', '--optimize-runs', '200']" \

# certoraRun contracts/mocks/certora/DateTimeHarness.sol \
# 	--verify DateTimeHarness:certora/dateTime.spec \
# 	--solc ~/.solcx/solc-v0.7.5 \
# 	--rule_sanity \
# 	--optimistic_loop \
# 	--loop_iter 7 \
# 	--settings -smt_bitVectorTheory=true \
# 	--packages_path '/home/jwu/.brownie/packages' \
# 	--packages @openzeppelin=/home/jwu/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=/home/jwu/.brownie/packages/compound-finance \
# 	--solc_args "['--optimize', '--optimize-runs', '200']" \

certoraRun contracts/mocks/certora/AccountPortfolioHarness.sol \
	--verify AccountPortfolioHarness:certora/accountContext.spec \
	--solc ~/.solcx/solc-v0.7.5 \
	--rule_sanity \
	--optimistic_loop \
	--loop_iter 9 \
	--settings -smt_bitVectorTheory=true \
	--packages_path '/home/jwu/.brownie/packages' \
	--packages @openzeppelin=/home/jwu/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=/home/jwu/.brownie/packages/compound-finance \
	--solc_args "['--optimize', '--optimize-runs', '200']" \

certoraRun contracts/mocks/certora/GovernanceActionHarness.sol \
	--verify GovernanceActionHarness:certora/OwnerGovernance.spec \
	--solc ~/.solcx/solc-v0.7.5 \
	--rule_sanity \
	--packages_path '/home/jwu/.brownie/packages' \
	--packages @openzeppelin=/home/jwu/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 \
			   compound-finance=/home/jwu/.brownie/packages/compound-finance \
			   interfaces=/home/jwu/code/notional-finance/contracts-v2/interfaces \
	--solc_args "['--optimize', '--optimize-runs', '200']"

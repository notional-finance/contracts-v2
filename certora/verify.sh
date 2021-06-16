#!/bin/bash
source venv/bin/activate

# certoraRun contracts/mocks/MockAggregator.sol \
# 	--verify MockAggregator:certora/hello.spec \
# 	--solc ~/.solcx/solc-v0.7.5

certoraRun certora/mocks/AccountPortfolioMock.sol \
	--verify AccountPortfolioMock:certora/accountContext.spec \
	--solc ~/.solcx/solc-v0.7.5 \
	--packages_path '/home/jwu/.brownie/packages' \
	--packages @openzeppelin=/home/jwu/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=/home/jwu/.brownie/packages/compound-finance \
	--solc_args "['--optimize', '--optimize-runs', '200']"

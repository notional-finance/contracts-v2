#!/bin/bash
source venv/bin/activate

PACKAGES_PATH=$HOME/.brownie/packages
SOLC=solc7.5
PACKAGES="@openzeppelin=${PACKAGES_PATH}/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7"
PACKAGES="${PACKAGES} compound-finance=${PACKAGES_PATH}/compound-finance"
PACKAGES="${PACKAGES} interfaces=${PWD}/interfaces"
SOLC_ARGS="['--optimize', '--optimize-runs', '200']"

HARNESS=$1
SPEC=$2
OPTS=${@:3}

	# --rule_sanity \
certoraRun contracts/mocks/certora/$1.sol \
	--verify $1:certora/$2.spec \
	--solc "$SOLC" \
	--packages_path "$PACKAGES_PATH" \
	--packages $PACKAGES \
	--solc_args "$SOLC_ARGS" \
 	--settings -smt_bitVectorTheory=true,-rule=impliedRatesDoNotChangeOnRemoveLiquidity,-deleteSMTFile=false \
        --staging alex/bv-solver-strategy \
	$OPTS


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

# certoraRun contracts/mocks/certora/AccountPortfolioHarness.sol \
# 	--verify AccountPortfolioHarness:certora/AccountContext2.spec \
# 	--rule_sanity \
# 	--optimistic_loop \
# 	--loop_iter 9 \
# 	--settings -smt_bitVectorTheory=true \
# 	--solc "$HOME/.solcx/solc-v0.7.5" \
# 	--packages_path "$HOME/.brownie/packages" \
# 	--packages @openzeppelin="$HOME/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7" compound-finance="$HOME/.brownie/packages/compound-finance" \
# 	--solc_args "['--optimize', '--optimize-runs', '200']" \

# certoraRun contracts/mocks/certora/LiquidityCurveHarness.sol \
# 	--verify LiquidityCurveHarness:certora/LiquidityCurve.spec \
# 	--solc ~/.solcx/solc-v0.7.5 \
# 	--rule_sanity \
# 	--settings -smt_bitVectorTheory=true \
# 	--packages_path '/home/jwu/.brownie/packages' \
# 	--packages @openzeppelin=/home/jwu/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=/home/jwu/.brownie/packages/compound-finance \
# 	--solc_args "['--optimize', '--optimize-runs', '200']" \

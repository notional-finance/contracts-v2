#!/bin/bash
source venv/bin/activate

certoraRun contracts/mocks/MockAggregator.sol \
	--verify MockAggregator:certora/hello.spec \
	--solc ~/.solcx/solc-v0.7.5
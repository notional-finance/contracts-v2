#!/bin/bash
shopt -s extglob

source venv/bin/activate
rm -Rf build/contracts build/interfaces
brownie compile

brownie test tests/adapters --disable-warnings
brownie test tests/test_authentication.py --disable-warnings
brownie test tests/internal --disable-warnings
brownie test tests/stateful/liquidation --disable-warnings
brownie test tests/stateful/vaults --disable-warnings
brownie test tests/stateful/test_!(settlement).py --disable-warnings
brownie test tests/stateful/test_settlement.py --disable-warnings
brownie test tests/mainnet-fork/test_treasury_action.py --network mainnet-fork
# export CHAIN_ID=42161; brownie test tests/arbitrum-fork/test_pcash_rebalancing.py --network arbitrum-fork
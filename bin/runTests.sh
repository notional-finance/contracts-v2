#!/bin/bash
shopt -s extglob

source venv/bin/activate
brownie test tests/adapters
brownie test tests/test_authentication.py
brownie test tests/internal 
brownie test tests/stateful/liquidation
brownie test tests/stateful/vaults
brownie test tests/stateful/test_!(settlement).py
brownie test tests/stateful/test_settlement.py
# brownie test tests/mainnet-fork --network mainnet-fork
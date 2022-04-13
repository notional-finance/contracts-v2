#!/bin/bash
source venv/bin/activate
brownie test tests/adapters tests/internal 
brownie test tests/test_authentication.py tests/test_migration.py tests/stateful 
brownie test tests/mainnet-fork --network mainnet-fork
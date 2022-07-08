#!/bin/bash
source venv/bin/activate
brownie test tests/adapters tests/internal 
brownie test tests/test_authentication.py tests/stateful 
brownie test tests/mainnet-fork --network mainnet-fork
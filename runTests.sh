#!/bin/bash

brownie test tests/adapters tests/internal 
brownie test tests/test_authentication.py tests/test_migration.py tests/stateful 
brownie test tests/mainnet-fork --network hardhat-fork
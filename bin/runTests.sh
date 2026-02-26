#!/usr/bin/env bash
set -euo pipefail

source venv/bin/activate

if [ "$#" -gt 0 ]; then
    brownie test "$@"
    exit 0
fi

brownie test tests/adapters tests/internal
brownie test tests/test_authentication.py tests/stateful
brownie test tests/mainnet-fork --network mainnet-fork

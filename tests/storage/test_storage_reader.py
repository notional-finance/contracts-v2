import secrets

import pytest
from brownie.test import given, strategy


@pytest.fixture(scope="module", autouse=True)
def storageReader(MockStorageReader, accounts):
    reader = MockStorageReader.deploy({"from": accounts[0]})
    # Ensure that we have at least 2 bytes of currencies
    reader.setMaxCurrencyId(15)
    reader.setCurrencyMapping(1, ("0x" + secrets.token_hex(20), False, 8, 18, 106))
    reader.setCurrencyMapping(7, ("0x" + secrets.token_hex(20), False, 8, 18, 106))

    return reader


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_get_balance_context(storageReader, accounts):
    storageReader.setAccountContext(accounts[1], (0, False, False, "0x82"))

    storageReader.setBalance(accounts[1], 7, (1e18, 7e18))

    # Assertions handled in mock
    (bc, ac) = storageReader._getBalanceContext(accounts[1], 7, False)

    (bc, ac) = storageReader._getBalanceContext(accounts[1], 7, True)

    (bc, ac) = storageReader._getBalanceContext(accounts[1], 1, False)

    (bc, ac) = storageReader._getBalanceContext(accounts[1], 1, True)


@given(active_currencies=strategy("bytes", min_size=1, max_size=32))
def test_get_remaining_balances(storageReader, active_currencies, accounts):
    bc = storageReader._getRemainingActiveBalances(accounts[1], active_currencies)

    # accounts for leading zeros
    num_bits = str(len(active_currencies) * 8)
    bitstring = ("{:0>" + num_bits + "b}").format(int(active_currencies.hex(), 16))

    ids = []
    for i, x in enumerate(list(bitstring)):
        if x == "1":
            ids.append(i + 1)

    assert len(bc) == len(ids)
    for i, b in enumerate(bc):
        assert b[0] == ids[i]


# def test_get_market_parameters(storageReader):

# def test_get_trade_context(storageReader):

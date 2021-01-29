import secrets

import brownie
import pytest
from brownie.test import given, strategy
from tests.common.params import *


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


def test_get_market_parameters_total_liquidity(storageReader):
    # Tests that market parameters gets total liquidity when add liquidity
    # is called
    cg = list(BASE_CASH_GROUP)
    blockTime = 700
    marketState = (1e18, 2e18, 5e7, 5e7, 0)
    maturity = 90 * SECONDS_IN_DAY
    totalLiquidity = 3e18
    storageReader.setMarketState(cg[0], maturity, marketState, totalLiquidity)

    # When not requesting liquidity total liquidity is not fetched
    result1 = storageReader._getMarketParameters(
        blockTime, [(TAKE_CURRENT_CASH, maturity, 1e18, "0x")], cg
    )

    assert len(result1) == 1
    assert result1[0] == (
        cg[0],
        90 * SECONDS_IN_DAY,
        marketState[0],
        marketState[1],
        0,
        marketState[2],
        marketState[3],
        marketState[4],
    )

    # When requesting liquidity it is fetched, regardless of order
    result2 = storageReader._getMarketParameters(
        blockTime,
        [(TAKE_CURRENT_CASH, maturity, 1e18, "0x"), (ADD_LIQUIDITY, maturity, 1e18, "0x")],
        cg,
    )
    assert len(result2) == 1
    assert result2[0] == (
        cg[0],
        90 * SECONDS_IN_DAY,
        marketState[0],
        marketState[1],
        totalLiquidity,
        marketState[2],
        marketState[3],
        marketState[4],
    )

    result3 = storageReader._getMarketParameters(
        blockTime,
        [(ADD_LIQUIDITY, maturity, 1e18, "0x"), (TAKE_CURRENT_CASH, maturity, 1e18, "0x")],
        cg,
    )
    assert result3 == result2


def test_get_market_parameters_unsorted(storageReader):
    cg = list(BASE_CASH_GROUP)
    blockTime = 700
    with brownie.reverts("R: trade requests unsorted"):
        storageReader._getMarketParameters(
            blockTime,
            [
                (TAKE_CURRENT_CASH, 180 * SECONDS_IN_DAY, 1e18, "0x"),
                (TAKE_CURRENT_CASH, 90 * SECONDS_IN_DAY, 1e18, "0x"),
            ],
            cg,
        )


def test_get_market_parameters_invalid_maturity(storageReader):
    cg = list(BASE_CASH_GROUP)
    cg[4] = 2
    blockTime = 700
    with brownie.reverts("R: invalid maturity"):
        storageReader._getMarketParameters(
            blockTime, [(TAKE_CURRENT_CASH, 360 * SECONDS_IN_DAY, 1e18, "0x")], cg
        )

    with brownie.reverts("R: invalid maturity"):
        storageReader._getMarketParameters(
            360 * SECONDS_IN_DAY, [(TAKE_CURRENT_CASH, 90 * SECONDS_IN_DAY, 1e18, "0x")], cg
        )

    # Test idiosyncratic cash
    with brownie.reverts("R: invalid maturity"):
        storageReader._getMarketParameters(
            blockTime, [(MINT_CASH_PAIR, 360 * SECONDS_IN_DAY, 1e18, "0x")], cg
        )

    with brownie.reverts("R: invalid maturity"):
        storageReader._getMarketParameters(
            360 * SECONDS_IN_DAY, [(MINT_CASH_PAIR, 90 * SECONDS_IN_DAY, 1e18, "0x")], cg
        )


def test_get_market_parameters_idiosyncratic(storageReader):
    cg = list(BASE_CASH_GROUP)
    blockTime = 0
    result = storageReader._getMarketParameters(
        blockTime,
        [
            (MINT_CASH_PAIR, 80 * SECONDS_IN_DAY, 1e18, "0x"),
            # We don't need market context even if we mint on an AMM
            (MINT_CASH_PAIR, 90 * SECONDS_IN_DAY, 1e18, "0x"),
            (TAKE_CURRENT_CASH, 180 * SECONDS_IN_DAY, 1e18, "0x"),
        ],
        cg,
    )

    assert len(result) == 1


# def test_get_trade_context(storageReader):

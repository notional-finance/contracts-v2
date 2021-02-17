import math
import random

import brownie
import pytest
from brownie.test import given, strategy
from hypothesis import settings
from tests.common.params import START_TIME


@pytest.fixture(scope="module", autouse=True)
def balanceHandler(MockBalanceHandler, MockERC20, accounts):
    handler = MockBalanceHandler.deploy({"from": accounts[0]})
    # Ensure that we have at least 2 bytes of currencies
    handler.setMaxCurrencyId(15)
    return handler


@pytest.fixture(scope="module", autouse=True)
def tokens(balanceHandler, MockERC20, accounts):
    tokens = []
    for i in range(1, 16):
        hasFee = random.randint(0, 1) == 1
        decimals = random.choice([6, 8, 18])
        fee = 0.01e18 if hasFee else 0

        token = MockERC20.deploy(str(i), str(i), decimals, fee, {"from": accounts[0]})
        balanceHandler.setCurrencyMapping(i, (token.address, hasFee, decimals, decimals))
        token.approve(balanceHandler.address, 2 ** 255)
        token.transfer(balanceHandler.address, 1e20, {"from": accounts[0]})
        tokens.append(token)

    return tokens


@given(active_currencies=strategy("bytes", min_size=1, max_size=8))
def test_get_remaining_balances(balanceHandler, active_currencies, accounts):
    # accounts for leading zeros
    num_bits = str(len(active_currencies) * 8)
    bitstring = ("{:0>" + num_bits + "b}").format(int(active_currencies.hex(), 16))

    ids = []
    for i, x in enumerate(list(bitstring)):
        if x == "1":
            ids.append(i + 1)

    # test additional balance contexts
    existingContexts = []
    for i in range(1, 15):
        if i not in ids and len(existingContexts) < 5:
            existingContexts.append((i, 0, 0, 0, 0, 0, 0, 0))

    (bc, ac) = balanceHandler.getRemainingActiveBalances(
        accounts[1], (0, 0, False, False, False, active_currencies), tuple(existingContexts)
    )

    # Assert that all the active currency bits have been set to false
    assert int(ac[5].hex(), 16) == 0
    assert len(bc) == (len(ids) + len(existingContexts))
    allIds = sorted(ids + [x[0] for x in existingContexts])
    for i, b in enumerate(bc):
        assert b[0] == allIds[i]


@given(
    currencyId=strategy("uint", min_value=1, max_value=15),
    assetBalance=strategy("int88", min_value=-10e18, max_value=10e18),
    perpetualTokenBalance=strategy("uint80", max_value=10e18),
    capitalDeposited=strategy("int88", min_value=-10e18, max_value=10e18),
    netCashChange=strategy("int88", min_value=-10e18, max_value=10e18),
    netTransfer=strategy("int88", min_value=-10e18, max_value=10e18),
    netCapitalDeposit=strategy("int88", min_value=-10e18, max_value=10e18),
    netPerpetualTokenTransfer=strategy("int88", min_value=-10e18, max_value=10e18),
)
# TODO: this test is very slow
@settings(max_examples=10)
def test_build_and_finalize_balances(
    balanceHandler,
    accounts,
    currencyId,
    assetBalance,
    perpetualTokenBalance,
    capitalDeposited,
    netCashChange,
    netTransfer,
    netPerpetualTokenTransfer,
    netCapitalDeposit,
    tokens,
):
    bitstring = list("".zfill(16))
    bitstring[currencyId - 1] = "1"
    active_currencies = int("".join(bitstring), 2).to_bytes(len(bitstring) // 8, byteorder="big")

    # Set global capital deposit to some initial value
    balanceHandler.finalize(
        (currencyId, 0, 0, 0, 0, 0, 0, 100e18),
        accounts[1],
        (0, START_TIME, False, False, False, active_currencies),
    )
    # Globel incentive counter is set
    assert 100e18 == balanceHandler.getCurrencyIncentiveData(currencyId)[0]

    balanceHandler.setBalance(
        accounts[0], currencyId, (assetBalance, perpetualTokenBalance, capitalDeposited)
    )
    context = (0, 0, False, False, False, active_currencies)

    (bs, context) = balanceHandler.buildBalanceState(accounts[0], currencyId, context)
    assert bs[0] == currencyId
    assert bs[1] == assetBalance
    assert bs[2] == perpetualTokenBalance
    assert bs[3] == capitalDeposited
    assert bs[4] == 0
    assert int.from_bytes(context[5], "big") == 0

    bsCopy = list(bs)
    bsCopy[4] = netCashChange
    bsCopy[5] = netTransfer
    bsCopy[6] = netPerpetualTokenTransfer
    bsCopy[7] = netCapitalDeposit

    # These scenarios should fail
    if netTransfer < 0 and assetBalance + netCashChange + netTransfer < 0:
        # Cannot withdraw to a negative balance
        with brownie.reverts("CH: cannot withdraw negative"):
            context = balanceHandler.finalize(bsCopy, accounts[0], context)
    elif perpetualTokenBalance + netPerpetualTokenTransfer < 0:
        with brownie.reverts("CH: cannot withdraw negative"):
            context = balanceHandler.finalize(bsCopy, accounts[0], context)
    else:
        # check that the balances match on the token balances and on the
        # the storage
        txn = balanceHandler.finalize(bsCopy, accounts[0], context)
        context = txn.return_value

        # Assert hasDebt is set properly (storedCashBalance + netCashChange + netTransfer)
        if bsCopy[1] + bsCopy[4] + netTransfer < 0:
            assert context[2]
        else:
            assert not context[2]

        (bsFinal, _) = balanceHandler.buildBalanceState(accounts[0], currencyId, context)
        assert bsFinal[0] == currencyId
        currency = balanceHandler.currencyMapping(currencyId)
        precisionDiff = 10 ** (currency[2] - 9)

        # Has transfer fee
        if currency[1]:
            transferConversion = math.trunc(netTransfer * precisionDiff)
            fee = math.trunc(transferConversion * 0.01e18 / 1e18)
            finalTransferInternal = int(math.trunc(transferConversion - fee) / precisionDiff)
            assert (
                pytest.approx(bsFinal[1], abs=10) == bsCopy[1] + bsCopy[4] + finalTransferInternal
            )
        else:
            transferConversion = math.trunc(math.trunc(netTransfer * precisionDiff) / precisionDiff)
            assert bsFinal[1] == bsCopy[1] + bsCopy[4] + transferConversion

        assert bsFinal[2] == bsCopy[2] + netPerpetualTokenTransfer
        assert bsFinal[3] == bsCopy[3] + netCapitalDeposit

        # Global capital deposit should change by the increment
        assert (int(100e18) + netCapitalDeposit) == balanceHandler.getCurrencyIncentiveData(
            currencyId
        )[0]

        # TODO: need to also test minting

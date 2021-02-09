import math
import random

import brownie
import pytest
from brownie.test import given, strategy


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
        balanceHandler.setCurrencyMapping(i, (token.address, hasFee, decimals, 106, decimals))
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
            existingContexts.append((i, 0, 0, 0))

    (bc, ac) = balanceHandler.getRemainingActiveBalances(
        accounts[1], (0, False, False, active_currencies), tuple(existingContexts)
    )

    # Assert that all the active currency bits have been set to false
    assert int(ac[3].hex(), 16) == 0
    assert len(bc) == (len(ids) + len(existingContexts))
    allIds = sorted(ids + [x[0] for x in existingContexts])
    for i, b in enumerate(bc):
        assert b[0] == allIds[i]


@given(
    currencyId=strategy("uint", min_value=1, max_value=15),
    assetBalance=strategy("int128", min_value=-10e18, max_value=10e18),
    perpetualTokenBalance=strategy("uint128", max_value=10e18),
    netCashChange=strategy("int128", min_value=-10e18, max_value=10e18),
    netTransfer=strategy("int128", min_value=-10e18, max_value=10e18),
    netPerpetualTokenTransfer=strategy("int128", min_value=-10e18, max_value=10e18),
)
def test_build_and_finalize_balances(
    balanceHandler,
    accounts,
    currencyId,
    assetBalance,
    perpetualTokenBalance,
    netCashChange,
    netTransfer,
    netPerpetualTokenTransfer,
    tokens,
):

    balanceHandler.setBalance(accounts[0], currencyId, (assetBalance, perpetualTokenBalance))
    bitstring = list("".zfill(16))
    bitstring[currencyId - 1] = "1"

    active_currencies = int("".join(bitstring), 2).to_bytes(len(bitstring) // 8, byteorder="big")
    context = (0, False, False, active_currencies)

    (bs, context) = balanceHandler.buildBalanceState(accounts[0], currencyId, context)
    assert bs[0] == currencyId
    assert bs[1] == assetBalance
    assert bs[2] == perpetualTokenBalance
    assert bs[3] == 0
    assert int.from_bytes(context[3], "big") == 0

    bsCopy = list(bs)
    bsCopy[3] = netCashChange

    # These scenarios should fail
    if netTransfer < 0 and assetBalance + netCashChange + netTransfer < 0:
        # Cannot withdraw to a negative balance
        with brownie.reverts("CH: cannot withdraw negative"):
            context = balanceHandler.finalize(
                bsCopy, accounts[0], context, netTransfer, netPerpetualTokenTransfer
            )
    elif perpetualTokenBalance + netPerpetualTokenTransfer < 0:
        with brownie.reverts("CH: cannot withdraw negative"):
            context = balanceHandler.finalize(
                bsCopy, accounts[0], context, netTransfer, netPerpetualTokenTransfer
            )
    else:
        # check that the balances match on the token balances and on the
        # the storage
        txn = balanceHandler.finalize(
            bsCopy, accounts[0], context, netTransfer, netPerpetualTokenTransfer
        )
        context = txn.return_value

        # Assert hasDebt is set properly
        if bsCopy[1] + bsCopy[3] + netTransfer < 0:
            assert context[1]
        else:
            assert not context[1]

        (bsFinal, _) = balanceHandler.buildBalanceState(accounts[0], currencyId, context)
        assert bsFinal[0] == currencyId
        currency = balanceHandler.currencyMapping(currencyId)
        precisionDiff = 10 ** (currency[2] - 9)

        # Has transfer fee
        if currency[1]:
            transferConversion = math.trunc(netTransfer * precisionDiff)
            fee = math.trunc(transferConversion * 0.01e18 / 1e18)
            finalTransferInternal = math.trunc(transferConversion - fee) / precisionDiff
            assert (
                pytest.approx(bsFinal[1], rel=precisionDiff)
                == bsCopy[1] + bsCopy[3] + finalTransferInternal
            )
        else:
            transferConversion = math.trunc(math.trunc(netTransfer * precisionDiff) / precisionDiff)
            assert (
                pytest.approx(bsFinal[1], rel=precisionDiff)
                == bsCopy[1] + bsCopy[3] + transferConversion
            )

        assert bsFinal[2] == bsCopy[2] + netPerpetualTokenTransfer

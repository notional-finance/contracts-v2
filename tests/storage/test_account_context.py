import random

import brownie
import pytest
from brownie.convert import to_bytes, to_uint
from brownie.test import given, strategy
from tests.constants import START_TIME


@pytest.fixture(scope="module", autouse=True)
def accountContext(MockAccountContextHandler, accounts):
    context = MockAccountContextHandler.deploy({"from": accounts[0]})
    return context


def get_active_currencies(currenciesList):
    if len(currenciesList) == 0:
        return to_bytes(0, "bytes18")

    if len(currenciesList) > 9:
        raise Exception("Currency list too long")

    result = bytearray()
    for c in currenciesList:
        if c < 0 or c > 2 ** 16:
            raise Exception("Invalid currency id")
        b = to_bytes(c, "bytes2")
        result.extend(b)

    if len(result) < 18:
        # Pad this out to 18 bytes
        result.extend(to_bytes(0, "bytes1") * (18 - len(result)))

    return bytes(result)


def bytes_to_list(activeCurrencies):
    ba = bytearray(activeCurrencies)
    return [to_uint(bytes(ba[i : i + 2])) for i in range(0, 18, 2)]


@given(
    length=strategy("uint", min_value=0, max_value=9),
    hasDebt=strategy("bool"),
    arrayLength=strategy("uint8"),
    bitmapId=strategy("uint16"),
)
def test_get_and_set_account_context(
    accountContext, accounts, length, hasDebt, arrayLength, bitmapId
):
    currencies = [random.randint(1, 2 ** 16) for i in range(0, length)]
    currenciesHex = brownie.convert.datatypes.HexString(
        get_active_currencies(currencies), "bytes18"
    )
    expectedContext = (START_TIME, hasDebt, arrayLength, bitmapId, currenciesHex)

    accountContext.setAccountContext(expectedContext, accounts[0])
    assert expectedContext == accountContext.getAccountContext(accounts[0])


@given(length=strategy("uint", min_value=0, max_value=9))
def test_is_active_currency(accountContext, length):
    currencies = [random.randint(1, 2 ** 16) for i in range(0, length)]
    ac = (0, False, 0, 0, get_active_currencies(currencies))

    for c in currencies:
        assert accountContext.isActiveCurrency(ac, c)

    for i in range(0, 10):
        c = random.randint(1, 2 ** 16)
        if c in currencies:
            assert accountContext.isActiveCurrency(ac, c)
        else:
            assert not accountContext.isActiveCurrency(ac, c)


def test_set_active_currency(accountContext):
    # is active and in list
    currenciesList = [0] * 9
    currenciesList[0] = 2
    currenciesList[1] = 4
    currenciesList[2] = 512
    currenciesList[3] = 1024
    # Assertions are handled inside the method
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 2, True)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 4, True)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 512, True)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 1024, True)

    # is active and must insert
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 1, True)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 3, True)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 513, True)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 550, True)
    # is active and append to end
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 1025, True)

    # is not active and in list middle
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 2, False)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 4, False)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 512, False)
    # is not active and in list at end
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 1024, False)

    # is not active and not in list
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 1, False)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 3, False)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 550, False)
    accountContext.setActiveCurrency(get_active_currencies(currenciesList), 2000, False)

    currenciesList = list(range(2, 19, 2))
    # is active and append to end, too long
    with brownie.reverts("AC: too many currencies"):
        accountContext.setActiveCurrency(get_active_currencies(currenciesList), 25, True)
        accountContext.setActiveCurrency(get_active_currencies(currenciesList), 1024, True)
    # is active and must insert, too long
    with brownie.reverts("AC: too many currencies"):
        accountContext.setActiveCurrency(get_active_currencies(currenciesList), 1, True)
        accountContext.setActiveCurrency(get_active_currencies(currenciesList), 3, True)


@given(length=strategy("uint", min_value=0, max_value=9))
def test_get_all_balances(accountContext, accounts, length):
    currenciesList = list(range(2, length * 2, 2))
    # no bitmap currency id
    bs = accountContext.getAllBalances(get_active_currencies(currenciesList), accounts[0], 0)
    assert list(map(lambda x: x[0], bs)) == currenciesList

    # with bitmap currency id inside list
    bs = accountContext.getAllBalances(get_active_currencies(currenciesList), accounts[0], 3)
    assert list(map(lambda x: x[0], bs)) == sorted(currenciesList + [3])

    # with bitmap currency id end of list
    bs = accountContext.getAllBalances(get_active_currencies(currenciesList), accounts[0], 25)
    assert list(map(lambda x: x[0], bs)) == sorted(currenciesList + [25])

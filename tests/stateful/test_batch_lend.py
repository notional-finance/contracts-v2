import brownie
import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from scripts.config import CurrencyDefaults
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import (
    _enable_cash_group,
    active_currencies_to_list,
    get_balance_trade_action,
    get_lend_action,
    get_tref,
    initialize_environment,
)
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants
from tests.stateful.test_settlement import settle_all_other_accounts

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_fail_on_unsorted_actions(environment, accounts):
    action1 = get_lend_action(
        1,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        True,
    )
    action2 = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        True,
    )

    with brownie.reverts("Unsorted actions"):
        environment.notional.batchLend(accounts[1], [action2, action1], {"from": accounts[1]})


def test_fail_on_zero_actions(environment, accounts):
    action = get_lend_action(1, [], True)
    with brownie.reverts():
        environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})


def test_fail_on_non_lend_actions(environment, accounts):
    action = get_lend_action(
        1,
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        True,
    )
    with brownie.reverts():
        environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})


def test_fail_on_slippage(environment, accounts):
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 1e9}],
        True,
    )
    with brownie.reverts("Trade failed, slippage"):
        environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})


@given(useUnderlying=strategy("bool"), useBitmap=strategy("bool"))
def test_lend_insufficient_cash(environment, useUnderlying, useBitmap, accounts):
    if useBitmap:
        environment.notional.enableBitmapCurrency(2, {"from": accounts[3]})

    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 1e9}],
        useUnderlying,
    )

    with brownie.reverts():
        environment.notional.batchLend(accounts[3], [action], {"from": accounts[3]})


@given(useUnderlying=strategy("bool"), useBitmap=strategy("bool"))
def test_lend_sufficient_cash_no_transfer(environment, useUnderlying, useBitmap, accounts):
    if useBitmap:
        environment.notional.enableBitmapCurrency(2, {"from": accounts[1]})

    environment.notional.depositUnderlyingToken(accounts[1], 2, 97.9e18, {"from": accounts[1]})
    marketsBefore = environment.notional.getActiveMarkets(2)
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        useUnderlying,
    )

    balanceBefore = environment.token["DAI"].balanceOf(accounts[1])
    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values())[0] == 100e8,
        feesPaidToReserve=lambda x: x[2] > 0,
        netCash=lambda x: x[2] < 0
    ) as c:
        txn = environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})
        c['txn'] = txn
    balanceAfter = environment.token["DAI"].balanceOf(accounts[1])

    assert balanceAfter == balanceBefore

    context = environment.notional.getAccountContext(accounts[1]).dict()
    if useBitmap:
        assert context["bitmapCurrencyId"] == 2
    else:
        activeCurrenciesList = active_currencies_to_list(context["activeCurrencies"])
        assert activeCurrenciesList == [(2, True, True)]

    assert context["hasDebt"] == "0x00"
    (cashBalance, _, _) = environment.notional.getAccountBalance(2, accounts[1])
    # Some residual cash left in Notional
    assert cashBalance <= 50e8

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8
    check_system_invariants(environment, accounts)

@given(useUnderlying=strategy("bool"), useBitmap=strategy("bool"))
def test_lend_sufficient_cash_transfer(environment, useUnderlying, useBitmap, accounts):
    if useBitmap:
        environment.notional.enableBitmapCurrency(2, {"from": accounts[1]})

    # Setup a borrow to move the exchange rate, this causes off by one errors
    environment.comptroller.enterMarkets(
        [environment.cToken["DAI"].address, environment.cToken["ETH"].address],
        {"from": accounts[1]},
    )

    environment.cToken["ETH"].mint({"from": accounts[1], "value": 10e18})
    environment.cToken["DAI"].borrow(100e18, {"from": accounts[1]})

    marketsBefore = environment.notional.getActiveMarkets(2)
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        useUnderlying,
    )

    if useUnderlying:
        token = environment.token["DAI"]
    else:
        token = environment.cToken["DAI"]

    balanceBefore = token.balanceOf(accounts[1])
    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values())[0] == 100e8,
        feesPaidToReserve=lambda x: x[2] > 0,
        netCash=lambda x: x[2] == 0
    ) as c:
        txn = environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})
        c['txn'] = txn
    balanceAfter = token.balanceOf(accounts[1])

    if useUnderlying:
        assert 95e8 < balanceBefore - balanceAfter
    else:
        assert 4500e8 < balanceBefore - balanceAfter

    context = environment.notional.getAccountContext(accounts[1])
    assert context[1] == "0x00"

    (cashBalance, nToken, incentiveDebt) = environment.notional.getAccountBalance(2, accounts[1])
    assert cashBalance < 100

    assert nToken == 0
    assert incentiveDebt == 0
    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8
    check_system_invariants(environment, accounts)

@given(useUnderlying=strategy("bool"), useBitmap=strategy("bool"))
def test_lend_insufficient_free_collateral(environment, useUnderlying, useBitmap, accounts):
    if useBitmap:
        environment.notional.enableBitmapCurrency(2, {"from": accounts[1]})

    borrowAction = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        depositActionAmount=3e18,
    )
    # Borrow and leave cash in system
    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction], {"from": accounts[1]}
    )

    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        useUnderlying,  # This is somewhat irrelevant
    )

    # Will attempt to use all the cash and fail
    with brownie.reverts("Insufficient free collateral"):
        environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})

    check_system_invariants(environment, accounts)


@given(useUnderlying=strategy("bool"))
def test_multi_currency_lend_actions_fails_on_bitmap(environment, useUnderlying, accounts):
    environment.notional.enableBitmapCurrency(2, {"from": accounts[1]})
    action1 = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        useUnderlying,
    )

    action2 = get_lend_action(
        3,
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        useUnderlying,
    )

    # If using bitmap this should revert
    with brownie.reverts():
        environment.notional.batchLend(accounts[1], [action1, action2], {"from": accounts[1]})


@given(useUnderlying=strategy("bool"))
def test_multi_currency_lend_actions(environment, useUnderlying, accounts):
    action1 = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        useUnderlying,
    )

    action2 = get_lend_action(
        3,
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        useUnderlying,
    )

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [100e8, 100e8],
        feesPaidToReserve=lambda x: x[2] > 0 and x[3] > 0,
        netCash=lambda x: x[2] == 0 and x[3] < 5000
    ) as c:
        txn = environment.notional.batchLend(accounts[1], [action1, action2], {"from": accounts[1]})
        c['txn'] = txn
    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 2
    assert portfolio[0][0] == 2
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    assert portfolio[1][0] == 3
    assert portfolio[1][2] == 1
    assert portfolio[1][3] == 100e8

    (daiCash, _, _) = environment.notional.getAccountBalance(2, accounts[1])
    (usdcCash, _, _) = environment.notional.getAccountBalance(3, accounts[1])
    assert daiCash < 5000
    assert usdcCash < 5000

    check_system_invariants(environment, accounts)


@given(
    useUnderlying=strategy("bool"),
    currencyId=strategy("uint", min_value=2, max_value=3),
    useBitmap=strategy("bool"),
)
def test_multiple_lend_trades(environment, currencyId, useUnderlying, useBitmap, accounts):
    if useBitmap:
        environment.notional.enableBitmapCurrency(currencyId, {"from": accounts[1]})

    action = get_lend_action(
        currencyId,
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        useUnderlying,
    )

    markets = environment.notional.getActiveMarkets(currencyId)
    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [100e8, 100e8],
    ) as c:
        txn = environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})
        c['txn'] = txn

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 2
    assert portfolio[0][0] == currencyId
    assert portfolio[0][1] == markets[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    assert portfolio[1][0] == currencyId
    assert portfolio[1][1] == markets[1][1]
    assert portfolio[1][2] == 1
    assert portfolio[1][3] == 100e8

    (cash, _, _) = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert cash < 5000

    check_system_invariants(environment, accounts)

@given(useBitmap=strategy("bool"))
def test_settle_and_lend_using_cash(environment, accounts, useBitmap):
    if useBitmap:
        environment.notional.enableBitmapCurrency(2, {"from": accounts[1]})

    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        True,
    )
    environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})

    # Set the blockchain forward one quarter to settle
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)
    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)
    environment.notional.initializeMarkets(3, False)

    settle_all_other_accounts(environment, accounts, accounts[1])

    balanceBefore = environment.token["DAI"].balanceOf(accounts[1])
    with EventChecker(environment, "Account Action", account=accounts[1], isSettlement=True) as c:
        txn = environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})
        c['txn'] = txn
    balanceAfter = environment.token["DAI"].balanceOf(accounts[1])

    # The net transfer should be small, only to account for the time to maturity increasing
    assert balanceBefore - balanceAfter < 5e18

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 1
    assert portfolio[0][0] == 2
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8
    check_system_invariants(environment, accounts)


def test_token_with_transfer_fee_reverts(environment, accounts):
    environment.token["USDT"].approve(environment.notional.address, 2 ** 255, {"from": accounts[0]})
    environment.token["USDT"].approve(
        environment.cToken["USDT"].address, 2 ** 255, {"from": accounts[0]}
    )
    environment.cToken["USDT"].approve(
        environment.notional.address, 2 ** 255, {"from": accounts[0]}
    )
    environment.cToken["USDT"].mint(10_000_000e8, {"from": accounts[0]})
    environment.enableCurrency("USDT", CurrencyDefaults)
    _enable_cash_group(5, environment, accounts, initialCash=1_000_000e18)

    action = get_lend_action(
        5,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        True,
    )
    with brownie.reverts("Insufficient deposit"):
        environment.notional.batchLend(accounts[0], [action], {"from": accounts[0]})

import brownie
import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import (
    active_currencies_to_list,
    get_balance_trade_action,
    get_lend_action,
    get_tref,
    initialize_environment,
)
from tests.stateful.invariants import check_system_invariants

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
        False,
    )
    action2 = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        False,
    )

    with brownie.reverts("Unsorted actions"):
        environment.notional.batchLend(accounts[1], [action2, action1], {"from": accounts[1]})


def test_fail_on_zero_actions(environment, accounts):
    action = get_lend_action(1, [], False)
    with brownie.reverts("dev: no actions"):
        environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})


def test_fail_on_non_lend_actions(environment, accounts):
    action = get_lend_action(
        1,
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        False,
    )
    with brownie.reverts("dev: only lend trades"):
        environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})


def test_fail_on_slippage(environment, accounts):
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 1e9}],
        False,
    )
    with brownie.reverts("Trade failed, slippage"):
        environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})


@given(useUnderlying=strategy("bool"))
def test_lend_insufficient_cash(environment, useUnderlying, accounts):
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 1e9}],
        useUnderlying,
    )

    with brownie.reverts():
        environment.notional.batchLend(accounts[3], [action], {"from": accounts[3]})


@given(useUnderlying=strategy("bool"))
def test_lend_sufficient_cash_no_transfer(environment, useUnderlying, accounts):
    environment.notional.depositUnderlyingToken(accounts[1], 2, 100e18, {"from": accounts[1]})
    marketsBefore = environment.notional.getActiveMarkets(2)
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        useUnderlying,
    )

    balanceBefore = environment.token["DAI"].balanceOf(accounts[1])
    txn = environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})
    balanceAfter = environment.token["DAI"].balanceOf(accounts[1])

    assert balanceAfter == balanceBefore
    assert txn.events["LendBorrowTrade"][0]["account"] == accounts[1]
    assert txn.events["LendBorrowTrade"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, True)]
    assert context[1] == "0x00"
    (cashBalance, _, _) = environment.notional.getAccountBalance(2, accounts[1])
    # Some residual cash left in Notional
    assert cashBalance <= 50e8

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8
    check_system_invariants(environment, accounts)


@given(useUnderlying=strategy("bool"))
def test_lend_sufficient_cash_transfer(environment, useUnderlying, accounts):
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
    txn = environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})
    balanceAfter = token.balanceOf(accounts[1])

    if useUnderlying:
        assert 95e8 < balanceBefore - balanceAfter
    else:
        assert 4500e8 < balanceBefore - balanceAfter
    assert txn.events["LendBorrowTrade"][0]["account"] == accounts[1]
    assert txn.events["LendBorrowTrade"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False)]
    assert context[1] == "0x00"
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8
    check_system_invariants(environment, accounts)


@given(useUnderlying=strategy("bool"))
def test_lend_underlying_insufficient_free_collateral(environment, useUnderlying, accounts):
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


def test_multiple_lend_actions(environment, accounts):
    action1 = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        True,
    )

    action2 = get_lend_action(
        3,
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        True,
    )

    environment.notional.batchLend(accounts[1], [action1, action2], {"from": accounts[1]})
    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 2
    assert portfolio[0][0] == 2
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    assert portfolio[1][0] == 3
    assert portfolio[1][2] == 1
    assert portfolio[1][3] == 100e8

    check_system_invariants(environment, accounts)


def test_settle_and_lend_using_cash(environment, accounts):
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

    environment.notional.initializeMarkets(2, False)

    balanceBefore = environment.token["DAI"].balanceOf(accounts[1])
    environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})
    balanceAfter = environment.token["DAI"].balanceOf(accounts[1])

    # The net transfer should be small, only to account for the time to maturity increasing
    assert balanceBefore - balanceAfter < 5e18

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 1
    assert portfolio[0][0] == 2
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8
    check_system_invariants(environment, accounts)


def test_lend_usdc_off_by_one(environment, accounts):
    action = get_lend_action(
        3,
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        True,
    )

    environment.notional.batchLend(accounts[1], [action], {"from": accounts[1]})
    (cashBalance, _, _) = environment.notional.getAccountBalance(3, accounts[1])
    # we will end up with some residual cToken here, make sure that it's not too much
    assert cashBalance > 0 and cashBalance < 50e6

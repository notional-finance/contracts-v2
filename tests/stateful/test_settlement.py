import pytest
from brownie.network.state import Chain
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import (
    get_balance_action,
    get_balance_trade_action,
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


def setup_multiple_asset_settlement(environment, account):
    daiAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 150e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    usdcAction = get_balance_trade_action(
        3,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=10000e6,
    )

    environment.notional.batchBalanceAndTradeAction(
        account, [daiAction, usdcAction], {"from": account}
    )


def test_settle_on_batch_action(environment, accounts):
    account = accounts[1]
    setup_multiple_asset_settlement(environment, account)

    # Set the blockchain forward one quarter to settle
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)
    environment.notional.initializeMarkets(3, False)

    ethAction = get_balance_action(1, "DepositUnderlying", depositActionAmount=1e18)

    txn = environment.notional.batchBalanceAction(
        account, [ethAction], {"from": account, "value": 1e18}
    )
    assert txn.events["AccountSettled"]

    check_system_invariants(environment, accounts)


def test_settle_on_batch_trade_action(environment, accounts):
    account = accounts[1]
    setup_multiple_asset_settlement(environment, account)

    # Set the blockchain forward one quarter to settle
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)
    environment.notional.initializeMarkets(3, False)

    ethAction = get_balance_trade_action(
        1,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 10, "maxSlippage": 0}],
    )

    txn = environment.notional.batchBalanceAndTradeAction(account, [ethAction], {"from": account})
    assert txn.events["AccountSettled"]

    check_system_invariants(environment, accounts)


def test_settle_on_withdraw(environment, accounts):
    account = accounts[1]
    setup_multiple_asset_settlement(environment, account)
    environment.notional.depositUnderlyingToken(account, 1, 1e18, {"from": account, "value": 1e18})

    # Set the blockchain forward one quarter to settle
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)
    environment.notional.initializeMarkets(3, False)

    txn = environment.notional.withdraw(1, 50e8, False, {"from": account})
    assert txn.events["AccountSettled"]

    check_system_invariants(environment, accounts)

import pytest
from brownie.network.state import Chain
from tests.constants import HAS_ASSET_DEBT, HAS_CASH_DEBT, SECONDS_IN_QUARTER
from tests.helpers import get_balance_trade_action, get_tref, initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_settle_bitmap_to_cash(environment, accounts):
    currencyId = 2
    environment.notional.enableBitmapCurrency(currencyId, {"from": accounts[1]})

    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        currencyId,
        "None",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 1,
                "notional": fCashAmount,
                "maxSlippage": 0,
            }
        ],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=50000e8)

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral], {"from": accounts[1]}
    )
    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    context = environment.notional.getAccountContext(accounts[1])
    balance = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert len(portfolio) == 0
    assert context[1] == HAS_CASH_DEBT
    assert context[0] == get_tref(txn.timestamp)
    assert balance[0] == -5000e8

    check_system_invariants(environment, accounts)


def test_settle_bitmap_shift_assets(environment, accounts):
    currencyId = 2
    environment.notional.enableBitmapCurrency(currencyId, {"from": accounts[1]})

    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        currencyId,
        "None",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 2,
                "notional": fCashAmount,
                "maxSlippage": 0,
            }
        ],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=50000e8)

    markets = environment.notional.getActiveMarkets(2)
    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral], {"from": accounts[1]}
    )
    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    context = environment.notional.getAccountContext(accounts[1])
    assert len(portfolio) == 1
    assert portfolio[0][3] == -fCashAmount
    assert portfolio[0][1] == markets[1][1]
    assert context[1] == HAS_ASSET_DEBT
    assert context[0] == get_tref(txn.timestamp)

    check_system_invariants(environment, accounts)


def test_settle_array_to_cash(environment, accounts):
    currencyId = 2

    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        currencyId,
        "None",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 1,
                "notional": fCashAmount,
                "maxSlippage": 0,
            }
        ],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=50000e8)

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral], {"from": accounts[1]}
    )
    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    context = environment.notional.getAccountContext(accounts[1])
    balance = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert len(portfolio) == 0
    assert context[1] == HAS_CASH_DEBT
    assert balance[0] == -5000e8
    assert context[0] == 0

    check_system_invariants(environment, accounts)

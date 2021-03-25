import brownie
import pytest
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment
from tests.constants import HAS_ASSET_DEBT, RATE_PRECISION, SECONDS_IN_QUARTER
from tests.helpers import active_currencies_to_list, get_balance_trade_action, get_tref
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    env = TestEnvironment(accounts[0])
    env.enableCurrency("DAI", CurrencyDefaults)
    env.enableCurrency("USDC", CurrencyDefaults)

    cToken = env.cToken["DAI"]
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["DAI"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(10000000e18, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    env.token["DAI"].transfer(accounts[1], 1000e18, {"from": accounts[0]})
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    cToken.transfer(accounts[1], 1000e8, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})

    cToken = env.cToken["USDC"]
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["USDC"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(10000000e6, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    env.token["USDC"].transfer(accounts[1], 1000e6, {"from": accounts[0]})
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    cToken.transfer(accounts[1], 1000e8, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})

    # Set the blocktime to the begnning of the next tRef otherwise the rates will blow up
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    currencyId = 2
    env.notional.updatePerpetualDepositParameters(currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9])
    env.notional.updateInitializationParameters(currencyId, [1.01e9, 1.021e9], [0.5e9, 0.5e9])
    env.notional.perpetualTokenMint(currencyId, 100000e8, False, {"from": accounts[0]})
    env.notional.initializeMarkets(currencyId, True)

    currencyId = 3
    env.notional.updatePerpetualDepositParameters(currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9])
    env.notional.updateInitializationParameters(currencyId, [1.01e9, 1.021e9], [0.5e9, 0.5e9])
    env.notional.perpetualTokenMint(currencyId, 100000e8, False, {"from": accounts[0]})
    env.notional.initializeMarkets(currencyId, True)

    return env


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_add_liquidity_failures(environment, accounts):
    with brownie.reverts():
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "AddLiquidity",
                    "marketIndex": 1,
                    "notional": 100e8,
                    "minSlippage": 0,
                    "maxSlippage": 0.40 * RATE_PRECISION,
                }
            ],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts():
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "AddLiquidity",
                    "marketIndex": 3,  # invalid market
                    "notional": 100e8,
                    "minSlippage": 0,
                    "maxSlippage": 0.40 * RATE_PRECISION,
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts():
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "AddLiquidity",
                    "marketIndex": 1,
                    "notional": 500e8,  # insufficient cash
                    "minSlippage": 0,
                    "maxSlippage": 0.40 * RATE_PRECISION,
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts():
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "AddLiquidity",
                    "marketIndex": 1,
                    "notional": 100e8,
                    "minSlippage": 0.35 * RATE_PRECISION,  # min bound
                    "maxSlippage": 0.40 * RATE_PRECISION,
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts():
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "AddLiquidity",
                    "marketIndex": 1,
                    "notional": 100e8,
                    "minSlippage": 0,
                    "maxSlippage": 0.001 * RATE_PRECISION,  # max bound
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )


def test_remove_liquidity_failures(environment, accounts):
    with brownie.reverts():
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "RemoveLiquidity",
                    "marketIndex": 1,
                    "notional": 100e8,  # No liquidity
                    "minSlippage": 0,
                    "maxSlippage": 0.40 * RATE_PRECISION,
                }
            ],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    # Add liquidity to test rate bounds
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            }
        ],
        depositActionAmount=100e8,
    )

    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    with brownie.reverts():
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "RemoveLiquidity",
                    "marketIndex": 1,
                    "notional": 100e8,
                    "minSlippage": 0,
                    "maxSlippage": 0.001 * RATE_PRECISION,  # max bound
                }
            ],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts():
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "RemoveLiquidity",
                    "marketIndex": 1,
                    "notional": 100e8,
                    "minSlippage": 0.39 * RATE_PRECISION,  # min bound
                    "maxSlippage": 0.40 * RATE_PRECISION,
                }
            ],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )


def test_deposit_asset_add_liquidity(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            }
        ],
        depositActionAmount=100e8,
    )
    marketsBefore = environment.notional.getActiveMarkets(2)

    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [action], {"from": accounts[1]}
    )

    assert txn.events["BatchTradeExecution"][0]["account"] == accounts[1]
    assert txn.events["BatchTradeExecution"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False)]
    assert context[0] == get_tref(chain.time()) + SECONDS_IN_QUARTER
    assert context[1] == HAS_ASSET_DEBT
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    marketsAfter = environment.notional.getActiveMarkets(2)

    assert marketsBefore[1] == marketsAfter[1]
    assert marketsAfter[0][2] - marketsBefore[0][2] == -portfolio[0][3]
    assert marketsAfter[0][3] - marketsBefore[0][3] == 100e8
    assert marketsAfter[0][4] - marketsBefore[0][4] == portfolio[1][3]

    check_system_invariants(environment, accounts)


def test_remove_liquidity(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            }
        ],
        depositActionAmount=100e8,
    )
    marketsBefore = environment.notional.getActiveMarkets(2)

    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    action = get_balance_trade_action(
        2,
        "None",
        [
            {
                "tradeActionType": "RemoveLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            }
        ],
        withdrawEntireCashBalance=True,
    )
    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [action], {"from": accounts[1]}
    )

    assert txn.events["BatchTradeExecution"][0]["account"] == accounts[1]
    assert txn.events["BatchTradeExecution"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []
    assert context[0] == 0
    assert context[1] == "0x00"
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])

    marketsAfter = environment.notional.getActiveMarkets(2)
    assert marketsBefore[0] == marketsAfter[0]
    assert marketsBefore[1] == marketsAfter[1]
    assert portfolio == []

    check_system_invariants(environment, accounts)


def test_roll_liquidity_to_maturity(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            }
        ],
        depositActionAmount=100e8,
    )
    marketsBefore = environment.notional.getActiveMarkets(2)

    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    action = get_balance_trade_action(
        2,
        "None",
        [
            {
                "tradeActionType": "RemoveLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 2,
                "notional": 0,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
        ],
    )

    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [action], {"from": accounts[1]}
    )

    marketsAfter = environment.notional.getActiveMarkets(2)
    assert txn.events["BatchTradeExecution"][0]["account"] == accounts[1]
    assert txn.events["BatchTradeExecution"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False)]
    assert context[0] == get_tref(chain.time()) + SECONDS_IN_QUARTER
    assert context[1] == HAS_ASSET_DEBT
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])

    assert marketsBefore[0] == marketsAfter[0]
    assert marketsAfter[1][2] - marketsBefore[1][2] == -portfolio[0][3]
    assert marketsAfter[1][3] - marketsBefore[1][3] == 100e8
    assert marketsAfter[1][4] - marketsBefore[1][4] == portfolio[1][3]

    check_system_invariants(environment, accounts)

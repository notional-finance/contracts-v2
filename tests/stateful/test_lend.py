import brownie
import pytest
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment
from tests.constants import RATE_PRECISION, SECONDS_IN_QUARTER
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

    env.token["DAI"].transfer(accounts[1], 100000e18, {"from": accounts[0]})
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    cToken.transfer(accounts[1], 100000e8, {"from": accounts[0]})
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


def test_lend_failures(environment, accounts):
    with brownie.reverts("Insufficient cash"):
        action = get_balance_trade_action(
            2,
            "None",  # No balance
            [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("Invalid market"):
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 3,  # invalid market
                    "notional": 100e8,
                    "minSlippage": 0,
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("Insufficient cash"):
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 1,
                    "notional": 500e8,  # insufficient cash
                    "minSlippage": 0,
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("Trade failed, slippage"):
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 1,
                    "notional": 500e8,
                    "minSlippage": 0.40 * RATE_PRECISION,  # min bound
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("Trade failed"):
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 1,
                    "notional": 100000e8,
                    "minSlippage": 0.40 * RATE_PRECISION,  # min bound
                }
            ],
            depositActionAmount=100000e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )


def test_deposit_underlying_and_lend_specify_fcash(environment, accounts):
    fCashAmount = environment.notional.getfCashAmountGivenCashAmount(2, -100e8, 1, chain.time() + 1)

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": fCashAmount, "minSlippage": 0}],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
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
    assert context[1] == "0x00"
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == fCashAmount

    marketsAfter = environment.notional.getActiveMarkets(2)

    cTokenTransfer = txn.events["Transfer"][-2]["amount"] - txn.events["Transfer"][-1]["amount"]
    reserveBalance = environment.notional.getReserveBalance(2)

    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert marketsBefore[0][3] - marketsAfter[0][3] == -cTokenTransfer + reserveBalance
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] > marketsAfter[0][5]

    check_system_invariants(environment, accounts)


def test_deposit_asset_and_lend(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=5100e8,
        withdrawEntireCashBalance=True,
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
    assert context[1] == "0x00"
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    marketsAfter = environment.notional.getActiveMarkets(2)
    reserveBalance = environment.notional.getReserveBalance(2)

    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert (
        marketsBefore[0][3] - marketsAfter[0][3]
        == -txn.events["Transfer"]["amount"] + reserveBalance
    )  # cToken transfer amount
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] > marketsAfter[0][5]

    check_system_invariants(environment, accounts)


# @pytest.mark.skip
# def test_roll_lend_to_maturity(environment, accounts):
#     action = get_balance_trade_action(
#         2,
#         "DepositAsset",
#         [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
#         depositActionAmount=5100e8,
#         withdrawEntireCashBalance=True,
#     )

#     environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
#     marketsBefore = environment.notional.getActiveMarkets(2)

#     blockTime = chain.time() + 1
#     cashAmount = environment.notional.getCashAmountGivenfCashAmount(2, 100e8, 1, blockTime)
#     fCashAmount = environment.notional.getfCashAmountGivenCashAmount(2, -cashAmount, 2, blockTime)
#     assert False
#     action = get_balance_trade_action(
#         2,
#         "None",
#         [
#             {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0},
#             {
#                 "tradeActionType": "Lend",
#                 "marketIndex": 2,
#                 "notional": fCashAmount,
#                 "minSlippage": 0,
#             },
#         ],
#     )

#     txn = environment.notional.batchBalanceAndTradeAction(
#         accounts[1], [action], {"from": accounts[1]}
#     )

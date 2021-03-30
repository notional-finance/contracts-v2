import brownie
import pytest
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment
from tests.constants import HAS_ASSET_DEBT, HAS_BOTH_DEBT, RATE_PRECISION, SECONDS_IN_QUARTER
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
    cToken.transfer(accounts[1], 500000e8, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})

    cToken = env.cToken["USDC"]
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["USDC"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(10000000e6, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    env.token["USDC"].transfer(accounts[1], 100000e6, {"from": accounts[0]})
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    cToken.transfer(accounts[1], 500000e8, {"from": accounts[0]})
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


def test_borrow_failures(environment, accounts):
    with brownie.reverts("Insufficient free collateral"):
        action = get_balance_trade_action(
            2,
            "None",  # No balance
            [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("BH: cannot withdraw negative"):
        collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=10000e8)

        borrowAction = get_balance_trade_action(
            2,
            "None",
            [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
            withdrawAmountInternalPrecision=1000000e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [borrowAction, collateral], {"from": accounts[1]}
        )

    with brownie.reverts("Invalid market"):
        collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=10000e8)

        borrowAction = get_balance_trade_action(
            2,
            "None",
            [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [borrowAction, collateral], {"from": accounts[1]}
        )

    with brownie.reverts("Trade failed, slippage"):
        collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=10000e8)

        borrowAction = get_balance_trade_action(
            2,
            "None",  # No balance
            [
                {
                    "tradeActionType": "Borrow",
                    "marketIndex": 2,
                    "notional": 100e8,
                    "maxSlippage": 0.01 * RATE_PRECISION,
                }
            ],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [borrowAction, collateral], {"from": accounts[1]}
        )

    with brownie.reverts("Trade failed"):
        collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=10000e8)

        borrowAction = get_balance_trade_action(
            2,
            "None",  # No balance
            [
                {
                    "tradeActionType": "Borrow",
                    "marketIndex": 2,
                    "notional": 1000000e8,
                    "maxSlippage": 0.01 * RATE_PRECISION,
                }
            ],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [borrowAction, collateral], {"from": accounts[1]}
        )


def test_deposit_underlying_and_borrow_specify_fcash(environment, accounts):
    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        2,
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

    collateral = get_balance_trade_action(3, "DepositUnderlying", [], depositActionAmount=10000e6)

    marketsBefore = environment.notional.getActiveMarkets(2)
    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )

    assert txn.events["BatchTradeExecution"][0]["account"] == accounts[1]
    assert txn.events["BatchTradeExecution"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False), (3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])
    assert (500000e8, 0, 0) == environment.notional.getAccountBalance(3, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == -fCashAmount

    marketsAfter = environment.notional.getActiveMarkets(2)

    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert marketsBefore[0][3] > marketsAfter[0][3]
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] < marketsAfter[0][5]

    check_system_invariants(environment, accounts)


def test_mint_perp_tokens_and_borrow_specify_fcash(environment, accounts):
    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        2,
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

    collateral = get_balance_trade_action(
        3, "DepositUnderlyingAndMintPerpetual", [], depositActionAmount=10000e6
    )

    marketsBefore = environment.notional.getActiveMarkets(2)
    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )
    assert txn.events["BatchTradeExecution"][0]["account"] == accounts[1]
    assert txn.events["BatchTradeExecution"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False), (3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])
    assert (0, 500000e8, txn.timestamp) == environment.notional.getAccountBalance(3, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == -fCashAmount

    marketsAfter = environment.notional.getActiveMarkets(2)

    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert marketsBefore[0][3] > marketsAfter[0][3]
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] < marketsAfter[0][5]

    check_system_invariants(environment, accounts)


def test_deposit_asset_and_borrow(environment, accounts):
    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        2,
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

    collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=500000e8)

    marketsBefore = environment.notional.getActiveMarkets(2)
    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )
    assert txn.events["BatchTradeExecution"][0]["account"] == accounts[1]
    assert txn.events["BatchTradeExecution"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False), (3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])
    assert (500000e8, 0, 0) == environment.notional.getAccountBalance(3, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == -fCashAmount

    marketsAfter = environment.notional.getActiveMarkets(2)

    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert marketsBefore[0][3] > marketsAfter[0][3]
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] < marketsAfter[0][5]

    check_system_invariants(environment, accounts)


def test_roll_borrow_to_maturity(environment, accounts):
    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        2,
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

    collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=500000e8)

    marketsBefore = environment.notional.getActiveMarkets(2)
    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )

    blockTime = chain.time() + 1
    (assetCash, cash) = environment.notional.getCashAmountGivenfCashAmount(2, 100e8, 1, blockTime)
    fCashAmount = environment.notional.getfCashAmountGivenCashAmount(2, cash, 2, blockTime)
    fCashAmount = int(fCashAmount * 1.005)  # TODO: residuals are higher in borrow for some reason

    (assetCash2, cash2) = environment.notional.getCashAmountGivenfCashAmount(
        2, fCashAmount, 2, blockTime
    )
    action = get_balance_trade_action(
        2,
        "None",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0},
            {
                "tradeActionType": "Borrow",
                "marketIndex": 2,
                "notional": fCashAmount,
                "maxSlippage": 0,
            },
        ],
    )

    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [action], {"from": accounts[1]}
    )

    assert txn.events["BatchTradeExecution"][0]["account"] == accounts[1]
    assert txn.events["BatchTradeExecution"][0]["currencyId"] == 2

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, True), (3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    (residual, perp, mint) = environment.notional.getAccountBalance(2, accounts[1])
    assert perp == 0
    assert mint == 0
    assert residual < 2e8

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[1][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == -fCashAmount

    check_system_invariants(environment, accounts)


@pytest.mark.only
def test_settle_cash_debt(environment, accounts):
    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        2,
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
    )

    collateral = get_balance_trade_action(3, "DepositAsset", [], depositActionAmount=500000e8)
    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )

    markets = environment.notional.getActiveMarkets(2)
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    # Markets do not need to be initialized to settle debts...test that
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "SettleCashDebt",
                "counterparty": accounts[1].address,
                "amountToSettle": 0,
            }
        ],
        depositActionAmount=100000e8,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[0], [action], {"from": accounts[0]})

    settler = environment.notional.getAccountPortfolio(accounts[0])
    settled = environment.notional.getAccountPortfolio(accounts[1])
    assert settler[0][1] == markets[1][1]
    assert settler[0][1] == settled[0][1]
    assert settler[0][3] + settled[0][3] == 0

    (settlerCashBalance, _, _) = environment.notional.getAccountBalance(2, accounts[0])
    assert settlerCashBalance == (100000e8 - 5000e8)

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False), (3, False, True)]
    assert context[1] == HAS_BOTH_DEBT  # TODO: need to clear this flag during the next FC
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    check_system_invariants(environment, accounts)

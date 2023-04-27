import brownie
import pytest
from brownie.network.state import Chain
from scripts.EventProcessor import processTxn
from tests.constants import HAS_ASSET_DEBT, HAS_BOTH_DEBT, RATE_PRECISION
from tests.helpers import (
    active_currencies_to_list,
    get_balance_trade_action,
    initialize_environment,
)
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


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

    with brownie.reverts("No Prime Borrow"):
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

    with brownie.reverts("Trade failed, liquidity"):
        collateral = get_balance_trade_action(
            3, "DepositUnderlying", [], depositActionAmount=10000e8
        )

        borrowAction = get_balance_trade_action(
            2,
            "None",  # No balance
            [
                {
                    "tradeActionType": "Borrow",
                    "marketIndex": 2,
                    "notional": 1_000_000e8,
                    "maxSlippage": 0,
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

    collateral = get_balance_trade_action(3, "DepositUnderlying", [], depositActionAmount=10_000e6)

    marketsBefore = environment.notional.getActiveMarkets(2)
    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [-fCashAmount],
        netCash=lambda x: x[3] == environment.approxPrimeCash('USDC', 10_000e6)
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [borrowAction, collateral], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False), (3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])
    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert environment.approxInternal("USDC", balances[0], 10_000e8)
    assert balances[1] == 0
    assert balances[2] == 0

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


@pytest.mark.only
def test_mint_ntokens_and_borrow_specify_fcash(environment, accounts):
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
        3, "DepositUnderlyingAndMintNToken", [], depositActionAmount=10_000e6
    )

    marketsBefore = environment.notional.getActiveMarkets(2)
    # TODO: this does not bundle properly because mint nTokens sits above the account action
    with EventChecker(environment, "Mint nToken",
        minter=accounts[1],
        # netfCashAssets=lambda x: list(x.values()) == [-fCashAmount],
        # netCash=lambda x: 3 not in x[3]
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [borrowAction, collateral], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False), (3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])
    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 0
    assert environment.approxInternal("USDC", balances[1], 10_000e8)
    assert balances[2] == 0

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
    with EventChecker(environment, "Account Action", account=accounts[1]) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [borrowAction, collateral], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False), (3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])
    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert environment.approxInternal("USDC", balances[0], 10_000e8)
    assert balances[1] == 0
    assert balances[2] == 0

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

    collateral = get_balance_trade_action(3, "DepositUnderlying", [], depositActionAmount=10_000e6)

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

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [100e8, -fCashAmount],
        netCash=lambda x: 0 < x[2] and x[2] < 10e8 # Only dust residual left
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, True), (3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    (residual, nToken, mint) = environment.notional.getAccountBalance(2, accounts[1])
    assert nToken == 0
    assert mint == 0
    assert residual < 10e8

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[1][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == -fCashAmount

    check_system_invariants(environment, accounts)


def test_deposit_and_borrow_bitmap(environment, accounts):
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
    collateral = get_balance_trade_action(3, "DepositUnderlying", [], depositActionAmount=10_000e6)

    marketsBefore = environment.notional.getActiveMarkets(2)
    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [-fCashAmount],
        netCash=lambda x: x[3] == environment.approxPrimeCash('USDC', 10_000e6)
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [borrowAction, collateral], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(3, False, True)]
    assert context[1] == HAS_ASSET_DEBT
    assert context[2] == 0
    assert context[3] == 2
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == -100e8

    check_system_invariants(environment, accounts)

def test_borrow_to_close_prime_lending(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=5e18,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    # Open a prime borrow / lend fixed position
    environment.notional.enablePrimeBorrow(True, {"from": accounts[1]})
    txn = environment.notional.batchBalanceAndTradeAction(
        accounts[1], [action], {"from": accounts[1]}
    )

    chain.mine(1, timedelta=86400)

    # Borrow to close the position
    action = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        depositActionAmount=0,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [-100e8],
        netCash=lambda x: x[2] > 0
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )
        c['txn'] = txn

    # Account context is cleaned out
    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []
    assert context[1] == "0x00"
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 0

    # A bit of loss on the margin due to 30 bps trading fees both ways
    transfer = list(
        filter(lambda e: e['from'] == environment.notional.address and e['to'] == accounts[1].address, txn.events['Transfer'])
    )[0]
    assert pytest.approx(transfer["value"] / 5e18, abs=0.01) == 0.96

    check_system_invariants(environment, accounts)

def test_borrow_fixed_withdraw_amount_with_prime_cash_debt(environment, accounts):
    environment.notional.enablePrimeBorrow(True, {"from": accounts[1]})
    # Deposit some collateral and borrow some DAI using prime cash
    environment.notional.depositUnderlyingToken(
        accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
    )
    environment.notional.withdraw(2, 100e8, True, {"from": accounts[1]})

    marketsBefore = environment.notional.getActiveMarkets(2)
    (_, borrowAmountPrimeCash, _, _) = environment.notional.getPrincipalFromfCashBorrow(
        2, 100e8, marketsBefore[0][1], 0, chain.time()
    )

    # Borrow fixed and withdraw the borrowed amount given the prime cash debt
    # This is an uncommon scenario but want to test the effect of a precise withdraw
    # amount, since using withdrawEntireCashBalance only works when positive and will
    # cause the prime debt to be repaid.
    action = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        depositActionAmount=0,
        withdrawAmountInternalPrecision=borrowAmountPrimeCash,
        redeemToUnderlying=True,
    )

    balanceBefore = environment.notional.getAccountBalance(2, accounts[1])[0]
    assert pytest.approx(balanceBefore, abs=1) == -100e8

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [-100e8],
        netCash=lambda x: 0 < x[2] and x[2] < 1e8
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )
        c['txn'] = txn

    balanceAfter = environment.notional.getAccountBalance(2, accounts[1])[0]
    assert pytest.approx(balanceAfter, abs=10_000) == balanceBefore
    transfer = list(
        filter(lambda e: e['from'] == environment.notional.address and e['to'] == accounts[1].address, txn.events['Transfer'])
    )[0]
    assert environment.approxExternal(
        "DAI", borrowAmountPrimeCash, transfer["value"]
    )
    context = environment.notional.getAccountContext(accounts[1])
    assert context["hasDebt"] == HAS_BOTH_DEBT

    check_system_invariants(environment, accounts)

def test_borrow_fails_on_supply_cap(environment, accounts):
    factors = environment.notional.getPrimeFactorsStored(2)
    environment.notional.setMaxUnderlyingSupply(2, factors['lastTotalUnderlyingValue'] + 1e8)
    factors = environment.notional.getPrimeFactorsStored(3)
    environment.notional.setMaxUnderlyingSupply(3, factors['lastTotalUnderlyingValue'] + 1e8)

    deposit = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [],
        depositActionAmount=100e18
    )

    borrow = get_balance_trade_action(
        3,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 25e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
    )

    with brownie.reverts("Over Supply Cap"):
        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [deposit, borrow], {"from": accounts[1]}
        )

    # Increase supply cap on DAI only, borrows still have a cap.
    environment.notional.setMaxUnderlyingSupply(2, factors['lastTotalUnderlyingValue'] + 105e8)

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [deposit, borrow], {"from": accounts[1]}
    )

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 1
    assert portfolio[0][0] == 3
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == -25e8

    check_system_invariants(environment, accounts)
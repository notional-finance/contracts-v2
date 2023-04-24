import math

import brownie
import pytest
from brownie import MockERC20
from brownie.network.state import Chain
from brownie.test import given, strategy
from liquidation_fixtures import *
from tests.helpers import get_balance_trade_action
from tests.snapshot import EventChecker

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def check_local_fcash_liquidation(env, accounts, currencyId, maturities, assetsToAccount, assetsToLiquidator):
    fcBefore = env.notional.getFreeCollateral(accounts[2])
    (transfersCalculated, netLocalCalculated) = env.notional.calculatefCashLocalLiquidation.call(
        accounts[2], currencyId, maturities, len(maturities) * [0]
    )
    localUnderlying = env.notional.convertCashBalanceToExternal(
        currencyId, netLocalCalculated, True
    )

    if currencyId != 1:
        token = MockERC20.at(
            env.notional.getCurrency(currencyId)["underlyingToken"]["tokenAddress"]
        )

    cashBalanceBefore = env.notional.getAccountBalance(currencyId, accounts[0])[0]
    if currencyId == 1:
        balanceBefore = accounts[0].balance()
    else:
        balanceBefore = token.balanceOf(accounts[0])

    with EventChecker(env, 'Liquidation',
        liquidator=accounts[0],
        account=accounts[2],
        localCurrency=currencyId,
        collateralCurrency=currencyId,
        assetsToAccount=assetsToAccount,
        assetsToLiquidator=assetsToLiquidator
    ) as e:
        txn = env.notional.liquidatefCashLocal(
            accounts[2],
            currencyId,
            maturities,
            len(maturities) * [0],
            {
                "from": accounts[0],
                "value": localUnderlying + 2e18 if currencyId == 1 and localUnderlying > 0 else 0,
            },
        )
        e['txn'] = txn

    cashBalanceAfter = env.notional.getAccountBalance(currencyId, accounts[0])[0]
    if currencyId == 1:
        balanceAfter = accounts[0].balance()
    else:
        balanceAfter = token.balanceOf(accounts[0])

    assert txn.events["LiquidatefCashEvent"]
    netLocal = txn.events["LiquidatefCashEvent"]["netLocalFromLiquidator"]
    transfers = txn.events["LiquidatefCashEvent"]["fCashNotionalTransfer"]

    assert pytest.approx(netLocal, rel=1e-5) == netLocalCalculated
    for (i, t) in enumerate(transfers):
        assert pytest.approx(t, rel=1e-5) == transfersCalculated[i]
    if localUnderlying > 0:
        assert pytest.approx(balanceBefore - balanceAfter, rel=1e-5) == localUnderlying
    else:
        assert pytest.approx(cashBalanceAfter - cashBalanceBefore, rel=1e-5) == -netLocalCalculated

    check_liquidation_invariants(env, accounts[2], fcBefore)

    return (netLocal, transfers)

@given(currencyId=strategy("uint", min_value=1, max_value=3))
def test_local_fcash_borrow_fcash(env, accounts, currencyId):
    decimals = env.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    depositActionAmount = 100 * decimals
    # Creates a trade on the spread between the 3mo and 6mo markets
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 103.8e8, "minSlippage": 0},
            {"tradeActionType": "Borrow", "marketIndex": 2, "notional": 100e8, "maxSlippage": 0},
        ],
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=True,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[2],
        [action],
        {"from": accounts[2], "value": depositActionAmount if currencyId == 1 else 0},
    )

    # Move the lend borrow spread against account[2]
    depositActionAmount = 1000 * decimals if currencyId == 1 else 1_000_000 * decimals
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 1,
                "notional": 275e8 if currencyId == 1 else 200_000e8,
                "maxSlippage": 0,
            },
            {
                "tradeActionType": "Lend",
                "marketIndex": 2,
                "notional": 325e8 if currencyId == 1 else 300_000e8,
                "minSlippage": 0,
            },
        ],
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=False,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[0],
        [action],
        {"from": accounts[0], "value": depositActionAmount if currencyId == 1 else 0},
    )

    # Allow the rate oracle to catch up
    chain.mine(1, timedelta=86400 / 4)

    portfolio = env.notional.getAccountPortfolio(accounts[2])
    maturities = list(reversed([asset[1] for asset in portfolio if asset[3] > 0]))
    check_local_fcash_liquidation(env, accounts, currencyId, maturities, 
        lambda x: len(x) == 1 and x[0]['assetType'] == 'pCash' and x[0]['underlying'] == currencyId,
        lambda x: len(x) == 1 and x[0]['assetType'] == 'fCash' and x[0]['underlying'] == currencyId,
    )


@given(currencyId=strategy("uint", min_value=1, max_value=3))
def test_local_fcash_borrow_lend_cash(env, accounts, currencyId):
    decimals = env.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    depositActionAmount = 4.75 * decimals
    # Borrow fCash and hold a cash position
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [{"tradeActionType": "Borrow", "marketIndex": 2, "notional": 100e8, "maxSlippage": 0}],
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=False,
    )

    env.notional.batchBalanceAndTradeAction(
        accounts[2],
        [action],
        {"from": accounts[2], "value": depositActionAmount if currencyId == 1 else 0},
    )

    # Move the interest rate against account[2]
    depositActionAmount = 1000 * decimals if currencyId == 1 else 1_000_000 * decimals
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "Lend",
                "marketIndex": 2,
                "notional": 150e8 if currencyId == 1 else 150_000e8,
                "minSlippage": 0,
            }
        ],
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=False,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[0],
        [action],
        {"from": accounts[0], "value": depositActionAmount if currencyId == 1 else 0},
    )

    # Allow the rate oracle to catch up
    chain.mine(1, timedelta=86400 / 4)

    portfolio = env.notional.getAccountPortfolio(accounts[2])
    maturities = list(reversed([asset[1] for asset in portfolio if asset[3] < 0]))

    check_local_fcash_liquidation(env, accounts, currencyId, maturities,
        lambda x: len(x) == 1 and x[0]['assetType'] == 'fCash' and x[0]['underlying'] == currencyId,
        lambda x: len(x) == 1 and x[0]['assetType'] == 'pCash' and x[0]['underlying'] == currencyId,
    )


@given(currencyId=strategy("uint", min_value=1, max_value=3))
def test_local_fcash_borrow_prime(env, accounts, currencyId):
    decimals = env.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    env.notional.enablePrimeBorrow(True, {"from": accounts[2]})
    depositActionAmount = 4.5 * decimals

    # Borrow prime and hold an fCash position
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=False,
    )

    env.notional.batchBalanceAndTradeAction(
        accounts[2],
        [action],
        {"from": accounts[2], "value": depositActionAmount if currencyId == 1 else 0},
    )

    # Move the interest rate against account[2]
    depositActionAmount = 1000 * decimals if currencyId == 1 else 1_000_000 * decimals
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 2,
                "notional": 150e8 if currencyId == 1 else 150_000e8,
                "maxSlippage": 0,
            }
        ],
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=False,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[0],
        [action],
        {"from": accounts[0], "value": depositActionAmount if currencyId == 1 else 0},
    )

    # Allow the rate oracle to catch up
    chain.mine(1, timedelta=86400 / 4)

    portfolio = env.notional.getAccountPortfolio(accounts[2])
    maturities = list(reversed([asset[1] for asset in portfolio if asset[3] > 0]))

    check_local_fcash_liquidation(env, accounts, currencyId, maturities,
        lambda x: len(x) == 1 and x[0]['assetType'] == 'pCash' and x[0]['underlying'] == currencyId,
        lambda x: len(x) == 1 and x[0]['assetType'] == 'fCash' and x[0]['underlying'] == currencyId,
    )

@given(currencyId=strategy("uint", min_value=1, max_value=3))
def test_liquidate_local_multiple_maturities(env, accounts, currencyId):
    decimals = env.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    depositActionAmount = 6.5 * decimals
    # Borrow fCash and hold a cash and lending position
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 80e8, "minSlippage": 0},
            {"tradeActionType": "Borrow", "marketIndex": 2, "notional": 100e8, "maxSlippage": 0},
        ],
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=False,
    )

    env.notional.batchBalanceAndTradeAction(
        accounts[2],
        [action],
        {"from": accounts[2], "value": depositActionAmount if currencyId == 1 else 0},
    )

    # Move the interest rate against account[2]
    depositActionAmount = 1000 * decimals if currencyId == 1 else 1_000_000 * decimals
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 1,
                "notional": 200e8 if currencyId == 1 else 200_000e8,
                "maxSlippage": 0,
            },
            # NOTE: if this gets too close to zero then we can get divide by zero revert error
            {
                "tradeActionType": "Lend",
                "marketIndex": 2,
                "notional": 275e8 if currencyId == 1 else 275_000e8,
                "minSlippage": 0,
            },
        ],
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=False,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[0],
        [action],
        {"from": accounts[0], "value": depositActionAmount if currencyId == 1 else 0},
    )

    # Allow the rate oracle to catch up
    chain.mine(1, timedelta=86400 / 4)

    portfolio = env.notional.getAccountPortfolio(accounts[2])
    maturities = list(reversed([asset[1] for asset in portfolio]))

    check_local_fcash_liquidation(env, accounts, currencyId, maturities, lambda x: True, lambda x: True)


@pytest.mark.only
@given(
    currencyId=strategy("uint", min_value=1, max_value=3),
    isPrime=strategy("bool"),
    numAssets=strategy("uint", min_value=1, max_value=2),
)
def test_cross_currency_fcash(env, accounts, currencyId, isPrime, numAssets):
    # Lend fCash in collateral currency, using ETH unless ETH is local
    decimals = env.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    symbol = list(filter(lambda x: env.currencyId[x] == currencyId, env.currencyId))[0]
    collateralCurrency = 2 if currencyId == 1 else 1
    collateralSymbol = list(
        filter(lambda x: env.currencyId[x] == collateralCurrency, env.currencyId)
    )[0]

    depositActionAmount = 100e18  # this is always DAI or ETH
    trades = []
    for i in range(0, numAssets):
        trades.append(
            {
                "tradeActionType": "Lend",
                "marketIndex": i + 1,
                "notional": 100e8 / numAssets,
                "minSlippage": 0,
            }
        )

    action = get_balance_trade_action(
        collateralCurrency,
        "DepositUnderlying",
        trades,
        depositActionAmount=depositActionAmount,
        withdrawEntireCashBalance=True,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[2],
        [action],
        {"from": accounts[2], "value": depositActionAmount if collateralCurrency == 1 else 0},
    )

    if currencyId == 1:
        oracle = env.ethOracle[collateralSymbol]
    else:
        oracle = env.ethOracle[symbol]

    # Borrowing up to the FC amount
    (fc, netLocal) = env.notional.getFreeCollateral(accounts[2])
    maxBorrowLocal = fc * 1e18 / oracle.latestAnswer() if currencyId != 1 else fc
    buffer = env.notional.getRateStorage(currencyId)["ethRate"]["buffer"]

    if isPrime:
        env.notional.enablePrimeBorrow(True, {"from": accounts[2]})
        maxBorrowUnderlying = math.floor(maxBorrowLocal * 99 / buffer)
        maxBorrowPrimeCash = env.notional.convertUnderlyingToPrimeCash(
            currencyId, maxBorrowUnderlying * decimals / 1e8
        )
        env.notional.withdraw(currencyId, maxBorrowPrimeCash, True, {"from": accounts[2]})
    else:
        fCashAmount = -math.floor(
            95
            * env.notional.getfCashAmountGivenCashAmount(
                currencyId, maxBorrowLocal, 1, chain.time()
            )
            / buffer
        )

        action = get_balance_trade_action(
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
        env.notional.batchBalanceAndTradeAction(accounts[2], [action], {"from": accounts[2]})

    # Decrease ETH value
    if currencyId == 1:
        oracle.setAnswer(math.floor(oracle.latestAnswer() * 0.90))
    else:
        oracle.setAnswer(math.floor(oracle.latestAnswer() * 1.10))

    fcBefore = env.notional.getFreeCollateral(accounts[2])
    portfolio = env.notional.getAccountPortfolio(accounts[2])
    maturities = list(reversed([asset[1] for asset in portfolio if asset[3] > 0]))
    (
        transfersCalculated,
        netLocalCalculated,
    ) = env.notional.calculatefCashCrossCurrencyLiquidation.call(
        accounts[2], currencyId, collateralCurrency, maturities, [0] * len(maturities)
    )
    localUnderlying = env.notional.convertCashBalanceToExternal(
        currencyId, netLocalCalculated, True
    )
    balanceBefore = env.token["DAI"].balanceOf(accounts[0])

    if currencyId != 1:
        token = MockERC20.at(
            env.notional.getCurrency(currencyId)["underlyingToken"]["tokenAddress"]
        )

    if currencyId == 1:
        balanceBefore = accounts[0].balance()
    else:
        balanceBefore = token.balanceOf(accounts[0])

    with EventChecker(env, 'Liquidation',
        liquidator=accounts[0],
        account=accounts[2],
        localCurrency=currencyId,
        collateralCurrency=collateralCurrency,
        assetsToAccount=lambda x: len(x) == 1 and x[0]['assetType'] == 'pCash' and x[0]['underlying'] == currencyId,
        assetsToLiquidator=lambda x: len(x) == 1 and x[0]['assetType'] == 'fCash' and x[0]['underlying'] == collateralCurrency,
    ) as e:
        txn = env.notional.liquidatefCashCrossCurrency(
            accounts[2],
            currencyId,
            collateralCurrency,
            maturities,
            [0] * len(maturities),
            {"from": accounts[0], "value": localUnderlying + 2e18 if currencyId == 1 else 0},
        )
        e['txn'] = txn

    if currencyId == 1:
        balanceAfter = accounts[0].balance()
    else:
        balanceAfter = token.balanceOf(accounts[0])

    assert txn.events["LiquidatefCashEvent"]
    netLocal = txn.events["LiquidatefCashEvent"]["netLocalFromLiquidator"]
    transfers = txn.events["LiquidatefCashEvent"]["fCashNotionalTransfer"]

    assert pytest.approx(netLocal, rel=1e-5) == netLocalCalculated
    for (i, t) in enumerate(transfers):
        assert pytest.approx(t, rel=1e-5) == transfersCalculated[i]
    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-5) == localUnderlying

    check_liquidation_invariants(env, accounts[2], fcBefore)


def test_multiple_maturities(env, accounts):
    # Test ability to liquidate both cross and local
    # Borrows fCash holds some cash, also has cross currency assets

    depositActionAmount = 100e18
    eth = get_balance_trade_action(
        1,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 25e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 25e8, "minSlippage": 0},
        ],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )
    dai = get_balance_trade_action(
        2,
        "None",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Borrow", "marketIndex": 3, "notional": 2750e8, "maxSlippage": 0},
        ],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )

    env.notional.batchBalanceAndTradeAction(
        accounts[2], [eth, dai], {"from": accounts[2], "value": depositActionAmount}
    )

    oracle = env.ethOracle["DAI"]
    # With negative FC, should be able to liquidate both local and cross currency
    oracle.setAnswer(oracle.latestAnswer() * 1.2)

    portfolio = env.notional.getAccountPortfolio(accounts[2])
    # ETH maturities
    ethMaturities = [asset[1] for asset in portfolio if asset[0] == 1]
    # DAI maturities
    daiMaturities = [asset[1] for asset in portfolio if asset[0] == 2]

    # Reverts on maturities that are not reversed
    with brownie.reverts():
        env.notional.liquidatefCashCrossCurrency.call(
            accounts[2], 2, 1, ethMaturities, [0, 0], {"from": accounts[0]}
        )

    with brownie.reverts():
        env.notional.liquidatefCashLocal.call(
            accounts[2], 2, daiMaturities, [0, 0], {"from": accounts[0]}
        )

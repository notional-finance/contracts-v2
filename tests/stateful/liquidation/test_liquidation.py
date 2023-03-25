import math

import brownie
import pytest
from brownie import MockERC20
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from liquidation_fixtures import *
from scripts.config import CurrencyDefaults, nTokenDefaults
from tests.constants import RATE_PRECISION, SECONDS_IN_QUARTER
from tests.helpers import get_balance_trade_action, get_lend_action, get_tref
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.mark.liquidation
def test_cannot_liquidate_self(env, accounts):
    liquidated = accounts[7]
    env.ethOracle["DAI"].setAnswer(0.017e18)
    liquidatedPortfolioBefore = env.notional.getAccountPortfolio(liquidated)
    maturities = [asset[1] for asset in liquidatedPortfolioBefore]
    with brownie.reverts():
        env.notional.liquidatefCashCrossCurrency(
            liquidated, 2, 1, maturities, [0, 0], {"from": liquidated}
        )


@pytest.mark.liquidation
@given(useBitmap=strategy("bool"))
def test_liquidator_settle_assets(env, accounts, useBitmap):
    liquidated = accounts[7]
    # account[7]: DAI borrower with ETH fCash collateral (2x)
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    collateral = get_balance_trade_action(
        1,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 1e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 1e8, "minSlippage": 0},
        ],
        depositActionAmount=2e18,
    )

    env.notional.batchBalanceAndTradeAction(
        accounts[7], [collateral, borrowAction], {"from": accounts[7], "value": 2e18}
    )

    collateral = get_balance_trade_action(
        1,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 1e8, "minSlippage": 0}],
        depositActionAmount=1e18,
    )

    if useBitmap:
        env.notional.enableBitmapCurrency(1, {"from": accounts[0]})

    env.notional.batchBalanceAndTradeAction(
        accounts[0], [collateral], {"from": accounts[0], "value": 1e18}
    )
    # Decrease ETH rate
    env.ethOracle["DAI"].setAnswer(0.014e18)

    fcBefore = env.notional.getFreeCollateral(liquidated)
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    env.notional.initializeMarkets(1, False)
    env.notional.initializeMarkets(2, False)

    liquidatedPortfolioBefore = env.notional.getAccountPortfolio(liquidated)
    maturities = list(reversed([asset[1] for asset in liquidatedPortfolioBefore]))

    # The liquidator and liquidated accounts both have matured assets
    # Also we pass in the maturity of the matured asset here, should not affect
    # the liquidation, should only liquidate the eth fCash asset
    env.notional.liquidatefCashCrossCurrency(
        liquidated, 2, 1, maturities, [0, 0, 0], {"from": accounts[0]}
    )

    check_liquidation_invariants(env, liquidated, fcBefore)


@pytest.mark.liquidation
@pytest.mark.skip(reason="liquidity tokens are disabled")
def test_calculations_dont_change_markets(env, accounts):
    cashGroup = list(env.notional.getCashGroup(2))
    cashGroup[9] = [80, 80, 80]
    env.notional.updateCashGroup(2, cashGroup)

    marketsBefore2 = env.notional.getActiveMarkets(2)
    env.notional.calculateLocalenv(accounts[6], 2, 0)
    marketsAfter2 = env.notional.getActiveMarkets(2)
    assert marketsBefore2 == marketsAfter2

    marketsBefore1 = env.notional.getActiveMarkets(1)
    env.ethOracle["DAI"].setAnswer(0.0135e18)
    env.notional.calculateCollateralenv(accounts[4], 2, 1, 0, 0)
    marketsAfter1 = env.notional.getActiveMarkets(1)
    assert marketsBefore1 == marketsAfter1


@pytest.mark.liquidation
def test_settlement_on_calculation_currency(env, accounts):
    liquidated = accounts[10]
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 150e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=2.8e18)
    env.notional.batchBalanceAndTradeAction(
        liquidated, [collateral, borrowAction], {"from": liquidated, "value": 2.8e18}
    )

    # Decrease ETH rate
    env.ethOracle["DAI"].setAnswer(0.014e18)

    blockTime = chain.time()
    nextInit = get_tref(blockTime) + SECONDS_IN_QUARTER
    chain.mine(1, timestamp=nextInit - 1)
    fcBefore = env.notional.getFreeCollateral(liquidated)

    chain.mine(1, timestamp=nextInit)
    env.notional.initializeMarkets(1, False)
    env.notional.initializeMarkets(2, False)
    env.notional.initializeMarkets(3, False)

    env.notional.calculateLocalCurrencyLiquidation(liquidated, 2, 0)
    fcAfter = env.notional.getFreeCollateral(liquidated)

    assert pytest.approx(fcBefore[0], abs=10) == fcAfter[0]
    check_system_invariants(env, accounts)


@pytest.mark.liquidation
def test_settlement_on_calculation_fcash(env, accounts):
    liquidated = accounts[11]
    lendAction = get_balance_trade_action(
        1,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 1.1e8, "minSlippage": 0}],
        depositActionAmount=2e18,
        withdrawEntireCashBalance=True,
    )
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 50e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
    )

    env.notional.batchBalanceAndTradeAction(
        liquidated, [lendAction, borrowAction], {"from": liquidated, "value": 2e18}
    )
    env.ethOracle["DAI"].setAnswer(0.014e18)

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    env.notional.initializeMarkets(1, False)
    env.notional.initializeMarkets(2, False)
    env.notional.initializeMarkets(3, False)

    liquidatedPortfolioBefore = env.notional.getAccountPortfolio(liquidated)
    maturities = [liquidatedPortfolioBefore[0][1]]  # Just the ETH lending asset
    env.notional.calculatefCashLocalLiquidation(liquidated, 2, maturities, [0])

    check_system_invariants(env, accounts)

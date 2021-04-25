import pytest
from brownie import accounts
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults, nTokenDefaults
from tests.constants import RATE_PRECISION, SECONDS_IN_QUARTER
from tests.helpers import get_balance_trade_action, initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()

# netLocal indexes
ETH = 0
DAI = 1


def transferDAI(environment, accounts):
    for account in accounts[1:]:
        environment.token["DAI"].transfer(account, 100000e18, {"from": accounts[0]})
        environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": account})


@pytest.fixture(scope="module", autouse=True)
def env(accounts):
    environment = initialize_environment(accounts)
    cashGroup = list(environment.notional.getCashGroup(2))
    # Enable the one year market
    cashGroup[0] = 3
    cashGroup[8] = CurrencyDefaults["tokenHaircut"][0:3]
    cashGroup[9] = CurrencyDefaults["rateScalar"][0:3]
    environment.notional.updateCashGroup(2, cashGroup)

    environment.notional.updateDepositParameters(2, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9])

    environment.notional.updateInitializationParameters(
        2, [1.01e9, 1.021e9, 1.07e9], [0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER))

    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)

    transferDAI(environment, accounts)

    return environment


@pytest.fixture(scope="module", autouse=True)
def currencyLiquidation(env, accounts):
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    # account[1]: DAI borrower with ETH cash
    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=1.5e18)
    env.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral, borrowAction], {"from": accounts[1], "value": 1.5e18}
    )

    # account[2]: DAI borrower with ETH liquidity token collateral (2x)
    collateral = get_balance_trade_action(
        1,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 0.75e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 0.75e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
        ],
        depositActionAmount=1.5e18,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[2], [collateral, borrowAction], {"from": accounts[2], "value": 1.5e18}
    )

    # account[3]: DAI borrower with ETH ntoken
    collateral = get_balance_trade_action(
        1, "DepositUnderlyingAndMintNToken", [], depositActionAmount=1.5e18
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[3], [collateral, borrowAction], {"from": accounts[3], "value": 1.5e18}
    )

    # account[4]: DAI borrower with ETH cash, liquidity token, nToken
    collateral = get_balance_trade_action(
        1,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 0.25e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 0.25e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
        ],
        depositActionAmount=1e18,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[4], [collateral], {"from": accounts[4], "value": 1e18}
    )

    collateral = get_balance_trade_action(
        1, "DepositUnderlyingAndMintNToken", [], depositActionAmount=0.5e18
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[4], [collateral, borrowAction], {"from": accounts[4], "value": 0.5e18}
    )

    # account[5]: DAI borrower with DAI ntoken
    collateral = get_balance_trade_action(
        2,
        "DepositUnderlyingAndMintNToken",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    env.notional.batchBalanceAndTradeAction(accounts[5], [collateral], {"from": accounts[5]})

    # account[6]: DAI borrower with DAI liquidity token (2x)
    collateral = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 2500e8,  # in asset cash terms
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 2,
                "notional": 2500e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
            {"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0},
        ],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    env.notional.batchBalanceAndTradeAction(accounts[6], [collateral], {"from": accounts[6]})

    return env


@pytest.fixture(scope="module", autouse=True)
def fCashLiquidation(env, accounts):
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    # account[0]: liquidator, has sufficient balances

    # account[1]: DAI borrower with ETH fCash collateral (2x)
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
        accounts[1], [collateral, borrowAction], {"from": accounts[1], "value": 2e18}
    )

    # account[2]: DAI borrower with DAI fCash collateral (2x)
    lendBorrowAction = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 50e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 50e8, "minSlippage": 0},
            {"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0},
        ],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
        depositActionAmount=100e18,
    )

    env.notional.batchBalanceAndTradeAction(accounts[2], [lendBorrowAction], {"from": accounts[2]})

    return env


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def check_liquidation_invariants(environment, liquidatedAccount, fcBefore):
    (fc, netLocal) = environment.notional.getFreeCollateralView(liquidatedAccount)
    assert fc > fcBefore[0]

    # Check that availables haven't crossed boundaries
    if fcBefore[1][ETH] > 0:
        assert netLocal[ETH] >= 0
    else:
        assert netLocal[ETH] <= 0

    if fcBefore[1][DAI] > 0:
        assert netLocal[DAI] >= 0
    else:
        assert netLocal[DAI] <= 0

    check_system_invariants(environment, accounts)


def move_oracle_rate(environment, marketIndex):
    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=100e18)
    # Why am I getting a trade failed liquidity error?
    borrow = get_balance_trade_action(
        2,
        "None",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": marketIndex,
                "notional": 195000e8,
                "maxSlippage": 0.40 * RATE_PRECISION,
            }
        ],
    )
    environment.notional.batchBalanceAndTradeAction(
        accounts[9], [collateral, borrow], {"from": accounts[9], "value": 100e18}
    )


# given different max liquidation amounts
def test_liquidate_local_currency(currencyLiquidation, accounts):
    # Increase oracle rate
    # marketsBefore = currencyLiquidation.notional.getActiveMarkets(2)
    # nTokenPVBefore = currencyLiquidation.nToken[2].getPresentValueUnderlyingDenominated()
    # move_oracle_rate(currencyLiquidation, 3)
    # marketsAfter = currencyLiquidation.notional.getActiveMarkets(2)
    # nTokenPVAfter = currencyLiquidation.nToken[2].getPresentValueUnderlyingDenominated()

    # Change the governance parameters
    tokenDefaults = nTokenDefaults["Collateral"]
    tokenDefaults[1] = 80
    currencyLiquidation.notional.updateTokenCollateralParameters(2, *(tokenDefaults))

    cashGroup = list(currencyLiquidation.notional.getCashGroup(2))
    cashGroup[8] = [80, 80, 80]
    currencyLiquidation.notional.updateCashGroup(2, cashGroup)

    # liquidate account[5]
    fcBeforeNToken = currencyLiquidation.notional.getFreeCollateralView(accounts[5])
    nTokenNetRequired = currencyLiquidation.notional.calculateLocalCurrencyLiquidation.call(
        accounts[5], 2, 0
    )

    balanceBefore = currencyLiquidation.cToken["DAI"].balanceOf(accounts[0])
    txn = currencyLiquidation.notional.liquidateLocalCurrency(accounts[5], 2, 0)
    assert txn.events["LiquidateLocalCurrency"]
    netLocal = txn.events["LiquidateLocalCurrency"]["netLocalFromLiquidator"]
    balanceAfter = currencyLiquidation.cToken["DAI"].balanceOf(accounts[0])

    assert pytest.approx(netLocal, rel=1e-6) == nTokenNetRequired
    assert balanceBefore - balanceAfter == netLocal
    check_liquidation_invariants(currencyLiquidation, accounts[5], fcBeforeNToken)

    # liquidate account[6]
    fcBeforeLiquidityToken = currencyLiquidation.notional.getFreeCollateralView(accounts[6])
    liquidityTokenNetRequired = currencyLiquidation.notional.calculateLocalCurrencyLiquidation.call(
        accounts[6], 2, 0
    )

    balanceBefore = currencyLiquidation.cToken["DAI"].balanceOf(accounts[0])
    txn = currencyLiquidation.notional.liquidateLocalCurrency(accounts[6], 2, 0)
    assert txn.events["LiquidateLocalCurrency"]
    netLocal = txn.events["LiquidateLocalCurrency"]["netLocalFromLiquidator"]
    balanceAfter = currencyLiquidation.cToken["DAI"].balanceOf(accounts[0])

    assert pytest.approx(netLocal, rel=1e-6) == liquidityTokenNetRequired
    assert balanceBefore - balanceAfter == netLocal
    check_liquidation_invariants(currencyLiquidation, accounts[6], fcBeforeLiquidityToken)


# given different max liquidation amounts
def test_liquidate_collateral_currency(currencyLiquidation, accounts):
    # Decrease ETH rate
    # Get local currency required
    # liquidate account[1:4]
    pass


# given different max liquidation amounts
def test_liquidate_local_fcash(fCashLiquidation, accounts):
    # Increase oracle rate
    # Get local currency required
    # liquidate account[2]
    assert False


# given different max liquidation amounts
def test_liquidate_cross_currency_fcash(fCashLiquidation, accounts):
    # Decrease ETH rate
    # Get local currency required
    # liquidate account[1]
    pass

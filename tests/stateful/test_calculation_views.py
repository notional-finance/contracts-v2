import brownie
import pytest
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from tests.helpers import get_balance_action, get_trade_action, initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_lend_borrow_reverts_on_rate_limit(environment):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    with brownie.reverts("Trade failed, slippage"):
        environment.notional.getfCashLendFromDeposit(2, 50000e8, maturity, 1e9, chain.time(), False)
        environment.notional.getPrincipalFromfCashBorrow(2, 1000e8, maturity, 1, chain.time())


def test_borrow_from_fcash_asset_using_calculation_view(environment, accounts):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    maxSlippage = 0.1e9
    (fCash, marketIndex, encodedTrade) = environment.notional.getfCashBorrowFromPrincipal(
        2, 5000e8, maturity, maxSlippage, chain.time(), False
    )

    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Borrow",
            marketIndex=marketIndex,
            notional=fCash,
            maxSlippage=maxSlippage,
        ),
        type_str="bytes32",
    )
    assert marketIndex == 1
    environment.notional.batchBalanceAndTradeAction(
        accounts[3],
        [
            get_balance_action(1, "DepositUnderlying", depositActionAmount=100e18) + tuple([[]]),
            get_balance_action(2, "None", withdrawEntireCashBalance=True) + tuple([[encodedTrade]]),
        ],
        {"from": accounts[3], "value": 100e18},
    )

    assert pytest.approx(environment.cToken["DAI"].balanceOf(accounts[3]), rel=1e-9) == 5000e8
    check_system_invariants(environment, accounts)


def test_borrow_from_fcash_underlying_using_calculation_view(environment, accounts):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    maxSlippage = 0.1e9
    (fCash, marketIndex, encodedTrade) = environment.notional.getfCashBorrowFromPrincipal(
        2, 100e18, maturity, maxSlippage, chain.time(), True
    )

    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Borrow",
            marketIndex=marketIndex,
            notional=fCash,
            maxSlippage=maxSlippage,
        ),
        type_str="bytes32",
    )
    assert marketIndex == 1
    environment.notional.batchBalanceAndTradeAction(
        accounts[3],
        [
            get_balance_action(1, "DepositUnderlying", depositActionAmount=100e18) + tuple([[]]),
            get_balance_action(2, "None", withdrawEntireCashBalance=True, redeemToUnderlying=True)
            + tuple([[encodedTrade]]),
        ],
        {"from": accounts[3], "value": 100e18},
    )

    assert pytest.approx(environment.token["DAI"].balanceOf(accounts[3]), rel=1e-9) == 100e18
    check_system_invariants(environment, accounts)


def test_lend_from_fcash_asset_using_calculation_view(environment, accounts):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    (fCash, marketIndex, encodedTrade) = environment.notional.getfCashLendFromDeposit(
        2, 50000e8, maturity, 0, chain.time(), False
    )

    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Lend", marketIndex=marketIndex, notional=fCash, minSlippage=0
        ),
        type_str="bytes32",
    )
    assert marketIndex == 1
    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[0])
    environment.notional.batchLend(accounts[0], [(2, False, [encodedTrade])], {"from": accounts[0]})
    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[0])

    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-9) == 50000e8
    check_system_invariants(environment, accounts)


def test_lend_from_fcash_underlying_using_calculation_view(environment, accounts):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    (fCash, marketIndex, encodedTrade) = environment.notional.getfCashLendFromDeposit(
        2, 1000e18, maturity, 0, chain.time(), True
    )

    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Lend", marketIndex=marketIndex, notional=fCash, minSlippage=0
        ),
        type_str="bytes32",
    )
    assert marketIndex == 1
    balanceBefore = environment.token["DAI"].balanceOf(accounts[0])
    environment.notional.batchLend(accounts[0], [(2, True, [encodedTrade])], {"from": accounts[0]})
    balanceAfter = environment.token["DAI"].balanceOf(accounts[0])

    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-9) == 1000e18
    check_system_invariants(environment, accounts)


def test_borrow_using_calculation_view(environment, accounts):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    maxSlippage = 0.1e9
    (
        borrowAmountUnderlying,
        borrowAmountAsset,
        marketIndex,
        encodedTrade,
    ) = environment.notional.getPrincipalFromfCashBorrow(
        2, 1000e8, maturity, maxSlippage, chain.time()
    )

    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Borrow",
            marketIndex=marketIndex,
            notional=1000e8,
            maxSlippage=maxSlippage,
        ),
        type_str="bytes32",
    )
    assert marketIndex == 1
    environment.notional.batchBalanceAndTradeAction(
        accounts[3],
        [
            get_balance_action(1, "DepositUnderlying", depositActionAmount=100e18) + tuple([[]]),
            get_balance_action(2, "None", withdrawEntireCashBalance=True) + tuple([[encodedTrade]]),
        ],
        {"from": accounts[3], "value": 100e18},
    )

    assert (
        pytest.approx(environment.cToken["DAI"].balanceOf(accounts[3]), rel=1e-9)
        == borrowAmountAsset
    )
    environment.cToken["DAI"].redeem(
        environment.cToken["DAI"].balanceOf(accounts[3]), {"from": accounts[3]}
    )
    assert (
        pytest.approx(environment.token["DAI"].balanceOf(accounts[3]), rel=1e-9)
        == borrowAmountUnderlying
    )

    check_system_invariants(environment, accounts)


def test_lend_asset_using_calculation_view(environment, accounts):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    (
        depositAmountUnderlying,
        depositAmountAsset,
        marketIndex,
        encodedTrade,
    ) = environment.notional.getDepositFromfCashLend(2, 10_000e8, maturity, 0, chain.time())

    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Lend", marketIndex=marketIndex, notional=10_000e8, minSlippage=0
        ),
        type_str="bytes32",
    )
    assert marketIndex == 1
    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[0])
    environment.notional.batchLend(accounts[0], [(2, False, [encodedTrade])], {"from": accounts[0]})
    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[0])

    assert pytest.approx(balanceBefore - balanceAfter, 1e-9) == depositAmountAsset
    check_system_invariants(environment, accounts)


def test_lend_underlying_using_calculation_view(environment, accounts):
    fCash = 50_000e8
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    (
        depositAmountUnderlying,
        depositAmountAsset,
        marketIndex,
        encodedTrade,
    ) = environment.notional.getDepositFromfCashLend(2, fCash, maturity, 0, chain.time())

    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Lend", marketIndex=marketIndex, notional=fCash, minSlippage=0
        ),
        type_str="bytes32",
    )
    assert marketIndex == 1
    balanceBefore = environment.token["DAI"].balanceOf(accounts[0])
    environment.notional.batchLend(accounts[0], [(2, True, [encodedTrade])], {"from": accounts[0]})
    balanceAfter = environment.token["DAI"].balanceOf(accounts[0])

    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-9) == depositAmountUnderlying
    check_system_invariants(environment, accounts)


def test_convert_cash_balance_using_calculation_view(environment):
    assert environment.notional.convertCashBalanceToExternal(2, 5000e8, True) == 100e18
    assert environment.notional.convertCashBalanceToExternal(2, -5000e8, True) == -100e18
    assert environment.notional.convertCashBalanceToExternal(2, 5000e8, False) == 5000e8
    assert environment.notional.convertCashBalanceToExternal(2, -5000e8, False) == -5000e8

import brownie
import pytest
from brownie.convert.datatypes import HexString, Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.helpers import get_balance_action, get_trade_action, initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    env = initialize_environment(accounts)
    env.comptroller.enterMarkets(
        [env.cToken["DAI"].address, env.cToken["USDC"].address, env.cToken["ETH"].address],
        {"from": accounts[1]},
    )

    env.cToken["ETH"].mint({"from": accounts[1], "value": 10e18})
    env.cToken["DAI"].borrow(100e18, {"from": accounts[1]})
    env.cToken["USDC"].borrow(100e6, {"from": accounts[1]})

    env.ethOracle["DAI"].setAnswer(0.0001e18)
    env.ethOracle["USDC"].setAnswer(0.0001e18)

    env.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                2, "DepositUnderlyingAndMintNToken", depositActionAmount=100_000_000e18
            ),
            get_balance_action(
                3, "DepositUnderlyingAndMintNToken", depositActionAmount=100_000_000e6
            ),
        ],
        {"from": accounts[0]},
    )

    return env


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def upscale_precision(amount, currencyId, useUnderlying):
    if currencyId == 2 and useUnderlying:
        return Wei(amount * 1e18)
    elif currencyId == 2 and not useUnderlying:
        return Wei(amount * 49e8)
    elif currencyId == 3 and useUnderlying:
        return Wei(amount * 1e6)
    elif currencyId == 3 and not useUnderlying:
        return Wei(amount * 48e8)


def get_token(environment, currencyId, useUnderlying):
    if currencyId == 2 and useUnderlying:
        return environment.token["DAI"]
    elif currencyId == 2 and not useUnderlying:
        return environment.cToken["DAI"]
    elif currencyId == 3 and useUnderlying:
        return environment.token["USDC"]
    elif currencyId == 3 and not useUnderlying:
        return environment.cToken["USDC"]


def test_lend_borrow_reverts_on_rate_limit(environment):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    with brownie.reverts("Trade failed, slippage"):
        environment.notional.getfCashLendFromDeposit(2, 50000e8, maturity, 1e9, chain.time(), False)
        environment.notional.getPrincipalFromfCashBorrow(2, 1000e8, maturity, 1, chain.time())


@given(
    currencyId=strategy("uint", min_value=2, max_value=3),
    marketIndex=strategy("uint", min_value=1, max_value=2),
    useUnderlying=strategy("bool"),
    principal=strategy("uint", min_value=100, max_value=1_000_000),
)
def test_borrow_from_fcash_using_calculation_view(
    environment, accounts, currencyId, marketIndex, useUnderlying, principal
):
    maturity = environment.notional.getActiveMarkets(currencyId)[marketIndex - 1][1]
    principalAmount = upscale_precision(principal, currencyId, useUnderlying)

    maxSlippage = 1e9
    (fCash, marketIndex_, encodedTrade) = environment.notional.getfCashBorrowFromPrincipal(
        currencyId, principalAmount, maturity, maxSlippage, chain.time(), useUnderlying
    )

    assert marketIndex_ == marketIndex
    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Borrow",
            marketIndex=marketIndex,
            notional=fCash,
            maxSlippage=maxSlippage,
        ),
        type_str="bytes32",
    )
    environment.notional.batchBalanceAndTradeAction(
        accounts[3],
        [
            # Deposit sufficient collateral
            get_balance_action(1, "DepositUnderlying", depositActionAmount=500e18) + tuple([[]]),
            get_balance_action(
                currencyId, "None", withdrawEntireCashBalance=True, redeemToUnderlying=True
            )
            + tuple([[encodedTrade]]),
        ],
        {"from": accounts[3], "value": 500e18},
    )

    # Borrows must be in underlying post upgrade
    token = get_token(environment, currencyId, True)
    borrowedBalance = token.balanceOf(accounts[3])
    principalAmount = upscale_precision(principal, currencyId, True)
    assert pytest.approx(borrowedBalance, rel=1e-6, abs=1000) == principalAmount
    check_system_invariants(environment, accounts)


@given(
    currencyId=strategy("uint", min_value=2, max_value=3),
    marketIndex=strategy("uint", min_value=1, max_value=2),
    useUnderlying=strategy("bool"),
    deposit=strategy("uint", min_value=100, max_value=100_000),
)
def test_lend_from_fcash_asset_using_calculation_view(
    environment, accounts, currencyId, marketIndex, useUnderlying, deposit
):
    maturity = environment.notional.getActiveMarkets(currencyId)[marketIndex - 1][1]
    depositAmount = upscale_precision(deposit, currencyId, useUnderlying)

    (fCash, marketIndex_, encodedTrade) = environment.notional.getfCashLendFromDeposit(
        currencyId, depositAmount, maturity, 1, chain.time(), useUnderlying
    )

    assert marketIndex_ == marketIndex
    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Lend", marketIndex=marketIndex, notional=fCash, minSlippage=1
        ),
        type_str="bytes32",
    )

    token = get_token(environment, currencyId, useUnderlying)
    balanceBefore = token.balanceOf(accounts[0])
    environment.notional.batchLend(
        accounts[0], [(currencyId, useUnderlying, [encodedTrade])], {"from": accounts[0]}
    )
    balanceAfter = token.balanceOf(accounts[0])

    if useUnderlying:
        assert pytest.approx(balanceBefore - balanceAfter, rel=1e-8, abs=1000) == depositAmount
    # Don't check asset cash deposit amount since after the upgrade these are in prime cash
    check_system_invariants(environment, accounts)


@given(
    currencyId=strategy("uint", min_value=2, max_value=3),
    marketIndex=strategy("uint", min_value=1, max_value=2),
    fCash=strategy("uint", min_value=100e8, max_value=500_000e8),
)
def test_borrow_principal_using_calculation_view(
    environment, accounts, currencyId, marketIndex, fCash
):
    maturity = environment.notional.getActiveMarkets(currencyId)[marketIndex - 1][1]
    maxSlippage = 0.1e9
    (
        borrowAmountUnderlying,
        borrowAmountPrimeCash,
        marketIndex_,
        encodedTrade,
    ) = environment.notional.getPrincipalFromfCashBorrow(
        currencyId, fCash, maturity, maxSlippage, chain.time()
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
    assert marketIndex == marketIndex_
    environment.notional.batchBalanceAndTradeAction(
        accounts[3],
        [
            get_balance_action(1, "DepositUnderlying", depositActionAmount=100e18) + tuple([[]]),
            get_balance_action(
                currencyId, "None", withdrawEntireCashBalance=True, redeemToUnderlying=True
            )
            + tuple([[encodedTrade]]),
        ],
        {"from": accounts[3], "value": 100e18},
    )

    # Borrow amounts are always in underlying after the upgrade
    underlying = get_token(environment, currencyId, True)
    assert (
        pytest.approx(underlying.balanceOf(accounts[3]), rel=1e-8, abs=1000)
        == borrowAmountUnderlying
    )

    check_system_invariants(environment, accounts)


@given(
    currencyId=strategy("uint", min_value=2, max_value=3),
    marketIndex=strategy("uint", min_value=1, max_value=2),
    fCash=strategy("uint", min_value=100e8, max_value=500_000e8),
    useUnderlying=strategy("bool"),
)
def test_lend_asset_using_calculation_view(
    environment, accounts, currencyId, marketIndex, fCash, useUnderlying
):
    maturity = environment.notional.getActiveMarkets(currencyId)[marketIndex - 1][1]
    (
        depositAmountUnderlying,
        depositAmountPrimeCash,
        marketIndex_,
        encodedTrade,
    ) = environment.notional.getDepositFromfCashLend(currencyId, fCash, maturity, 0, chain.time())

    assert encodedTrade == HexString(
        get_trade_action(
            tradeActionType="Lend", marketIndex=marketIndex, notional=fCash, minSlippage=0
        ),
        type_str="bytes32",
    )
    assert marketIndex == marketIndex_

    token = get_token(environment, currencyId, useUnderlying)
    balanceBefore = token.balanceOf(accounts[0])
    environment.notional.batchLend(
        accounts[0], [(currencyId, useUnderlying, [encodedTrade])], {"from": accounts[0]}
    )
    balanceAfter = token.balanceOf(accounts[0])

    if useUnderlying:
        assert (
            pytest.approx(balanceBefore - balanceAfter, rel=1e-8, abs=1000)
            == depositAmountUnderlying
        )

    check_system_invariants(environment, accounts)


def test_convert_cash_balance_using_calculation_view(environment):
    assert (
        pytest.approx(environment.notional.convertCashBalanceToExternal(2, 4900e8, True), abs=1e13)
        == 100e18
    )
    assert (
        pytest.approx(environment.notional.convertCashBalanceToExternal(2, -4900e8, True), abs=1e13)
        == -100e18
    )

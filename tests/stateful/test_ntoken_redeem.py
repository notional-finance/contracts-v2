import brownie
import pytest
from brownie.exceptions import RPCRequestError
from brownie.network.state import Chain
from brownie.test import given, strategy
from scripts.config import CurrencyDefaults
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import (
    get_balance_action,
    get_balance_trade_action,
    initialize_environment,
    setup_residual_environment,
)
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


"""
Testing Matrix:

nToken State
1. cash, no liquid residuals, no ifCash residuals
2. no cash, no liquid residuals, no ifCash residuals
3. cash, no liquid residuals, negative ifCash residuals
4. no cash, no liquid residuals, negative ifCash residuals
5. cash, no liquid residuals, positive ifCash residuals
6. no cash, no liquid residuals, positive ifCash residuals

7. cash, liquid residuals (can't sell), no ifCash residuals
8. no cash, liquid residuals (can't sell), no ifCash residuals
9. cash, liquid residuals (can't sell), positive ifCash residuals
10. no cash, liquid residuals (can't sell), positive ifCash residuals
11. cash, liquid residuals (can't sell), negative ifCash residuals
12. no cash, liquid residuals (can't sell), negative ifCash residuals

13. cash, liquid residuals (can sell), no ifCash residuals
14. no cash, liquid residuals (can sell), no ifCash residuals
15. cash, liquid residuals (can sell), positive ifCash residuals
16. no cash, liquid residuals (can sell), positive ifCash residuals
17. cash, liquid residuals (can sell), negative ifCash residuals
18. no cash, liquid residuals (can sell), negative ifCash residuals

Results:
[User Option, State]
[(all), 1]: cash share
[(all), 2]: revert

1. batchBalance [True, False] sellfCash, no residuals
2. nTokenRedeem [True, False] sellfCash, no residuals
(3-6): cash share, tokens withdrawn
(7-12): revert
(13-18): cash share, tokens withdrawn, residuals sold

3. nTokenRedeem [False, False] keep fCash, no residuals
(3-6): cash only (discount)
(7-18): revert

4. nTokenRedeem [False, True] keep fCash, accept residuals
(3-18): cash, liquid fCash assets, ifCash assets (no discount)

5. nTokenRedeem [True, True] sellfCash, accept residuals
(3-6): cash, ifCash assets (no discount)
(7-12): cash, liquid fCash assets, ifCash assets (no discount)
(13-18): cash, ifCash assets (no discount)
"""


def test_redeem_tokens_and_sell_fcash(environment, accounts):
    currencyId = 2
    (
        cashBalanceBefore,
        perpTokenBalanceBefore,
        lastMintTimeBefore,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=300e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    marketsBefore = environment.notional.getActiveMarkets(currencyId)
    environment.notional.nTokenRedeem(
        accounts[0].address, currencyId, 1e8, True, False, {"from": accounts[0]}
    )
    marketsAfter = environment.notional.getActiveMarkets(currencyId)

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (cashBalanceAfter, perpTokenBalanceAfter, _) = environment.notional.getAccountBalance(
        currencyId, accounts[0]
    )

    # Assert that no assets in portfolio
    assert len(environment.notional.getAccountPortfolio(accounts[0])) == 0

    # assert decrease in market liquidity
    assert len(marketsBefore) == len(marketsAfter)
    for (i, m) in enumerate(marketsBefore):
        assert m[4] > marketsAfter[i][4]

    assert cashBalanceAfter > cashBalanceBefore
    assert perpTokenBalanceAfter == perpTokenBalanceBefore - 1e8

    check_system_invariants(environment, accounts)


def test_redeem_tokens_and_save_assets_portfolio(environment, accounts):
    currencyId = 2
    (
        cashBalanceBefore,
        perpTokenBalanceBefore,
        lastMintTimeBefore,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])

    totalSupplyBefore = environment.nToken[currencyId].totalSupply()

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=300e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    marketsBefore = environment.notional.getActiveMarkets(currencyId)
    environment.notional.nTokenRedeem(
        accounts[0].address, currencyId, 1e8, False, True, {"from": accounts[0]}
    )
    marketsAfter = environment.notional.getActiveMarkets(currencyId)

    (cashBalanceAfter, perpTokenBalanceAfter, _) = environment.notional.getAccountBalance(
        currencyId, accounts[0]
    )
    totalSupplyAfter = environment.nToken[currencyId].totalSupply()

    portfolio = environment.notional.getAccountPortfolio(accounts[0])
    for asset in portfolio:
        # Should be a net borrower because of lending
        assert asset[3] < 0

    # assert decrease in market liquidity
    assert len(marketsBefore) == len(marketsAfter)
    for (i, m) in enumerate(marketsBefore):
        assert m[4] > marketsAfter[i][4]

    # Some cash claim withdrawn
    assert cashBalanceAfter > cashBalanceBefore
    assert perpTokenBalanceAfter == perpTokenBalanceBefore - 1e8
    assert totalSupplyBefore - totalSupplyAfter == 1e8

    check_system_invariants(environment, accounts)


def test_redeem_tokens_and_save_assets_settle(environment, accounts):
    currencyId = 2
    (
        cashBalanceBefore,
        perpTokenBalanceBefore,
        lastMintTimeBefore,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 10e8, "maxSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=300e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    environment.nToken[currencyId].transfer(accounts[1], 10e8, {"from": accounts[0]})

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    # This account has a matured borrow fCash
    txn = environment.notional.nTokenRedeem(
        accounts[1].address, currencyId, 1e8, False, True, {"from": accounts[1]}
    )
    assert txn.events["AccountSettled"]
    context = environment.notional.getAccountContext(accounts[1])
    assert context[1] == "0x02"

    check_system_invariants(environment, accounts)


def test_redeem_tokens_and_save_assets_bitmap(environment, accounts):
    currencyId = 2
    (
        cashBalanceBefore,
        perpTokenBalanceBefore,
        lastMintTimeBefore,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 10e8, "maxSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=300e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.enableBitmapCurrency(currencyId, {"from": accounts[1]})
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    portfolioBefore = environment.notional.getAccountPortfolio(accounts[1])

    environment.nToken[currencyId].transfer(accounts[1], 10e8, {"from": accounts[0]})

    # This account has a matured borrow fCash
    environment.notional.nTokenRedeem(
        accounts[1].address, currencyId, 1e8, False, True, {"from": accounts[1]}
    )
    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 2
    assert portfolio[0][1] == portfolioBefore[0][1]
    assert portfolio[0][3] > portfolioBefore[0][3]
    assert portfolio[1][1] == portfolioBefore[1][1]
    assert portfolio[1][3] < portfolioBefore[1][3]

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_batch_balance_action(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    redeemAmount = 1_000_000e8
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )
    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (_, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], redeemAmount, {"from": accounts[0]})
    portfolio = environment.notional.getAccountPortfolio(accounts[2])
    assert len(portfolio) == 0

    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()
    action = get_balance_action(2, "RedeemNToken", depositActionAmount=redeemAmount)

    if not canSellResiduals and marketResiduals:
        try:
            environment.notional.nTokenRedeem(
                accounts[2].address, currencyId, redeemAmount, True, False, {"from": accounts[2]}
            )
            assert False
        except RPCRequestError:
            # This is how we detect a revert when Ganache throws an Invalid String Length error
            pass
    else:
        environment.notional.batchBalanceAction(
            accounts[2].address, [action], {"from": accounts[2]}
        )

    # Account should have redeemed around the ifCash residual
    portfolio = environment.notional.getAccountPortfolio(accounts[2])
    assert len(portfolio) == 0

    # Test for PV of account[2] assets relative to redeem
    (cash, _, _) = environment.notional.getAccountBalance(2, accounts[2])
    cashRatio = cash / nTokenPV
    supplyRatio = redeemAmount / totalSupply

    if residualType == 0 and not marketResiduals:
        # In this scenario (with no residuals anywhere) valuation is at par
        assert cashRatio == supplyRatio
    else:
        assert cashRatio < supplyRatio

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_sell_fcash_no_residuals(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    redeemAmount = 1_000_000e8
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )
    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (_, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], redeemAmount, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0

    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()

    if not canSellResiduals and marketResiduals:
        # If residual sales fail then this must revert
        try:
            environment.notional.nTokenRedeem(
                accounts[2].address, currencyId, redeemAmount, True, False, {"from": accounts[2]}
            )
            assert False
        except RPCRequestError:
            # This is how we detect a revert when Ganache throws an Invalid String Length error
            pass
    else:
        environment.notional.nTokenRedeem(
            accounts[2].address, currencyId, redeemAmount, True, False, {"from": accounts[2]}
        )

    # Account should have redeemed around the ifCash residual
    portfolio = environment.notional.getAccountPortfolio(accounts[2])
    assert len(portfolio) == 0

    # Test for PV of account[2] assets relative to redeem
    (cash, _, _) = environment.notional.getAccountBalance(2, accounts[2])
    cashRatio = cash / nTokenPV
    supplyRatio = redeemAmount / totalSupply

    if residualType == 0 and not marketResiduals:
        # In this scenario (with no residuals anywhere) valuation is at par
        assert cashRatio == supplyRatio
    else:
        assert cashRatio < supplyRatio

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_keep_assets_no_residuals(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )
    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (_, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], 50_000e8, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0

    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()

    if not marketResiduals:
        environment.notional.nTokenRedeem(
            accounts[2].address, currencyId, 50_000e8, False, False, {"from": accounts[2]}
        )

        # Should have fCash assets for each liquid market
        portfolio = environment.notional.getAccountPortfolio(accounts[2])
        assert len(portfolio) == 0

        (cash, _, _) = environment.notional.getAccountBalance(2, accounts[2])
        cashRatio = cash / nTokenPV
        supplyRatio = 50000e8 / totalSupply

        if residualType == 0:
            # In this scenario (with no residuals anywhere) valuation is at par
            assert cashRatio == supplyRatio
        else:
            assert cashRatio < supplyRatio
    else:
        # If there are any market residuals this version will fail
        with brownie.reverts("Residuals"):
            environment.notional.nTokenRedeem(
                accounts[2].address, currencyId, 50_000e8, False, False, {"from": accounts[2]}
            )

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_keep_assets_accept_residuals(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )
    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (_, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], 50_000e8, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0
    blockTime = chain.time()
    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()

    environment.notional.nTokenRedeem(
        accounts[2].address, currencyId, 50_000e8, False, True, {"from": accounts[2]}
    )

    # Should have fCash assets for each liquid market and the ifCash asset
    portfolio = environment.notional.getAccountPortfolio(accounts[2])

    if residualType == 0:
        if marketResiduals:
            assert len(portfolio) == 3
            assert portfolio[0][1] == ifCashAssets[0][1]
            assert portfolio[1][1] == ifCashAssets[1][1]
            assert portfolio[2][1] == ifCashAssets[2][1]
        else:
            assert len(portfolio) == 0
    else:
        if marketResiduals:
            assert len(portfolio) == 4
            assert portfolio[0][1] == ifCashAssets[0][1]
            assert portfolio[1][1] == ifCashAssets[1][1]
            assert portfolio[2][1] == ifCashAssets[2][1]
            assert portfolio[3][1] == ifCashAssets[3][1]
        else:
            # Only the ifCash asset here
            # We can get off by one errors here due to the nature of the
            # calculation when we approximate the fCashClaim & netfCash
            if len(portfolio) > 1:
                # Filter out anything that is dust
                portfolio = list(filter(lambda x: abs(x[3]) > 1, portfolio))

            assert len(portfolio) == 1
            assert portfolio[0][1] == ifCashAssets[2][1]

    (valuation, _, _) = environment.notional.getAccountBalance(2, accounts[2])
    for a in portfolio:
        # This is in asset cash terms
        valuation += environment.notional.getPresentfCashValue(2, a[1], a[3], blockTime, False) * 50
    valuationRatio = valuation / nTokenPV
    supplyRatio = 50000e8 / totalSupply

    # assert that valuation is par to the nToken PV
    assert pytest.approx(valuationRatio, abs=100) == supplyRatio

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_sell_assets_accept_residuals(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )
    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (_, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], 1_000_000e8, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0
    blockTime = chain.time()
    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()

    environment.notional.nTokenRedeem(
        accounts[2].address, currencyId, 1_000_000e8, True, True, {"from": accounts[2]}
    )

    portfolio = environment.notional.getAccountPortfolio(accounts[2])

    (valuation, _, _) = environment.notional.getAccountBalance(2, accounts[2])
    for a in portfolio:
        # This is in asset cash terms
        valuation += environment.notional.getPresentfCashValue(2, a[1], a[3], blockTime, False) * 50
    valuationRatio = valuation / nTokenPV
    supplyRatio = 1_000_000e8 / totalSupply

    if residualType == 0:
        if not marketResiduals or canSellResiduals:
            # No ifCash residuals so no assets
            assert len(portfolio) == 0
        else:
            # Some fCash residuals sold but not all
            assert len(portfolio) > 0 and len(portfolio) < 4
            # No ifCash assets in portfolio
            assert len(list(filter(lambda x: x[1] == ifCashAssets[2][1], portfolio))) == 0
    else:
        if not marketResiduals or canSellResiduals:
            # We can get off by one errors here due to the nature of the
            # calculation when we approximate the fCashClaim & netfCash
            if len(portfolio) > 1:
                # Filter out anything that is dust
                portfolio = list(filter(lambda x: abs(x[3]) > 1, portfolio))

            # Only the ifCash asset is in the portfolio
            assert len(portfolio) == 1
            assert portfolio[0][1] == ifCashAssets[2][1]
        else:
            # Some fCash residuals sold but not all
            assert len(portfolio) > 0 and len(portfolio) <= 4
            # Holding ifCash assets in portfolio
            assert len(list(filter(lambda x: x[1] == ifCashAssets[2][1], portfolio))) == 1

    if marketResiduals and canSellResiduals:
        assert valuationRatio < supplyRatio
    else:
        assert pytest.approx(valuationRatio, abs=100) == supplyRatio

    check_system_invariants(environment, accounts)


def test_redeem_tokens_and_sell_fcash_zero_notional(environment, accounts):
    # This unit test is here to test a bug where markets were skipped during the sellfCash portion
    # of redeeming nTokens
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the two year markets
    cashGroup[0] = 4
    cashGroup[9] = CurrencyDefaults["tokenHaircut"][0:4]
    cashGroup[10] = CurrencyDefaults["rateScalar"][0:4]
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.2e8, 0.2e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInitializationParameters(
        currencyId, [0.01e9, 0.021e9, 0.07e9, 0.08e9], [0.5e9, 0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=10e18)
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            # This leaves a positive residual
            {"tradeActionType": "Borrow", "marketIndex": 3, "notional": 1e4, "maxSlippage": 0},
            # This leaves a negative residual
            {"tradeActionType": "Lend", "marketIndex": 4, "notional": 1e4, "minSlippage": 0},
        ],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral, action], {"from": accounts[1], "value": 10e18}
    )

    # Now settle the markets, should be some residual
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # Leaves some more residual
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 3, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 4, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=500e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral, action], {"from": accounts[1], "value": 10e18}
    )

    # Need to ensure that no residual assets are left behind
    assert len(environment.notional.getAccountPortfolio(accounts[0])) == 0
    environment.notional.nTokenRedeem(
        accounts[0].address, currencyId, 1e8, True, False, {"from": accounts[0]}
    )

    assert len(environment.notional.getAccountPortfolio(accounts[0])) == 0
    check_system_invariants(environment, accounts)

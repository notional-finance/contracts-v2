import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from tests.constants import RATE_PRECISION, SECONDS_IN_DAY, SECONDS_IN_QUARTER
from tests.helpers import get_balance_action, get_balance_trade_action, initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def get_market_proportion(currencyId, environment):
    proportions = []
    (cashGroup, assetRate) = environment.notional.getCashGroupAndRate(currencyId)
    markets = environment.notional.getActiveMarkets(currencyId)
    for (i, market) in enumerate(markets):
        totalCashUnderlying = (market[3] * Wei(1e8) * assetRate[1]) / (assetRate[2] * Wei(1e18))
        proportion = int(market[2] * RATE_PRECISION / (totalCashUnderlying + market[2]))
        proportions.append(proportion)

    return proportions


def test_deleverage_markets_no_lend(environment, accounts):
    # Lending does not succeed when markets are over levered, cash goes into cash balance
    currencyId = 2
    environment.notional.updatePerpetualDepositParameters(
        currencyId, [0.4e8, 0.6e8], [0.4e9, 0.4e9]
    )

    perpTokenAddress = environment.notional.getPerpetualTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    marketsBefore = environment.notional.getActiveMarkets(currencyId)
    totalSupplyBefore = environment.perpToken[currencyId].totalSupply()

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId, "DepositAssetAndMintPerpetual", depositActionAmount=100000e8
            )
        ],
        {"from": accounts[0]},
    )

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    balanceAfter = environment.notional.getAccountBalance(currencyId, perpTokenAddress)
    marketsAfter = environment.notional.getActiveMarkets(currencyId)
    reserveBalance = environment.notional.getReserveBalance(currencyId)
    totalSupplyAfter = environment.perpToken[currencyId].totalSupply()

    assert portfolioBefore == portfolioAfter
    assert ifCashAssetsBefore == ifCashAssetsAfter
    assert balanceAfter[0] == 100000e8
    assert marketsBefore == marketsAfter
    assert reserveBalance == 0
    assert totalSupplyBefore + 100000e8 == totalSupplyAfter

    check_system_invariants(environment, accounts)


def test_deleverage_markets_lend(environment, accounts):
    # Lending does not succeed when markets are over levered, cash goes into cash balance
    currencyId = 2
    environment.notional.updatePerpetualDepositParameters(
        currencyId, [0.4e8, 0.6e8], [0.4e9, 0.4e9]
    )

    perpTokenAddress = environment.notional.getPerpetualTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    totalSupplyBefore = environment.perpToken[currencyId].totalSupply()
    marketProportionsBefore = get_market_proportion(currencyId, environment)

    environment.notional.batchBalanceAction(
        accounts[0],
        [get_balance_action(currencyId, "DepositAssetAndMintPerpetual", depositActionAmount=100e8)],
        {"from": accounts[0]},
    )

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    balanceAfter = environment.notional.getAccountBalance(currencyId, perpTokenAddress)
    reserveBalance = environment.notional.getReserveBalance(currencyId)
    totalSupplyAfter = environment.perpToken[currencyId].totalSupply()
    marketProportionsAfter = get_market_proportion(currencyId, environment)

    assert portfolioBefore == portfolioAfter

    for (assetBefore, assetAfter) in zip(ifCashAssetsBefore, ifCashAssetsAfter):
        assert assetBefore[3] < assetAfter[3]

    for (proportionBefore, proportionAfter) in zip(marketProportionsBefore, marketProportionsAfter):
        assert proportionBefore > proportionAfter

    # Minimum residual left
    assert balanceAfter[0] < 1e8
    assert reserveBalance > 0
    assert totalSupplyBefore + 100e8 == totalSupplyAfter

    check_system_invariants(environment, accounts)


def test_deleverage_markets_lend_and_provide(environment, accounts):
    # Lending does not succeed when markets are over levered, cash goes into cash balance
    currencyId = 2
    environment.notional.updatePerpetualDepositParameters(
        currencyId, [0.4e8, 0.6e8], [0.49e9, 0.49e9]
    )

    perpTokenAddress = environment.notional.getPerpetualTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    totalSupplyBefore = environment.perpToken[currencyId].totalSupply()
    marketProportionsBefore = get_market_proportion(currencyId, environment)

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId, "DepositAssetAndMintPerpetual", depositActionAmount=5000e8
            )
        ],
        {"from": accounts[0]},
    )

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    balanceAfter = environment.notional.getAccountBalance(currencyId, perpTokenAddress)
    reserveBalance = environment.notional.getReserveBalance(currencyId)
    totalSupplyAfter = environment.perpToken[currencyId].totalSupply()
    marketProportionsAfter = get_market_proportion(currencyId, environment)

    for (assetBefore, assetAfter) in zip(portfolioBefore, portfolioAfter):
        assert assetBefore[3] < assetAfter[3]

    for (assetBefore, assetAfter) in zip(ifCashAssetsBefore, ifCashAssetsAfter):
        assert assetBefore[3] < assetAfter[3]

    for (proportionBefore, proportionAfter) in zip(marketProportionsBefore, marketProportionsAfter):
        assert proportionBefore > proportionAfter

    # No residual left
    assert balanceAfter[0] == 0
    assert reserveBalance > 0
    assert totalSupplyBefore + 5000e8 == totalSupplyAfter

    check_system_invariants(environment, accounts)


def test_redeem_tokens_and_sell_fcash(environment, accounts):
    currencyId = 2
    (
        cashBalanceBefore,
        perpTokenBalanceBefore,
        lastMintTimeBefore,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])

    perpTokenAddress = environment.notional.getPerpetualTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )

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
    environment.notional.perpetualTokenRedeem(currencyId, 1e8, True, {"from": accounts[0]})
    marketsAfter = environment.notional.getActiveMarkets(currencyId)

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    (
        cashBalanceAfter,
        perpTokenBalanceAfter,
        lastMintTimeAfter,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])

    # Assert that no assets in portfolio
    assert len(environment.notional.getAccountPortfolio(accounts[0])) == 0

    # assert decrease in market liquidity
    assert len(marketsBefore) == len(marketsAfter)
    for (i, m) in enumerate(marketsBefore):
        assert m[4] > marketsAfter[i][4]

    assert cashBalanceAfter > cashBalanceBefore
    assert perpTokenBalanceAfter == perpTokenBalanceBefore - 1e8
    assert lastMintTimeAfter > lastMintTimeBefore

    check_system_invariants(environment, accounts)


def test_redeem_tokens_and_save_assets_portfolio(environment, accounts):
    currencyId = 2
    (
        cashBalanceBefore,
        perpTokenBalanceBefore,
        lastMintTimeBefore,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])

    # perpTokenAddress = environment.notional.getPerpetualTokenAddress(currencyId)
    totalSupplyBefore = environment.perpToken[currencyId].totalSupply()

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
    environment.notional.perpetualTokenRedeem(currencyId, 1e8, False, {"from": accounts[0]})
    marketsAfter = environment.notional.getActiveMarkets(currencyId)

    (
        cashBalanceAfter,
        perpTokenBalanceAfter,
        lastMintTimeAfter,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])
    totalSupplyAfter = environment.perpToken[currencyId].totalSupply()

    # Assert that no assets in portfolio
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
    assert lastMintTimeAfter > lastMintTimeBefore
    assert totalSupplyBefore - totalSupplyAfter == 1e8

    check_system_invariants(environment, accounts)


def test_redeem_tokens_and_save_assets_bitmap(environment, accounts):
    # TODO: activate bitmap portfolio
    pass


def test_purchase_perp_token_residual_negative(environment, accounts):
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the one year market
    cashGroup[0] = 3
    cashGroup[8] = CurrencyDefaults["tokenHaircut"][0:3]
    cashGroup[9] = CurrencyDefaults["rateScalar"][0:3]
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updatePerpetualDepositParameters(
        currencyId, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInitializationParameters(
        currencyId, [1.01e9, 1.021e9, 1.07e9], [0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    # Do some trading to leave some perp token residual
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 3, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    # Now settle the markets, should be some residual
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    perpTokenAddress = environment.notional.getPerpetualTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    (cashBalanceBefore, _, _) = environment.notional.getAccountBalance(currencyId, perpTokenAddress)

    with brownie.reverts("Insufficient block time"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchasePerpetualTokenResidual",
                    "maturity": ifCashAssetsBefore[2][1],
                    "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    with brownie.reverts("Invalid maturity"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchasePerpetualTokenResidual",
                    "maturity": ifCashAssetsBefore[1][1],
                    "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    blockTime = chain.time()
    # 96 hour buffer period
    chain.mine(1, timestamp=blockTime + 96 * 3600)

    with brownie.reverts("Invalid amount"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchasePerpetualTokenResidual",
                    "maturity": ifCashAssetsBefore[2][1],
                    "fCashAmountToPurchase": 100e8,
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    action = get_balance_trade_action(
        2,
        "None",
        [
            {
                "tradeActionType": "PurchasePerpetualTokenResidual",
                "maturity": ifCashAssetsBefore[2][1],
                "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
            }
        ],
    )
    environment.notional.batchBalanceAndTradeAction(accounts[2], [action], {"from": accounts[2]})

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    (cashBalanceAfter, _, _) = environment.notional.getAccountBalance(currencyId, perpTokenAddress)
    (accountCashBalance, _, _) = environment.notional.getAccountBalance(currencyId, accounts[2])
    accountPortfolio = environment.notional.getAccountPortfolio(accounts[2])

    assert portfolioAfter == portfolioBefore
    assert accountCashBalance == cashBalanceBefore - cashBalanceAfter
    assert accountPortfolio[0][0:3] == ifCashAssetsBefore[2][0:3]
    assert len(ifCashAssetsAfter) == 3

    check_system_invariants(environment, accounts)


def test_purchase_perp_token_residual_positive(environment, accounts):
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the one year market
    cashGroup[0] = 3
    cashGroup[8] = CurrencyDefaults["tokenHaircut"][0:3]
    cashGroup[9] = CurrencyDefaults["rateScalar"][0:3]
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updatePerpetualDepositParameters(
        currencyId, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInitializationParameters(
        currencyId, [1.01e9, 1.021e9, 1.07e9], [0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    # Do some trading to leave some perp token residual
    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=10e18)

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
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

    perpTokenAddress = environment.notional.getPerpetualTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    (cashBalanceBefore, _, _) = environment.notional.getAccountBalance(currencyId, perpTokenAddress)

    blockTime = chain.time()
    # 96 hour buffer period
    chain.mine(1, timestamp=blockTime + 96 * 3600)

    with brownie.reverts("Invalid amount"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchasePerpetualTokenResidual",
                    "maturity": ifCashAssetsBefore[2][1],
                    "fCashAmountToPurchase": -100e8,
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    with brownie.reverts("Insufficient cash"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchasePerpetualTokenResidual",
                    "maturity": ifCashAssetsBefore[2][1],
                    "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    # Use a different account
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "PurchasePerpetualTokenResidual",
                "maturity": ifCashAssetsBefore[2][1],
                "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
            }
        ],
        depositActionAmount=5500e8,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[0], [action], {"from": accounts[0]})

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getPerpetualTokenPortfolio(
        perpTokenAddress
    )
    (cashBalanceAfter, _, _) = environment.notional.getAccountBalance(currencyId, perpTokenAddress)
    (accountCashBalance, _, _) = environment.notional.getAccountBalance(currencyId, accounts[0])
    accountPortfolio = environment.notional.getAccountPortfolio(accounts[0])

    assert portfolioAfter == portfolioBefore
    assert 5500e8 - accountCashBalance == cashBalanceAfter
    assert accountPortfolio[0][0:3] == ifCashAssetsBefore[2][0:3]
    assert len(ifCashAssetsAfter) == 3

    check_system_invariants(environment, accounts)


def test_transfer_tokens(environment, accounts):
    currencyId = 2
    totalSupplyBefore = environment.perpToken[currencyId].totalSupply()
    assert totalSupplyBefore == environment.perpToken[currencyId].balanceOf(accounts[0])
    (_, _, accountOneLastMintTime) = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert accountOneLastMintTime == 0

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + 10 * SECONDS_IN_DAY)
    txn = environment.perpToken[currencyId].transfer(accounts[1], 100e8)

    assert environment.perpToken[currencyId].totalSupply() == totalSupplyBefore
    assert environment.perpToken[currencyId].balanceOf(accounts[1]) == 100e8
    assert environment.perpToken[currencyId].balanceOf(accounts[0]) == totalSupplyBefore - 100e8
    assert environment.noteERC20.balanceOf(accounts[0]) > 0
    assert environment.noteERC20.balanceOf(accounts[1]) == 0

    (_, _, mintTimeAfterZero) = environment.notional.getAccountBalance(currencyId, accounts[0])
    (_, _, mintTimeAfterOne) = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert mintTimeAfterOne == mintTimeAfterZero == txn.timestamp

    check_system_invariants(environment, accounts)


def test_mint_incentives(environment, accounts):
    currencyId = 2
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + 10 * SECONDS_IN_DAY)
    txn = environment.perpToken[currencyId].mintIncentives(accounts[0])
    balanceBefore = environment.noteERC20.balanceOf(accounts[0])
    assert balanceBefore > 0

    (_, _, mintTimeAfterZero) = environment.notional.getAccountBalance(currencyId, accounts[0])
    assert mintTimeAfterZero == txn.timestamp

    environment.perpToken[currencyId].mintIncentives(accounts[0])
    assert environment.noteERC20.balanceOf(accounts[0]) == balanceBefore

    check_system_invariants(environment, accounts)

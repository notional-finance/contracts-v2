import brownie
import pytest
from brownie.network.state import Chain
from tests.constants import SETTLEMENT_DATE, START_TIME
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_eth_rate_mapping,
    get_fcash_token,
    get_market_curve,
)

chain = Chain()
LIQUIDATION_BUFFER = 1.01e18


@pytest.fixture(scope="module", autouse=True)
def ethAggregators(MockAggregator, accounts):
    return [
        MockAggregator.deploy(18, {"from": accounts[0]}),
        MockAggregator.deploy(18, {"from": accounts[0]}),
        MockAggregator.deploy(18, {"from": accounts[0]}),
    ]


@pytest.fixture(scope="module", autouse=True)
def liquidation(MockLiquidation, MockCToken, cTokenAggregator, ethAggregators, accounts):
    liq = accounts[0].deploy(MockLiquidation)
    ctoken = accounts[0].deploy(MockCToken, 8)
    # This is the identity rate
    ctoken.setAnswer(1e18)
    aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})

    rateStorage = (aggregator.address, 8)
    liq.setAssetRateMapping(1, rateStorage)
    cg = get_cash_group_with_max_markets(3)
    liq.setCashGroup(1, cg)
    ethAggregators[0].setAnswer(1e18)
    liq.setETHRateMapping(1, get_eth_rate_mapping(ethAggregators[0], discount=104))

    liq.setAssetRateMapping(2, rateStorage)
    liq.setCashGroup(2, cg)
    ethAggregators[1].setAnswer(1e18)
    liq.setETHRateMapping(2, get_eth_rate_mapping(ethAggregators[1], discount=102))

    liq.setAssetRateMapping(3, rateStorage)
    liq.setCashGroup(3, cg)
    ethAggregators[2].setAnswer(1e18)
    liq.setETHRateMapping(3, get_eth_rate_mapping(ethAggregators[2], discount=105))

    chain.mine(1, timestamp=START_TIME)

    return liq


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_revert_on_sufficient_collateral(liquidation, accounts):
    liquidation.setBalance(accounts[0], 1, 100e8, 0)

    with brownie.reverts("L: sufficient free collateral"):
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2)

    with brownie.reverts("L: sufficient free collateral"):
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 2, 1)

    with brownie.reverts("L: sufficient free collateral"):
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 3, 2)


def test_revert_on_sufficient_portfolio_value(liquidation, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    liquidation.setPortfolio(accounts[0], [get_fcash_token(1, notional=100e8)])

    with brownie.reverts("L: sufficient free collateral"):
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2)

    with brownie.reverts("L: sufficient free collateral"):
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 2, 1)

    with brownie.reverts("L: sufficient free collateral"):
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 3, 2)


def test_revert_on_invalid_currencies(liquidation, accounts):
    with brownie.reverts():
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 1)

    with brownie.reverts():
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 0)

    with brownie.reverts():
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 0, 1)

    with brownie.reverts():
        liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 0, 0)


def test_has_no_collateral_fcash(liquidation, accounts):
    liquidation.setBalance(accounts[0], 1, -1000e8, 0)
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    liquidation.setPortfolio(accounts[0], [get_fcash_token(1, notional=100e8)])
    factors = liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2).return_value

    # only has fCash at this point
    assert not factors[-1]


def test_has_no_collateral_insolvent(liquidation, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    liquidation.setPortfolio(accounts[0], [get_fcash_token(1, notional=-100e8)])
    factors = liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2).return_value

    # is insolvent
    assert not factors[-1]


def test_has_collateral(liquidation, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)
    liquidation.setPortfolio(accounts[0], [get_fcash_token(1, notional=-100e8)])
    liquidation.setBalance(accounts[0], 3, 100e8, 0)

    factors = liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 3).return_value
    # has collateral balance
    assert factors[-1]


def test_asset_factors_local_and_collateral(liquidation, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    liquidation.setPortfolio(accounts[0], [get_fcash_token(1, notional=-100e8)])
    liquidation.setBalance(accounts[0], 3, 100e8, 0)

    factors = liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 3).return_value

    assert factors[1] > -100e8 and factors[1] < -99e8
    assert pytest.approx(factors[0], abs=2) == -int(((factors[1] * 1.40) + 100e8) * 1.01)
    assert factors[2] == 100e8


def test_asset_factors_local_only(liquidation, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    liquidation.setPortfolio(accounts[0], [get_fcash_token(1, notional=-100e8)])
    liquidation.setBalance(accounts[0], 1, 10e8, 0)

    factors = liquidation.calculateLiquidationFactors(accounts[0], START_TIME, 1, 3).return_value

    assert factors[1] > -90e8 and factors[1] < -89e8
    assert pytest.approx(factors[0], abs=2) == -int((factors[1] * 1.40) * 1.01)
    assert factors[2] == 0


# def test_liquidate_tokens(liquidation, ethAggregators, assetRateAggregator, accounts):
#     setup_markets(liquidation)
#     config = ((1, 1, 90), (2, 1, 90))
#     (cashGroups, marketStates) = get_cash_groups_and_market_states(config)

#     # This should be a function #
#     balanceStates = ((1, 0, 0, 0, 0, 0), (2, 0.7e18, 0, 0, 0, 0))
#     netPortfolioValue = [-1e18, 0]
#     factors = liquidation.getLiquidationFactors(
#         1, 2, balanceStates, tuple(cashGroups), tuple(marketStates), tuple(netPortfolioValue)
#     )
#     # This should be a function #

#     portfolioState = (
#         [
#             # TODO: generate random token stuff
#             (1, MARKETS[0], 2, 0.1e18, 0)
#         ],
#         (),
#         0,
#         1,
#         (),
#     )

#     # assetCash     = 100000000000000000
#     # fCash         = 100000000000000000
#     # totalCashOut  = 909090909090909
#     # cashToAccount = 818181818181818

#     (
#         incentivePaid,
#         localAssetRequired,
#         newBalanceContext,
#         newPortfolioState,
#         newMarketStates,
#     ) = liquidation.liquidateLocalLiquidityTokens(
#         factors, START_TIME, balanceStates[0], portfolioState
#     )

#     # assert that the balance transfers net out to what was required when entering the function
#     totalCashClaim = newBalanceContext[3] + incentivePaid

#     # TODO: assert that market has updated properly
#     # fCash amounts net off
#     assert newMarketStates[0][2] + newPortfolioState[1][0][3] == 1e18
#     # asset amounts net off
#     assert newMarketStates[0][3] + totalCashClaim == 1e18
#     # total liquidity amounts net off
#     assert newMarketStates[0][3] + portfolioState[0][0][3] == 1e18

#     # haircut amount - incentive = localAssetRequired change
#     assert factors[0] >= localAssetRequired
#     assert factors[0] - localAssetRequired == (
#         (newBalanceContext[3] + incentivePaid) * (100 - 90) / 100 - incentivePaid
#     )


# def test_liquidate_collateral(liquidation, ethAggregators, assetRateAggregator, accounts):
#     setup_markets(liquidation)
#     config = ((1, 1, 97), (2, 1, 97))
#     (cashGroups, marketStates) = get_cash_groups_and_market_states(config)

#     balanceStates = ((1, 0, 0, 0, 0, 0), (2, 0.7e18, 0, 0, 0, 0))
#     portfolioState = ([(2, MARKETS[0], 2, 0.1e18, 0)], (), 0, 1, ())
#     netPortfolioValue = [-1e18, 0]

#     factors = liquidation.getLiquidationFactors(
#         1, 2, balanceStates, tuple(cashGroups), tuple(marketStates), tuple(netPortfolioValue)
#     )

#     (localToPurchase, newCollateralBalance, newPortfolioState) = liquidation.liquidateCollateral(
#         factors, balanceStates[1], portfolioState, 0, START_TIME
#     )

#     assert False

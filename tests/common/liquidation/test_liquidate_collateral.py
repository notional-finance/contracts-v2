import math

import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import SETTLEMENT_DATE, START_TIME
from tests.helpers import (
    get_balance_state,
    get_cash_group_with_max_markets,
    get_eth_rate_mapping,
    get_fcash_token,
    get_liquidity_token,
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
def liquidationFixtures(
    MockLiquidateTokens,
    MockLiquidateCollateral,
    MockCToken,
    cTokenAggregator,
    ethAggregators,
    accounts,
):
    liquidateTokens = accounts[0].deploy(MockLiquidateTokens)
    liquidateCollateral = accounts[0].deploy(MockLiquidateCollateral)
    ctoken = accounts[0].deploy(MockCToken, 8)
    # This is the identity rate
    ctoken.setAnswer(1e18)
    aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})

    cg = get_cash_group_with_max_markets(3)
    rateStorage = (aggregator.address, 8)

    ethAggregators[0].setAnswer(1e18)
    liquidateTokens.setAssetRateMapping(1, rateStorage)
    liquidateTokens.setCashGroup(1, cg)
    liquidateTokens.setETHRateMapping(1, get_eth_rate_mapping(ethAggregators[0], discount=104))
    liquidateCollateral.setAssetRateMapping(1, rateStorage)
    liquidateCollateral.setCashGroup(1, cg)
    liquidateCollateral.setETHRateMapping(1, get_eth_rate_mapping(ethAggregators[0], discount=104))

    ethAggregators[1].setAnswer(1e18)
    liquidateTokens.setAssetRateMapping(2, rateStorage)
    liquidateTokens.setCashGroup(2, cg)
    liquidateTokens.setETHRateMapping(2, get_eth_rate_mapping(ethAggregators[1], discount=102))
    liquidateCollateral.setAssetRateMapping(2, rateStorage)
    liquidateCollateral.setCashGroup(2, cg)
    liquidateCollateral.setETHRateMapping(2, get_eth_rate_mapping(ethAggregators[1], discount=102))

    ethAggregators[2].setAnswer(1e18)
    liquidateTokens.setAssetRateMapping(3, rateStorage)
    liquidateTokens.setCashGroup(3, cg)
    liquidateTokens.setETHRateMapping(3, get_eth_rate_mapping(ethAggregators[2], discount=105))
    liquidateCollateral.setAssetRateMapping(3, rateStorage)
    liquidateCollateral.setCashGroup(3, cg)
    liquidateCollateral.setETHRateMapping(3, get_eth_rate_mapping(ethAggregators[2], discount=105))

    chain.mine(1, timestamp=START_TIME)

    return (liquidateTokens, liquidateCollateral)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


# Test calculations
def test_calculate_token_cash_claims(liquidationFixtures, accounts):
    (_, liquidation) = liquidationFixtures
    (cashGroup, markets) = liquidation.buildCashGroupView(1)

    markets = get_market_curve(3, "flat")
    for i, m in enumerate(markets):
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    # FCash token only
    portfolioState = ([get_fcash_token(1)], [], 0, 1, [])

    (totalAssetCash, totalHaircutAssetCash) = liquidation.calculateTokenCashClaims(
        portfolioState, cashGroup, markets, START_TIME
    )
    assert totalAssetCash == 0
    assert totalHaircutAssetCash == 0

    liquidityTokenNotional = 1000e8
    portfolioState = (
        [
            get_liquidity_token(
                1, notional=liquidityTokenNotional, storageState=2
            ),  # should be ignored
            get_liquidity_token(2, notional=liquidityTokenNotional),
            get_liquidity_token(
                1, currencyId=2, notional=liquidityTokenNotional
            ),  # should be ignored
        ],
        [],
        0,
        3,
        [],
    )

    (totalAssetCash, totalHaircutAssetCash) = liquidation.calculateTokenCashClaims(
        portfolioState, cashGroup, markets, START_TIME
    )

    cashClaim = math.trunc(markets[1][3] * liquidityTokenNotional / markets[1][4])

    assert totalAssetCash == cashClaim
    assert totalHaircutAssetCash == cashClaim * 0.98


@given(
    fCashValue=strategy("int", min_value=-1000e8, max_value=1000e8),
    storedCashBalance=strategy("int", min_value=-1000e8, max_value=1000e8),
    netCashChange=strategy("int", min_value=-1000e8, max_value=1000e8),
    collateralPerpetualTokenValue=strategy("int", min_value=0, max_value=1000e8),
    collateralCashClaim=strategy("int", min_value=0, max_value=1000e8),
)
def test_post_fcash_value(
    liquidationFixtures,
    accounts,
    fCashValue,
    storedCashBalance,
    netCashChange,
    collateralPerpetualTokenValue,
    collateralCashClaim,
):
    (_, liquidation) = liquidationFixtures
    fCashValue = -100e8
    storedCashBalance = 200e8
    netCashChange = 0
    collateralPerpetualTokenValue = 0
    collateralCashClaim = 0

    collateralBalance = storedCashBalance + netCashChange + collateralPerpetualTokenValue
    collateralAvailable = collateralBalance + collateralCashClaim + fCashValue
    balanceState = get_balance_state(
        1, storedCashBalance=storedCashBalance, netCashChange=netCashChange
    )
    (newCollateralAvailable, balanceAdjustment) = liquidation.calculatePostfCashValue(
        collateralAvailable, balanceState, collateralPerpetualTokenValue, collateralCashClaim
    )

    if fCashValue <= 0:
        # No adjustment for negative fCash
        assert newCollateralAvailable == collateralAvailable
        assert balanceAdjustment == 0
    elif collateralBalance > 0:
        # Positive balance, withold for fCashValue
        assert newCollateralAvailable == collateralAvailable - fCashValue
        assert balanceAdjustment == 0
    else:
        # Negative balance, offset fCashValue first
        netBalance = collateralBalance + fCashValue
        if netBalance > 0:
            assert newCollateralAvailable == collateralAvailable - netBalance
            assert balanceAdjustment == -collateralBalance
        else:
            assert newCollateralAvailable == collateralAvailable
            assert balanceAdjustment == fCashValue


@given(
    collateralAvailable=strategy("int", min_value=1, max_value=1000e8),
    localToTrade=strategy("int", min_value=1, max_value=1000e8),
    haircutCashClaim=strategy("int", min_value=0, max_value=1000e8),
)
def test_collateral_to_sell(
    liquidationFixtures, accounts, collateralAvailable, localToTrade, haircutCashClaim
):
    (_, liquidation) = liquidationFixtures

    localETHRate = liquidation.getETHRate(1)
    collateralETHRate = liquidation.getETHRate(2)
    (cg1, markets1) = liquidation.buildCashGroupView(1)
    (cg2, markets2) = liquidation.buildCashGroupView(2)

    discount = max(localETHRate[-1], collateralETHRate[-1])
    factors = (
        0,
        0,
        collateralAvailable,
        0,
        localETHRate,
        collateralETHRate,
        cg1,
        cg2,
        markets1,
        markets2,
        True,
    )
    (collateralToSell, localToPurchase) = liquidation.calculateCollateralToSell(
        factors, localToTrade, haircutCashClaim
    )

    # All exchange rates are 1-1 here so we just want to ensure that the branches are caught
    collateralRequired = localToTrade * discount / 100
    if collateralAvailable + haircutCashClaim > collateralRequired:
        assert collateralToSell == collateralRequired
        assert localToPurchase == localToTrade
    else:
        assert collateralToSell == collateralAvailable + haircutCashClaim
        assert (
            pytest.approx(localToPurchase, abs=2)
            == (collateralAvailable + haircutCashClaim) * 100 / discount
        )


@given(
    localAssetRequired=strategy("int", min_value=1, max_value=1000e8),
    localAvailable=strategy("int", min_value=-1000e8, max_value=-1),
)
def test_local_to_trade(liquidationFixtures, accounts, localAssetRequired, localAvailable):
    (_, liquidation) = liquidationFixtures
    localAssetRequired = 100e8
    localAvailable = -100e8

    localETHRate = liquidation.getETHRate(1)
    collateralETHRate = liquidation.getETHRate(2)
    (cg1, markets1) = liquidation.buildCashGroupView(1)
    (cg2, markets2) = liquidation.buildCashGroupView(2)

    factors = (
        localAssetRequired,
        localAvailable,
        0,
        0,
        localETHRate,
        collateralETHRate,
        cg1,
        cg2,
        markets1,
        markets2,
        True,
    )

    localToTrade = liquidation.calculateLocalToTrade(factors)

    assert localToTrade <= -localAvailable
    assert localToTrade <= localAssetRequired


# Test liquidate collateral
def test_sufficient_no_portfolio(liquidationFixtures, accounts):
    (factorContract, liquidation) = liquidationFixtures
    localBalance = -100e8
    collateralBalance = 120e8

    factorContract.setBalance(accounts[0], 1, localBalance, 0)
    factorContract.setBalance(accounts[0], 2, collateralBalance, 0)
    portfolioState = ([], [], 0, 0, [])

    txn = factorContract.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2)
    factors = txn.return_value

    discount = max(factors[4][-1], factors[5][-1])
    (localToPurchase, newBalanceContext, newPortfolioState) = liquidation.liquidateCollateral(
        factors,
        get_balance_state(2, storedCashBalance=collateralBalance),
        portfolioState,
        0,
        START_TIME,
    )

    assert portfolioState == newPortfolioState
    assert localToPurchase < -localBalance
    assert pytest.approx(newBalanceContext[4]) == -math.trunc(localToPurchase * discount / 100)
    assert newBalanceContext[5] == 0


def test_not_sufficient_no_portfolio(liquidationFixtures, accounts):
    (factorContract, liquidation) = liquidationFixtures
    localBalance = -200e8
    collateralBalance = 100e8

    factorContract.setBalance(accounts[0], 1, localBalance, 0)
    factorContract.setBalance(accounts[0], 2, collateralBalance, 0)
    portfolioState = ([], [], 0, 0, [])

    txn = factorContract.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2)
    factors = txn.return_value

    discount = max(factors[4][-1], factors[5][-1])
    (localToPurchase, newBalanceContext, newPortfolioState) = liquidation.liquidateCollateral(
        factors,
        get_balance_state(2, storedCashBalance=collateralBalance),
        portfolioState,
        0,
        START_TIME,
    )

    assert portfolioState == newPortfolioState
    assert localToPurchase == collateralBalance * 100 / discount
    assert pytest.approx(newBalanceContext[4]) == -collateralBalance
    assert newBalanceContext[5] == 0


def test_sufficient_with_fcash(liquidationFixtures, accounts):
    (factorContract, liquidation) = liquidationFixtures
    localBalance = -100e8
    collateralBalance = 120e8

    factorContract.setBalance(accounts[0], 1, localBalance, 0)
    factorContract.setBalance(accounts[0], 2, collateralBalance, 0)
    portfolioState = ([get_fcash_token(2, notional=100e8)], [], 0, 0, [])

    txn = factorContract.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2)
    factors = txn.return_value

    discount = max(factors[4][-1], factors[5][-1])
    (localToPurchase, newBalanceContext, newPortfolioState) = liquidation.liquidateCollateral(
        factors,
        get_balance_state(2, storedCashBalance=collateralBalance),
        portfolioState,
        0,
        START_TIME,
    )

    assert portfolioState == newPortfolioState
    assert localToPurchase < -localBalance
    assert pytest.approx(newBalanceContext[4]) == -math.trunc(localToPurchase * discount / 100)
    assert newBalanceContext[5] == 0


def test_not_sufficient_with_fcash(liquidationFixtures, accounts):
    (factorContract, liquidation) = liquidationFixtures
    localBalance = -200e8
    collateralBalance = 100e8

    factorContract.setBalance(accounts[0], 1, localBalance, 0)
    factorContract.setBalance(accounts[0], 2, collateralBalance, 0)
    portfolioState = ([get_fcash_token(2, notional=100e8)], [], 0, 0, [])

    txn = factorContract.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2)
    factors = txn.return_value

    discount = max(factors[4][-1], factors[5][-1])
    (localToPurchase, newBalanceContext, newPortfolioState) = liquidation.liquidateCollateral(
        factors,
        get_balance_state(2, storedCashBalance=collateralBalance),
        portfolioState,
        0,
        START_TIME,
    )

    assert portfolioState == newPortfolioState
    assert localToPurchase == collateralBalance * 100 / discount
    assert pytest.approx(newBalanceContext[4]) == -collateralBalance
    assert newBalanceContext[5] == 0


def test_sufficient_perpetual_tokens(liquidationFixtures, accounts):
    (factorContract, liquidation) = liquidationFixtures
    localBalance = -100e8
    perpTokenValue = 120e8
    perpTokenBalance = 1000e8

    factorContract.setBalance(accounts[0], 1, localBalance, 0)
    factorContract.setBalance(
        accounts[0], 2, perpTokenValue, 0
    )  # Bit of a hack to get around valuation
    portfolioState = ([], [], 0, 0, [])

    txn = factorContract.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2)
    factors = list(txn.return_value)
    factors[2] = perpTokenValue
    factors[3] = perpTokenValue

    discount = max(factors[4][-1], factors[5][-1])
    (localToPurchase, newBalanceContext, newPortfolioState) = liquidation.liquidateCollateral(
        factors,
        get_balance_state(2, storedPerpetualTokenBalance=perpTokenBalance),
        portfolioState,
        0,
        START_TIME,
    )

    assert portfolioState == newPortfolioState
    assert localToPurchase < -localBalance
    assert newBalanceContext[4] == 0
    assert pytest.approx(newBalanceContext[5], abs=10) == -math.trunc(
        (localToPurchase * discount / 100) * perpTokenBalance / perpTokenValue
    )


def test_not_sufficient_perpetual_tokens(liquidationFixtures, accounts):
    (factorContract, liquidation) = liquidationFixtures
    localBalance = -200e8
    perpTokenValue = 100e8
    perpTokenBalance = 1000e8

    factorContract.setBalance(accounts[0], 1, localBalance, 0)
    factorContract.setBalance(
        accounts[0], 2, perpTokenValue, 0
    )  # Bit of a hack to get around valuation
    portfolioState = ([], [], 0, 0, [])

    txn = factorContract.calculateLiquidationFactors(accounts[0], START_TIME, 1, 2)
    factors = list(txn.return_value)
    factors[2] = perpTokenValue
    factors[3] = perpTokenValue

    discount = max(factors[4][-1], factors[5][-1])
    (localToPurchase, newBalanceContext, newPortfolioState) = liquidation.liquidateCollateral(
        factors,
        get_balance_state(2, storedPerpetualTokenBalance=perpTokenBalance),
        portfolioState,
        0,
        START_TIME,
    )

    assert portfolioState == newPortfolioState
    assert localToPurchase == perpTokenValue * 100 / discount
    assert newBalanceContext[4] == 0
    assert newBalanceContext[5] == -perpTokenBalance


def test_sufficient_liquidity_tokens(liquidationFixtures, accounts):
    pass


def test_not_sufficient_liquidity_tokens(liquidationFixtures, accounts):
    pass

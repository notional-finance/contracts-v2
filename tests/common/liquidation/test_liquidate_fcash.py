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
def liquidation(MockfCashLiquidation, MockCToken, cTokenAggregator, ethAggregators, accounts):
    liquidation = accounts[0].deploy(MockfCashLiquidation)
    ctoken = accounts[0].deploy(MockCToken, 8)
    # This is the identity rate
    ctoken.setAnswer(1e18)
    aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})

    cg = get_cash_group_with_max_markets(3)
    rateStorage = (aggregator.address, 8)

    ethAggregators[0].setAnswer(1e18)
    liquidation.setAssetRateMapping(1, rateStorage)
    liquidation.setCashGroup(1, cg)
    liquidation.setETHRateMapping(1, get_eth_rate_mapping(ethAggregators[0], discount=104))

    ethAggregators[1].setAnswer(1e18)
    liquidation.setAssetRateMapping(2, rateStorage)
    liquidation.setCashGroup(2, cg)
    liquidation.setETHRateMapping(2, get_eth_rate_mapping(ethAggregators[1], discount=102))

    ethAggregators[2].setAnswer(1e18)
    liquidation.setAssetRateMapping(3, rateStorage)
    liquidation.setCashGroup(3, cg)
    liquidation.setETHRateMapping(3, get_eth_rate_mapping(ethAggregators[2], discount=105))

    chain.mine(1, timestamp=START_TIME)

    return liquidation


def test_liquidate_fcash_local_positive_available_insufficient(liquidation, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    portfolio = [
        get_fcash_token(1, currencyId=1, notional=100e8),
        get_fcash_token(2, currencyId=1, notional=100e8),
        get_fcash_token(3, currencyId=1, notional=100e8),
    ]
    portfolioState = (portfolio, [], 0, len(portfolio))
    accountContext = (START_TIME, "0x01", 3, 0, "0x000000000000000000")
    (cashGroup, markets) = liquidation.buildCashGroupView(1)
    factors = (
        accounts[0],
        -10e8,
        1000e8,
        1000e8,
        0,
        "0x5F00005A0000",  # 95 liquidation, 90 haircut
        (1e18, 1e18, 140, 100, 106),
        (1e18, 1e18, 140, 100, 105),
        cashGroup,
        markets,
    )

    fCashContext = (accountContext, factors, portfolioState, 0, 0, 0, [])
    maturities = [a[1] for a in portfolio]

    (notionals, localFromLiquidator, _) = liquidation.liquidatefCashLocal(
        accounts[0], 1, maturities, [0, 0, 0], fCashContext, START_TIME
    ).return_value

    assert sum(notionals) > localFromLiquidator
    assert notionals == [100e8, 100e8, 100e8]


def test_liquidate_fcash_local_positive_available_sufficient(liquidation, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    portfolio = [
        get_fcash_token(1, currencyId=1, notional=50000e8),
        get_fcash_token(2, currencyId=1, notional=50000e8),
        get_fcash_token(3, currencyId=1, notional=50000e8),
    ]
    portfolioState = (portfolio, [], 0, len(portfolio))
    accountContext = (START_TIME, "0x01", 3, 0, "0x000000000000000000")
    (cashGroup, markets) = liquidation.buildCashGroupView(1)
    factors = (
        accounts[0],
        -10e8,
        1000e8,
        1000e8,
        0,
        "0x5F00005A0000",  # 95 liquidation, 90 haircut
        (1e18, 1e18, 140, 100, 106),
        (1e18, 1e18, 140, 100, 105),
        cashGroup,
        markets,
    )

    fCashContext = (accountContext, factors, portfolioState, 0, 0, 0, [])
    maturities = [a[1] for a in portfolio]

    (notionals, localFromLiquidator, _) = liquidation.liquidatefCashLocal(
        accounts[0], 1, maturities, [0, 0, 0], fCashContext, START_TIME
    ).return_value

    assert sum(notionals) > localFromLiquidator
    assert notionals == [50000e8, 20000e8, 0]


def test_liquidate_fcash_local_negative_available(liquidation, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        liquidation.setMarketStorage(1, SETTLEMENT_DATE, m)

    portfolio = [
        get_fcash_token(1, currencyId=1, notional=50000e8),
        get_fcash_token(2, currencyId=1, notional=50000e8),
        get_fcash_token(3, currencyId=1, notional=50000e8),
    ]
    portfolioState = (portfolio, [], 0, len(portfolio))
    accountContext = (START_TIME, "0x01", 3, 0, "0x000000000000000000")
    (cashGroup, markets) = liquidation.buildCashGroupView(1)
    factors = (
        accounts[0],
        -100e8,
        -100e8,
        1000e8,
        0,
        "0x5F00005A0000",  # 95 liquidation, 90 haircut
        (1e18, 1e18, 140, 100, 106),
        (1e18, 1e18, 140, 100, 105),
        cashGroup,
        markets,
    )

    fCashContext = (accountContext, factors, portfolioState, 0, 0, 0, [])
    maturities = [a[1] for a in portfolio]

    (notionals, localFromLiquidator, _) = liquidation.liquidatefCashLocal(
        accounts[0], 1, maturities, [0, 0, 0], fCashContext, START_TIME
    ).return_value

    assert sum(notionals) > localFromLiquidator
    assert notionals == [50000e8, 50000e8, 20000e8]

import math
import random

import brownie
import pytest
from brownie.test import given
from tests.common.params import *


@pytest.fixture(scope="module", autouse=True)
def assetLibrary(MockAsset, accounts):
    return accounts[0].deploy(MockAsset)


@pytest.fixture(scope="module", autouse=True)
def cashGroup(MockCashGroup, accounts):
    return accounts[0].deploy(MockCashGroup)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@given(oracleRate=impliedRateStrategy)
def test_risk_adjusted_pv(assetLibrary, cashGroup, oracleRate):
    # has a 30 bps buffer / haircut
    cg = list(BASE_CASH_GROUP)
    blockTime = START_TIME

    # the longer dated the maturity, the lower the pv holding everything else constant
    maturities = [START_TIME + (90 * SECONDS_IN_DAY) * i for i in range(1, 50)]
    prevPositivePV = 1e18
    prevNegativePV = -1e18
    for m in maturities:
        riskPVPositive = assetLibrary.getRiskAdjustedPresentValue(
            (1e18, m, cg[0]), cg, blockTime, oracleRate
        )

        assert riskPVPositive < prevPositivePV or riskPVPositive == 0
        prevPositivePV = riskPVPositive

        # further away then you can hold less capital against it
        riskPVNegative = assetLibrary.getRiskAdjustedPresentValue(
            (-1e18, m, cg[0]), cg, blockTime, oracleRate
        )
        assert prevNegativePV < riskPVNegative or riskPVNegative == -1e18
        prevNegativePV = riskPVNegative


def test_haircut_token_value(assetLibrary):
    cg = list(BASE_CASH_GROUP)
    (assetCash, fCash) = assetLibrary.getHaircutCashClaims(
        (1e18, 100, cg[0]), (cg[0], 100, 2e18, 2e18, 2e18, 0, 0, 0), cg, 0
    )
    assert assetCash == math.trunc(1e18 * cg[5] / 100)
    assert fCash == math.trunc(1e18 * cg[5] / 100)


def test_find_market_index(assetLibrary):
    cg = list(BASE_CASH_GROUP)
    marketStates = [
        (cg[0], 100, 1e18, 1e18, 1e18, 0, 0, 0),
        (cg[0], 200, 1e18, 1e18, 1e18, 0, 0, 0),
        (cg[0], 300, 1e18, 1e18, 1e18, 0, 0, 0),
    ]

    (index, idiosyncratic) = assetLibrary.findMarketIndex(100, marketStates)
    assert index == 0
    assert not idiosyncratic

    (index, idiosyncratic) = assetLibrary.findMarketIndex(300, marketStates)
    assert index == 2
    assert not idiosyncratic

    (index, idiosyncratic) = assetLibrary.findMarketIndex(125, marketStates)
    assert index == 0
    assert idiosyncratic

    with brownie.reverts("A: market not found"):
        (index, idiosyncratic) = assetLibrary.findMarketIndex(400, marketStates)


@given(shortRate=impliedRateStrategy, shortMaturity=timeToMaturityStrategy)
def test_interpolated_rate_oracle(assetLibrary, shortRate, shortMaturity):
    shortMaturity = shortMaturity * SECONDS_IN_DAY
    longMaturity = shortMaturity + math.trunc(random.uniform(1, 3600) * SECONDS_IN_DAY)
    longRate = shortRate + math.trunc(random.uniform(-shortRate, shortRate * 5))
    maturity = math.trunc(random.uniform(shortMaturity - 1, longMaturity + 1))

    # assertions are handled in the mock
    rate = assetLibrary.interpolateOracleRate(
        (1, shortMaturity, 0, 0, 0, 0, shortRate, 0),
        (1, longMaturity, 0, 0, 0, 0, longRate, 0),
        maturity,
    )

    if shortRate < longRate:
        assert shortRate < rate
        assert rate < longRate
    elif longRate < shortRate:
        assert shortRate > rate
        assert rate > longRate


def test_liquidity_token_value(assetLibrary):
    cg = list(BASE_CASH_GROUP)
    marketStates = [
        (cg[0], 100, 1e18, 1e18, 1e18, 0, 0.01 * RATE_PRECISION, 0),
        (cg[0], 200, 2e18, 2e18, 1e18, 0, 0.01 * RATE_PRECISION, 0),
        (cg[0], 300, 3e18, 3e18, 1e18, 0, 0.01 * RATE_PRECISION, 0),
    ]

    with brownie.reverts("A: idiosyncratic token"):
        assetLibrary.getLiquidityTokenValue((1e18, 120, cg[0]), cg, marketStates, [], 0)

    # Case when token is not found
    (assetCash, pv, fCashAssets) = assetLibrary.getLiquidityTokenValue(
        (0.5e18, 200, cg[0]), cg, marketStates, [], 0
    )

    assert fCashAssets == ()
    assert assetCash == 0.97e18
    assert pv == assetLibrary.getRiskAdjustedPresentValue(
        (0.97e18, 200, cg[0]), cg, 0, 0.01 * RATE_PRECISION
    )

    # Case when token is found
    (assetCash, pv, fCashAssets) = assetLibrary.getLiquidityTokenValue(
        (0.5e18, 200, cg[0]), cg, marketStates, [(-0.25e18, 200, cg[0])], 0
    )
    assert assetCash == 0.97e18
    assert pv == 0
    assert len(fCashAssets) == 1
    assert fCashAssets[0][0] == 0.72e18


# def test_portfolio_value(assetLibrary, oracleRate, timeToMaturity):

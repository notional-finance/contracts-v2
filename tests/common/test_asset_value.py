import math

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
            cg, 1e18, m, blockTime, oracleRate
        )

        assert riskPVPositive < prevPositivePV or riskPVPositive == 0
        prevPositivePV = riskPVPositive

        # further away then you can hold less capital against it
        riskPVNegative = assetLibrary.getRiskAdjustedPresentValue(
            cg, -1e18, m, blockTime, oracleRate
        )
        assert prevNegativePV < riskPVNegative or riskPVNegative == -1e18
        prevNegativePV = riskPVNegative


def test_haircut_token_value(assetLibrary):
    cg = list(BASE_CASH_GROUP)
    (assetCash, fCash) = assetLibrary.getHaircutCashClaims(
        (cg[0], 100, 2, 1e18, 0), (cg[0], 100, 2e18, 2e18, 2e18, 0, 0, 0), cg, 0
    )
    assert assetCash == math.trunc(1e18 * 97 / 100)
    assert fCash == math.trunc(1e18 * 97 / 100)


def test_liquidity_token_value(assetLibrary):
    cg = list(BASE_CASH_GROUP)
    marketStates = [
        (cg[0], 90 * SECONDS_IN_DAY, 1e18, 1e18, 1e18, 0, 0.01 * RATE_PRECISION, 0),
        (cg[0], 180 * SECONDS_IN_DAY, 2e18, 2e18, 1e18, 0, 0.01 * RATE_PRECISION, 0),
        (cg[0], SECONDS_IN_YEAR, 3e18, 3e18, 1e18, 0, 0.01 * RATE_PRECISION, 0),
    ]

    with brownie.reverts("A: idiosyncratic token"):
        assetLibrary.getLiquidityTokenValue((cg[0], 120, 2, 1e18, 0), cg, marketStates, [], 0)

    # Case when token is not found
    (assetCash, pv, fCashAssets) = assetLibrary.getLiquidityTokenValue(
        (cg[0], 180 * SECONDS_IN_DAY, 2, 0.5e18, 0), cg, marketStates, [], 0
    )

    assert fCashAssets == ()
    assert assetCash == 0.97e18
    assert pv == assetLibrary.getRiskAdjustedPresentValue(
        cg, 0.97e18, 180 * SECONDS_IN_DAY, 0, 0.01 * RATE_PRECISION
    )

    # Case when token is found
    (assetCash, pv, fCashAssets) = assetLibrary.getLiquidityTokenValue(
        (cg[0], 180 * SECONDS_IN_DAY, 2, 0.5e18, 0),
        cg,
        marketStates,
        [(cg[0], 180 * SECONDS_IN_DAY, 1, -0.25e18, 0)],
        0,
    )
    assert assetCash == 0.97e18
    assert pv == 0
    assert len(fCashAssets) == 1
    assert fCashAssets[0][3] == 0.72e18


# def test_portfolio_value(assetLibrary, oracleRate, timeToMaturity):

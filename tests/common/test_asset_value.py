import math
import random

import brownie
import pytest
from brownie.test import given
from tests.common.params import *


@pytest.fixture(scope="module", autouse=True)
def assetLibrary(MockAssetHandler, accounts):
    return accounts[0].deploy(MockAssetHandler)


@pytest.fixture(scope="module", autouse=True)
def cashGroup(MockCashGroup, accounts):
    return accounts[0].deploy(MockCashGroup)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_settlement_date(assetLibrary):
    (assetArray, _) = generate_asset_array(50, 8)

    for a in assetArray:
        date = assetLibrary.getSettlementDate(list(a) + [0])

        if a[2] > 3:
            assert date - 90 * SECONDS_IN_DAY == START_TIME_TREF
        else:
            assert a[1] == date


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
        (cg[0], 100, 2, 1e18, 0), (cg[0], 100, 2e18, 2e18, 2e18, 0, 0, 0, False), cg, 0
    )
    assert assetCash == math.trunc(1e18 * 97 / 100)
    assert fCash == math.trunc(1e18 * 97 / 100)


def test_liquidity_token_value(assetLibrary):
    cg = list(BASE_CASH_GROUP)
    marketStates = [
        (cg[0], 90 * SECONDS_IN_DAY, 1e18, 1e18, 1e18, 0, 0.01 * RATE_PRECISION, 0, False),
        (cg[0], 180 * SECONDS_IN_DAY, 2e18, 2e18, 1e18, 0, 0.01 * RATE_PRECISION, 0, False),
        (cg[0], SECONDS_IN_YEAR, 3e18, 3e18, 1e18, 0, 0.01 * RATE_PRECISION, 0, False),
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


# @given(
#     blockTime=strategy("uint32", min_value=START_TIME),
#     # this is a per block interest rate of 0.2% to 42%, (rate = 2102400 * supplyRate / 1e18)
#     supplyRate=strategy("uint", min_value=1e9, max_value=2e11),
#     numAssets=strategy("uint", min_value=0, max_value=40)
# )
def test_portfolio_value(
    assetLibrary,
    MockCToken,
    cTokenAggregator,
    accounts,
    cashGroup,  # blockTime, supplyRate, numAssets
):
    blockTime = START_TIME
    supplyRate = 1e9
    cTokens = []
    env = []

    # Setup 5 cash groups
    for i in range(1, 6):
        ctoken = accounts[0].deploy(MockCToken, 8)
        ctoken.setAnswer(1e18)
        ctoken.setSupplyRate(supplyRate)
        cTokens.append(ctoken)
        currencyId = i

        aggregator = accounts[0].deploy(cTokenAggregator, ctoken.address)
        cashGroupParams = (
            3,
            1,  # 1 rateOracleTimeWindowMin,
            random.randint(1, 100),  # 2 liquidityFeeBPS,
            random.randint(1, 100),  # 3 liquidityTokenHaircut,
            random.randint(1, 100),  # 4 debtBufferBPS,
            random.randint(1, 100),  # 5 fCashHaircutBPS,
            random.randint(1, 20000),  # 6 rateScalar
        )

        rateStorage = (aggregator.address, 18, False, 0, 0, 18, 18)
        assetLibrary.setAssetRateMapping(currencyId, rateStorage)
        cashGroup.setAssetRateMapping(currencyId, rateStorage)

        assetLibrary.setCashGroup(currencyId, cashGroupParams)
        cashGroup.setCashGroup(currencyId, cashGroupParams)
        maxMarketIndex = cashGroupParams[0]

        tRef = blockTime - blockTime % (90 * SECONDS_IN_DAY)
        validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(1, maxMarketIndex + 1)]
        impliedRates = {}
        (cg, markets) = cashGroup.buildCashGroup(currencyId)

        for m in validMarkets:
            lastImpliedRate = random.randint(1e8, 1e9)
            impliedRates[m] = lastImpliedRate

            assetLibrary.setMarketState(
                cg[0], m, (1e18, 1e18, lastImpliedRate, 0, blockTime - 1000), 1e18
            )

        env.append(
            {
                "cashGroup": cg,
                "markets": markets,
                "impliedRates": impliedRates,
                "validMarkets": validMarkets,
            }
        )

    # TODO: add a more sophisticated test here
    values = assetLibrary.getRiskAdjustedPortfolioValue(
        [
            (2, env[1]["validMarkets"][0], 1, 1e8, 0),
            (2, env[1]["validMarkets"][1], 2, 1e8, 0),
            (4, env[1]["validMarkets"][0], 1, -1e8, 0),
        ],
        [e["cashGroup"] for e in env],
        [e["markets"] for e in env],
        blockTime,
    )

    # One set of values per cash group
    assert len(values) == len(env)
    assert values[0] == 0
    assert values[1] > 0
    assert values[2] == 0
    assert values[3] < 0
    assert values[4] == 0

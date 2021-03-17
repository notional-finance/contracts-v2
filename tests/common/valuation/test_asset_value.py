import math

import brownie
import pytest
from brownie.network.state import Chain
from brownie.test import given
from tests.constants import (
    FCASH_ASSET_TYPE,
    MARKETS,
    SECONDS_IN_DAY,
    SETTLEMENT_DATE,
    START_TIME,
    START_TIME_TREF,
)
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_fcash_token,
    get_liquidity_token,
    get_market_state,
    get_portfolio_array,
    impliedRateStrategy,
)

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def assetLibrary(MockAssetHandler, MockCToken, cTokenAggregator, accounts):
    asset = accounts[0].deploy(MockAssetHandler)
    ctoken = accounts[0].deploy(MockCToken, 8)
    # This is the identity rate
    ctoken.setAnswer(1e18)
    aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})

    rateStorage = (aggregator.address, 8)
    asset.setAssetRateMapping(1, rateStorage)
    cg = get_cash_group_with_max_markets(3)
    asset.setCashGroup(1, cg)

    asset.setAssetRateMapping(2, rateStorage)
    asset.setCashGroup(2, cg)

    asset.setAssetRateMapping(3, rateStorage)
    asset.setCashGroup(3, cg)

    chain.mine(1, timestamp=START_TIME)

    return asset


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_settlement_date(assetLibrary):
    with brownie.reverts():
        # invalid asset type
        assetLibrary.getSettlementDate((1, START_TIME_TREF, 0, 0, 0))

    # fcash settlement date
    assert MARKETS[1] == assetLibrary.getSettlementDate((1, MARKETS[1], FCASH_ASSET_TYPE, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[0], 2, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[1], 3, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[2], 4, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[3], 5, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[4], 6, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[5], 7, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[6], 8, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[7], 9, 0, 0))
    assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[8], 10, 0, 0))

    with brownie.reverts():
        # invalid asset type
        assetLibrary.getSettlementDate((1, START_TIME_TREF, 11, 0, 0))


def test_failure_liquidity_token_cash_claims(assetLibrary):
    marketState = get_market_state(MARKETS[0])
    (cashGroup, _) = assetLibrary.buildCashGroupView(1)

    with brownie.reverts():
        assetLibrary.getCashClaims(get_fcash_token(1), marketState)

    with brownie.reverts():
        assetLibrary.getHaircutCashClaims(get_fcash_token(1), marketState, cashGroup)

    with brownie.reverts():
        assetLibrary.getCashClaims((1, START_TIME_TREF, 11, 1e18, 0), marketState)

    with brownie.reverts():
        assetLibrary.getHaircutCashClaims((1, START_TIME_TREF, 11, 1e18, 0), marketState, cashGroup)

    with brownie.reverts():
        assetLibrary.getCashClaims(get_liquidity_token(1, notional=-1), marketState)

    with brownie.reverts():
        assetLibrary.getHaircutCashClaims(
            get_liquidity_token(1, notional=-1), marketState, cashGroup
        )


def test_liquidity_token_cash_claims(assetLibrary):
    marketState = get_market_state(MARKETS[1])
    (cashGroup, _) = assetLibrary.buildCashGroupView(1)
    token = get_liquidity_token(1, notional=0.5e18)

    (assetCashHaircut, fCashHaircut) = assetLibrary.getHaircutCashClaims(
        token, marketState, cashGroup
    )
    (assetCash, fCash) = assetLibrary.getCashClaims(token, marketState)

    assert assetCashHaircut == math.trunc(0.5e18 * 99 / 100)
    assert fCashHaircut == math.trunc(0.5e18 * 99 / 100)
    assert assetCash == 0.5e18
    assert fCash == 0.5e18


def test_invalid_liquidity_token_value(assetLibrary):
    (cashGroup, _) = assetLibrary.buildCashGroupView(1)
    marketStates = [
        get_market_state(MARKETS[0]),
        get_market_state(MARKETS[1]),
        get_market_state(MARKETS[2]),
    ]

    token = get_liquidity_token(1, maturity=MARKETS[0] + 100)

    with brownie.reverts():
        assetLibrary.getLiquidityTokenValue(token, cashGroup, marketStates, [], 0)

    with brownie.reverts():
        assetLibrary.getLiquidityTokenValueRiskAdjusted(token, cashGroup, marketStates, [], 0)


def test_liquidity_token_value_fcash_not_found(assetLibrary):
    token = get_liquidity_token(1)

    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[0]))
    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[1]))
    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[2]))
    (cashGroup, marketStates) = assetLibrary.buildCashGroupView(1)
    oracleRate = get_market_state(MARKETS[0])[6]

    # Case when token is not found
    (assetCash, riskAdjustedPv, fCashAssets) = assetLibrary.getLiquidityTokenValueRiskAdjusted(
        token, cashGroup, marketStates, [], START_TIME
    )

    assert fCashAssets == ()
    assert assetCash == 0.99e18
    assert riskAdjustedPv == assetLibrary.getRiskAdjustedPresentValue(
        cashGroup, 0.99e18, MARKETS[0], START_TIME, oracleRate
    )

    # Test when not risk adjusted
    (assetCash, pv, fCashAssets) = assetLibrary.getLiquidityTokenValue(
        token, cashGroup, marketStates, [], START_TIME
    )

    assert fCashAssets == ()
    assert assetCash == 1e18
    assert pv == assetLibrary.getPresentValue(1e18, MARKETS[0], START_TIME, oracleRate)


def test_liquidity_token_value_fcash_found(assetLibrary):
    token = get_liquidity_token(1, notional=0.5e18)

    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[0]))
    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[1]))
    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[2]))
    (cashGroup, marketStates) = assetLibrary.buildCashGroupView(1)
    fCashAssetsInput = [get_fcash_token(1, notional=-0.25e18)]

    # Case when token is found
    (assetCash, pv, fCashAssets) = assetLibrary.getLiquidityTokenValue(
        token, cashGroup, marketStates, fCashAssetsInput, START_TIME
    )

    assert assetCash == 0.5e18
    assert pv == 0
    assert len(fCashAssets) == 1
    assert fCashAssets[0][3] == 0.25e18

    (assetCash, riskAdjustedPv, fCashAssets) = assetLibrary.getLiquidityTokenValueRiskAdjusted(
        token, cashGroup, marketStates, fCashAssetsInput, START_TIME
    )

    assert assetCash == 0.5e18 * 0.99
    assert riskAdjustedPv == 0
    assert len(fCashAssets) == 1
    # Take the haircut first and then net off
    assert fCashAssets[0][3] == (0.5e18 * 0.99) - 0.25e18


@given(oracleRate=impliedRateStrategy)
def test_risk_adjusted_pv(assetLibrary, oracleRate):
    # has a 30 bps buffer / haircut
    (cashGroup, _) = assetLibrary.buildCashGroupView(1)

    # the longer dated the maturity, the lower the pv holding everything else constant
    maturities = [START_TIME + (90 * SECONDS_IN_DAY) * i for i in range(1, 50, 3)]
    prevPositivePV = 1e18
    prevNegativePV = -1e18
    for m in maturities:
        riskPVPositive = assetLibrary.getRiskAdjustedPresentValue(
            cashGroup, 1e18, m, START_TIME, oracleRate
        )
        pvPositive = assetLibrary.getPresentValue(1e18, m, START_TIME, oracleRate)

        assert pvPositive > riskPVPositive
        assert riskPVPositive < prevPositivePV or riskPVPositive == 0
        prevPositivePV = riskPVPositive

        # further away then you can hold less capital against it
        riskPVNegative = assetLibrary.getRiskAdjustedPresentValue(
            cashGroup, -1e18, m, START_TIME, oracleRate
        )
        pvNegative = assetLibrary.getPresentValue(-1e18, m, START_TIME, oracleRate)

        assert pvNegative > riskPVNegative
        assert prevNegativePV < riskPVNegative or riskPVNegative == -1e18
        prevNegativePV = riskPVNegative


def test_oracle_rate_failure(assetLibrary):
    (cashGroup, markets) = assetLibrary.buildCashGroupView(1)
    assets = [get_fcash_token(1)]

    # Fails due to unset market
    with brownie.reverts():
        assetLibrary.getRiskAdjustedPortfolioValue(assets, [cashGroup], [markets], START_TIME)


def test_portfolio_value_cash_group_not_found(assetLibrary):
    (cashGroup, markets) = assetLibrary.buildCashGroupView(1)
    assets = [get_fcash_token(1, currencyId=2)]

    # Cash group not found
    with brownie.reverts():
        assetLibrary.getRiskAdjustedPortfolioValue(assets, [cashGroup], [markets], START_TIME)


def test_portfolio_value(assetLibrary):
    (cashGroup1, markets1) = assetLibrary.buildCashGroupView(1)
    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[0]))
    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[1]))
    assetLibrary.setMarketStorage(1, SETTLEMENT_DATE, get_market_state(MARKETS[2]))

    (cashGroup2, markets2) = assetLibrary.buildCashGroupView(2)
    assetLibrary.setMarketStorage(2, SETTLEMENT_DATE, get_market_state(MARKETS[0]))
    assetLibrary.setMarketStorage(2, SETTLEMENT_DATE, get_market_state(MARKETS[1]))
    assetLibrary.setMarketStorage(2, SETTLEMENT_DATE, get_market_state(MARKETS[2]))

    (cashGroup3, markets3) = assetLibrary.buildCashGroupView(3)
    assetLibrary.setMarketStorage(3, SETTLEMENT_DATE, get_market_state(MARKETS[0]))
    assetLibrary.setMarketStorage(3, SETTLEMENT_DATE, get_market_state(MARKETS[1]))
    assetLibrary.setMarketStorage(3, SETTLEMENT_DATE, get_market_state(MARKETS[2]))

    cashGroups = [cashGroup1, cashGroup2, cashGroup3]
    markets = [markets1, markets2, markets3]
    assets = get_portfolio_array(5, cashGroups, sorted=True)

    assetValuesRiskAdjusted = assetLibrary.getRiskAdjustedPortfolioValue(
        assets, cashGroups, markets, START_TIME
    )

    assetValues = assetLibrary.getPortfolioValue(assets, cashGroups, markets, START_TIME)

    assert len(assetValuesRiskAdjusted) == 3
    assert len(assetValues) == 3

    totalPV = [0, 0, 0]
    for asset in assets:
        currencyId = asset[0]
        if asset[2] == FCASH_ASSET_TYPE:
            # All implied rates in this example are 0.1e9
            totalPV[currencyId - 1] += assetLibrary.getPresentValue(
                asset[3], asset[1], START_TIME, 0.1e9
            )
        else:
            (assetCash, pv, _) = assetLibrary.getLiquidityTokenValue(
                asset, cashGroups[currencyId - 1], markets[currencyId - 1], [], START_TIME
            )
            totalPV[currencyId - 1] += pv
            totalPV[currencyId - 1] += assetCash

    assert totalPV == assetValues

    for (i, v) in enumerate(assetValues):
        if v == 0:
            assert assetValuesRiskAdjusted[i] == 0
        else:
            assert v > assetValuesRiskAdjusted[i]

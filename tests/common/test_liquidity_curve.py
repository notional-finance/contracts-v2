import random

import pytest
from brownie.test import given, strategy
from pytest import approx

BASIS_POINT = 10000
SECONDS_IN_YEAR = 31536000


@pytest.fixture(scope="module", autouse=True)
def liquidityCurve(MockLiquidityCurve, accounts):
    return accounts[0].deploy(MockLiquidityCurve)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@given(
    fCashAmount=strategy("int256", min_value=-100e18, max_value=100e18),
    timeToMaturity=strategy("uint32", min_value=1, max_value=SECONDS_IN_YEAR * 10),
    totalCurrentCash=strategy("uint128", min_value=0, max_value=100e18),
    totalfCash=strategy("uint128", min_value=0, max_value=100e18),
)
def test_exchange_rate(liquidityCurve, fCashAmount, timeToMaturity, totalCurrentCash, totalfCash):
    """
    Tests that the exchange rate will never return a value below 1 before accounting for fees.
    """
    if fCashAmount < 0 and totalfCash < -fCashAmount:
        return

    marketState = (totalfCash, totalCurrentCash, 0, 1.1e9, 0.1e9)
    cashGroup = (1e5, 25)
    (rateAnchor, success) = liquidityCurve.getNewRateAnchor(marketState, cashGroup, timeToMaturity)

    if not success:
        return

    (exchangeRate, success) = liquidityCurve.getExchangeRate(
        (totalfCash, totalCurrentCash, 0, rateAnchor, 0.1e9), cashGroup, timeToMaturity, fCashAmount
    )

    if success:
        assert exchangeRate > 1e9
    else:
        assert exchangeRate == 0


@given(
    fCashAmount=strategy("int256", min_value=-100e18, max_value=100e18, exclude=[0]),
    proportion=strategy("uint128", min_value=0.25e18, max_value=0.75e18),
    liquidityFee=strategy("uint256", min_value=BASIS_POINT, max_value=50 * BASIS_POINT),
    rateScalar=strategy("uint256", min_value=20, max_value=200),
)
@pytest.mark.skip
def test_rate_anchor_update(liquidityCurve, fCashAmount, proportion, liquidityFee, rateScalar):
    # test that for a given proportion and fCash amount, no matter what the time to maturity is
    # the implied rate before and after will be constant
    totalfCash = ((1e18 - proportion) * 1000e18) / 1e18
    totalCurrentCash = (proportion * 1000e18) / 1e18

    timeToMaturities = [random.randint(1, SECONDS_IN_YEAR * 10) for i in range(10)]
    postTradeImpliedRate = 0

    for timeToMaturity in timeToMaturities:
        # TODO: what should this be where timeToMaturity > than 5 years? we're getting
        # negative exchange rates
        marketState = (totalfCash, totalCurrentCash, 0, 1.5e9, 0.5e9)
        cashGroup = (liquidityFee, rateScalar)

        (newMarketState, success) = liquidityCurve.tradeCalculation(
            marketState, cashGroup, fCashAmount, timeToMaturity
        )

        assert success
        if postTradeImpliedRate == 0:
            postTradeImpliedRate = newMarketState[4]
        else:
            postTradeImpliedRate == approx(newMarketState[4], 5)


@given(
    rateAnchor=strategy("uint256", min_value=1e9, max_value=1.4e9, exclude=[1e9]),
    timeToMaturity=strategy("uint256", min_value=1, max_value=SECONDS_IN_YEAR * 10),
)
def test_initialize_rate_anchor(liquidityCurve, rateAnchor, timeToMaturity):
    newRateAnchor = liquidityCurve.initializeRateAnchor(rateAnchor, timeToMaturity)
    assert newRateAnchor >= 1e9

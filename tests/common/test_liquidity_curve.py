import math

import pytest
from brownie.test import given, strategy

SECONDS_IN_DAY = 86400
RATE_PRECISION = 1e6
NORMALIZED_RATE_TIME = 31104000


@pytest.fixture(scope="module", autouse=True)
def market(MockMarket, accounts):
    return accounts[0].deploy(MockMarket)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


# def test_get_uint(market):
#     print(market.getUint64(1e6))
#     assert False


@given(
    proportion=strategy("uint256", min_value=0.01 * RATE_PRECISION, max_value=100 * RATE_PRECISION)
)
def test_log_proportion(market, proportion):
    (lnProportion, success) = market.logProportion(proportion)

    assert success
    assert lnProportion == math.log(proportion)


@given(
    proportion=strategy(
        "uint256", min_value=0.001 * RATE_PRECISION, max_value=0.999 * RATE_PRECISION
    )
)
def test_exchange_rate_proportion(market, proportion):
    # Tests exchange rate proportion while holding rateAnchor and rateScalar constant
    timeToMaturity = SECONDS_IN_DAY
    totalfCash = 1e18
    totalCurrentCash = totalfCash * (RATE_PRECISION - proportion) / proportion
    rateAnchor = 1.05 * RATE_PRECISION
    marketState = (totalfCash, totalCurrentCash, 0, rateAnchor, 0)

    rateScalar = 10
    assetRate = (1e18, 1e8, 1e6, 1e18, 0, 0)

    (exchangeRate, success) = market.getExchangeRate(
        marketState, assetRate, rateScalar, timeToMaturity, 0
    )

    assert success
    assert math.trunc(exchangeRate / 10) == math.trunc(
        (math.log(proportion) / rateScalar + rateAnchor) / 10
    )


@given(
    # Annualized rates between 1% and 20%
    gRateAnchor=strategy("uint", min_value=0.01 * RATE_PRECISION, max_value=0.20 * RATE_PRECISION),
    # Days between 1 and 40 years
    timeToMaturity=strategy("uint", min_value=1, max_value=14400),
)
def test_initialized_rate_anchor(market, gRateAnchor, timeToMaturity):
    ttmSeconds = timeToMaturity * SECONDS_IN_DAY
    result = market.initializeRateAnchor(gRateAnchor + RATE_PRECISION, ttmSeconds)

    pyResult = math.exp((ttmSeconds / NORMALIZED_RATE_TIME) * (gRateAnchor / RATE_PRECISION))
    pyResult = math.trunc(pyResult * RATE_PRECISION)

    assert result == pyResult


@given(
    rateAnchor=strategy("uint", min_value=0.01 * RATE_PRECISION, max_value=0.50 * RATE_PRECISION)
)
def test_implied_rate(market, rateAnchor):
    timeToMaturity = NORMALIZED_RATE_TIME
    totalfCash = 1e18
    totalCurrentCash = 1e18
    rateAnchor = (rateAnchor * RATE_PRECISION) + RATE_PRECISION
    marketState = (totalfCash, totalCurrentCash, 0, rateAnchor, 0)

    rateScalar = 1
    assetRate = (1e18, 1e8, 1e6, 1e18, 0, 0)

    (impliedRate, success) = market.getImpliedRate(
        marketState, assetRate, rateScalar, timeToMaturity
    )

    assert impliedRate == math.log(rateAnchor / RATE_PRECISION) * RATE_PRECISION


@given(
    initRate=strategy("uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION),
    # Days between 30 and 10 years
    timeToMaturity=strategy("uint", min_value=30, max_value=3600),
)
@pytest.mark.only
def test_new_rate_anchor(market, initRate, timeToMaturity):
    totalfCash = 1e18
    totalCurrentCash = 1e18
    rateAnchor = initRate + RATE_PRECISION
    rateScalar = 100
    assetRate = (1e18, 1e8, 1e6, 1e18, 0, 0)

    initialTimeToMaturity = timeToMaturity * SECONDS_IN_DAY

    (impliedRate, success) = market.getImpliedRate(
        (totalfCash, totalCurrentCash, 0, rateAnchor, 0),
        assetRate,
        rateScalar * NORMALIZED_RATE_TIME / initialTimeToMaturity,
        initialTimeToMaturity,
    )

    # Get a range of time to maturities as the market rolls down
    rollDownMaturities = [math.trunc(initialTimeToMaturity / i) - 1 for i in range(1, 5)]
    prevRateAnchor = rateAnchor
    print("begin here", initRate, timeToMaturity, rollDownMaturities)
    for t in rollDownMaturities:
        print("previous rate anchor", prevRateAnchor)
        print("roll down maturity", t)
        (newRateAnchor, success) = market.getNewRateAnchor(
            (totalfCash, totalCurrentCash, 0, prevRateAnchor, impliedRate),
            assetRate,
            rateScalar * NORMALIZED_RATE_TIME / t,
            t,
        )

        (newImpliedRate, success) = market.getImpliedRate(
            (totalfCash, totalCurrentCash, 0, newRateAnchor, impliedRate),
            assetRate,
            rateScalar * NORMALIZED_RATE_TIME / t,
            t,
        )

        # prevRateAnchor = newRateAnchor
        print("new implied rate", newImpliedRate)
        # print("new rate anchor", newRateAnchor)
        # print("set new prev rate anchor", prevRateAnchor)
        # assert newImpliedRate == impliedRate
        # print("end loop")
    assert False


#
# @given(
#    fCashAmount=strategy("int256", min_value=-100e18, max_value=100e18, exclude=[0]),
#    proportion=strategy("uint128", min_value=0.25e18, max_value=0.75e18),
#    liquidityFee=strategy("uint256", min_value=BASIS_POINT, max_value=50 * BASIS_POINT),
#    rateScalar=strategy("uint256", min_value=20, max_value=200),
# )
# @pytest.mark.skip
# def test_rate_anchor_update(liquidityCurve, fCashAmount, proportion, liquidityFee, rateScalar):
#    # test that for a given proportion and fCash amount, no matter what the time to maturity is
#    # the implied rate before and after will be constant
#    totalfCash = ((1e18 - proportion) * 1000e18) / 1e18
#    totalCurrentCash = (proportion * 1000e18) / 1e18
#
#    timeToMaturities = [random.randint(1, SECONDS_IN_YEAR * 10) for i in range(10)]
#    postTradeImpliedRate = 0
#
#    for timeToMaturity in timeToMaturities:
#        # TODO: what should this be where timeToMaturity > than 5 years? we're getting
#        # negative exchange rates
#        marketState = (totalfCash, totalCurrentCash, 0, 1.5e9, 0.5e9)
#        cashGroup = (liquidityFee, rateScalar)
#
#        (newMarketState, success) = liquidityCurve.tradeCalculation(
#            marketState, cashGroup, fCashAmount, timeToMaturity
#        )
#
#        assert success
#        if postTradeImpliedRate == 0:
#            postTradeImpliedRate = newMarketState[4]
#        else:
#            postTradeImpliedRate == approx(newMarketState[4], 5)
#
#
# @given(
#    rateAnchor=strategy("uint256", min_value=1e9, max_value=1.4e9, exclude=[1e9]),
#    timeToMaturity=strategy("uint256", min_value=1, max_value=SECONDS_IN_YEAR * 10),
# )
# def test_initialize_rate_anchor(liquidityCurve, rateAnchor, timeToMaturity):
#    newRateAnchor = liquidityCurve.initializeRateAnchor(rateAnchor, timeToMaturity)
#    assert newRateAnchor >= 1e9
#

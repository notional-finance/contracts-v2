import math

import pytest
from brownie.test import given, strategy

SECONDS_IN_DAY = 86400
RATE_PRECISION = 1e9
NORMALIZED_RATE_TIME = 31104000


@pytest.fixture(scope="module", autouse=True)
def market(MockMarket, accounts):
    return accounts[0].deploy(MockMarket)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


# def test_get_uint(market):
#     print(market.getUint64(1e9))
#     assert False


@given(
    proportion=strategy("int256", min_value=0.01 * RATE_PRECISION, max_value=100 * RATE_PRECISION)
)
def test_log_proportion(market, proportion):
    (lnProportion, success) = market.logProportion(proportion)

    assert success
    assert lnProportion == math.log(proportion)


def test_log_proportion_negative(market):
    (lnProportion, success) = market.logProportion(-RATE_PRECISION)
    assert not success


@given(
    proportion=strategy(
        "uint256", min_value=0.001 * RATE_PRECISION, max_value=0.999 * RATE_PRECISION
    )
)
def test_exchange_rate_proportion(market, proportion):
    # Tests exchange rate proportion while holding rateAnchor and rateScalar constant
    timeToMaturity = SECONDS_IN_DAY
    totalfCash = 1e18
    totalCashUnderlying = totalfCash * (RATE_PRECISION - proportion) / proportion
    rateAnchor = 1.05 * RATE_PRECISION
    rateScalar = 100

    (exchangeRate, success) = market.getExchangeRate(
        totalfCash, totalCashUnderlying, rateScalar, rateAnchor, timeToMaturity, 0
    )

    assert success
    assert (
        pytest.approx(math.trunc(math.log(proportion) / rateScalar + rateAnchor), abs=1)
        == exchangeRate
    )


@given(
    initRate=strategy("uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION),
    # Days between 30 months and 20 years
    timeToMaturity=strategy("uint", min_value=90, max_value=7200),
)
def test_implied_rate(market, initRate, timeToMaturity):
    totalfCash = 1e18
    totalCashUnderlying = 1e18
    rateAnchor = initRate + RATE_PRECISION
    rateScalar = 100
    initialTimeToMaturity = timeToMaturity * SECONDS_IN_DAY

    (rateAnchor, success) = market.getRateAnchor(
        totalfCash, initRate, totalCashUnderlying, rateScalar, initialTimeToMaturity
    )

    (impliedRate, success) = market.getImpliedRate(
        totalfCash, totalCashUnderlying, rateScalar, rateAnchor, initialTimeToMaturity
    )

    approxImpliedRate = math.trunc(
        math.log(rateAnchor / RATE_PRECISION)
        * RATE_PRECISION
        * NORMALIZED_RATE_TIME
        / initialTimeToMaturity
    )
    assert pytest.approx(approxImpliedRate, abs=10) == impliedRate

    # Ensure that the implied rate for given proportion remains the same as we roll down. The
    # rate anchor should be updated every time. The max roll down is over the course of a 90
    # day period.
    rollDownMaturities = [initialTimeToMaturity - i * 10 * SECONDS_IN_DAY for i in range(1, 9)]
    for t in rollDownMaturities:
        (rateAnchor, success) = market.getRateAnchor(
            totalfCash, impliedRate, totalCashUnderlying, rateScalar, t
        )

        (newImpliedRate, success) = market.getImpliedRate(
            totalfCash, totalCashUnderlying, rateScalar, rateAnchor, t
        )

        # The implied rate does decay on roll down do a small degree
        assert pytest.approx(newImpliedRate, rel=1e-5) == impliedRate


# @given(
#     initRate=strategy("uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION),
#     # Days between 30 months and 20 years
#     timeToMaturity=strategy("uint", min_value=90, max_value=7200),
# )
# def test_rate_oracle(market, timeWindow, previousTradeTime):
#     pass

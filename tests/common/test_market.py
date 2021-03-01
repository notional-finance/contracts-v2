import math

import pytest
from brownie.test import given, strategy
from tests.common.params import *


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
    totalfCash = 1e18
    totalCashUnderlying = totalfCash * (RATE_PRECISION - proportion) / proportion
    rateAnchor = 1.05 * RATE_PRECISION
    rateScalar = 100

    (exchangeRate, success) = market.getExchangeRate(
        totalfCash, totalCashUnderlying, rateScalar, rateAnchor, 0
    )

    assert success
    assert (
        pytest.approx(math.trunc(math.log(proportion) / rateScalar + rateAnchor), abs=1)
        == exchangeRate
    )


@given(initRate=impliedRateStrategy, timeToMaturity=timeToMaturityStrategy)
def test_implied_rate(market, initRate, timeToMaturity):
    totalfCash = 1e18
    totalCashUnderlying = 1e18
    rateAnchor = initRate + RATE_PRECISION
    rateScalar = 100
    initialTimeToMaturity = timeToMaturity * SECONDS_IN_DAY

    (rateAnchor, _) = market.getRateAnchor(
        totalfCash, initRate, totalCashUnderlying, rateScalar, initialTimeToMaturity
    )

    (impliedRate, _) = market.getImpliedRate(
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
        (rateAnchor, _) = market.getRateAnchor(
            totalfCash, impliedRate, totalCashUnderlying, rateScalar, t
        )

        (newImpliedRate, _) = market.getImpliedRate(
            totalfCash, totalCashUnderlying, rateScalar, rateAnchor, t
        )

        # The implied rate does decay on roll down do a small degree
        assert pytest.approx(newImpliedRate, abs=100) == impliedRate


@given(
    lastImpliedRate=strategy(
        "uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION
    ),
    oracleRate=strategy("uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION),
    # Random previous times
    previousTradeTime=strategy(
        "uint", min_value=START_TIME, max_value=START_TIME + 30 * SECONDS_IN_YEAR
    ),
    # Next trade between 0 seconds and 2 hours
    newBlockTime=strategy("uint", min_value=0, max_value=7200),
    # From seconds to an hour
    timeWindow=strategy("uint", min_value=30, max_value=3600),
)
def test_build_market(
    market, timeWindow, previousTradeTime, newBlockTime, oracleRate, lastImpliedRate
):
    maturity = 90 * SECONDS_IN_DAY
    blockTime = previousTradeTime + newBlockTime
    marketStorage = (
        1,
        maturity,
        1e18,
        2e18,
        3e18,
        lastImpliedRate,
        oracleRate,
        previousTradeTime,
        True,
    )
    settlementDate = blockTime - (blockTime % (90 * SECONDS_IN_DAY)) + (90 * SECONDS_IN_DAY)

    market.setMarketStorage(marketStorage, settlementDate)
    result = market.buildMarket(1, maturity, blockTime, True, timeWindow)

    if newBlockTime > timeWindow:
        # If past the time window, ensure that the oracle rate equals the last implied rate
        assert result[6] == lastImpliedRate
    else:
        # It should be the weighted average of the two
        weightedAvg = math.trunc(
            newBlockTime / timeWindow * lastImpliedRate
            + (1 - newBlockTime / timeWindow) * oracleRate
        )
        assert pytest.approx(weightedAvg, abs=10) == result[6]

    assert result[0] == 1  # currency id
    assert result[1] == maturity
    assert result[2] == 1e18
    assert result[3] == 2e18
    assert result[4] == 3e18
    assert result[5] == lastImpliedRate
    assert result[7] == previousTradeTime
    assert not result[8]

    # Test saving market
    newMarket = list(result)
    newMarket[2] = 2e18
    newMarket[3] = 3e18
    newMarket[4] = 4e18
    newMarket[5] = lastImpliedRate - 1
    newMarket[7] = previousTradeTime + 1
    market.setMarketStorage(tuple(newMarket), settlementDate)
    noSaveResult = market.buildMarket(1, maturity, blockTime, True, timeWindow)
    assert noSaveResult == result

    newMarket[8] = True
    market.setMarketStorage(tuple(newMarket), settlementDate)
    result = market.buildMarket(1, maturity, blockTime + 10, True, timeWindow)

    assert result[0] == 1  # currency id
    assert result[1] == maturity
    assert result[2] == 2e18
    assert result[3] == 3e18
    assert result[4] == 4e18
    assert result[5] == lastImpliedRate - 1
    assert result[7] == previousTradeTime + 1
    assert not result[8]

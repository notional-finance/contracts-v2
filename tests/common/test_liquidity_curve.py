import pytest
from brownie.test import given, strategy


@pytest.fixture(scope="module", autouse=True)
def liquidityCurve(MockLiquidityCurve, accounts):
    return accounts[0].deploy(MockLiquidityCurve)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@given(
    fCashAmount=strategy("int256", min_value=-100e18, max_value=100e18),
    timeToMaturity=strategy("uint32", min_value=1),
    totalCurrentCash=strategy("uint128", min_value=0, max_value=100e18),
    totalfCash=strategy("uint128", min_value=0, max_value=100e18),
)
@pytest.mark.only
def test_exchange_rate(liquidityCurve, fCashAmount, timeToMaturity, totalCurrentCash, totalfCash):
    if fCashAmount < 0 and totalfCash < -fCashAmount:
        return

    marketState = (totalfCash, totalCurrentCash, 0, 1.1e9, 0.1e9)
    cashGroup = (1e5, 100)
    (rateAnchor, success) = liquidityCurve.getNewRateAnchor(marketState, cashGroup, timeToMaturity)

    if not success:
        return

    (exchangeRate, success) = liquidityCurve.getExchangeRate(
        (totalfCash, totalCurrentCash, 0, rateAnchor, 0.1e9), cashGroup, fCashAmount, timeToMaturity
    )

    if success:
        assert exchangeRate > 1e9
    else:
        assert exchangeRate == 0

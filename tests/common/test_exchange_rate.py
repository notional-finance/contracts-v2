from itertools import product

import pytest


@pytest.fixture(scope="module", autouse=True)
def exchangeRate(MockExchangeRate, accounts):
    return accounts[0].deploy(MockExchangeRate)


@pytest.fixture(scope="module", autouse=True)
def aggregator(MockAggregator, accounts):
    return accounts[0].deploy(MockAggregator, 18)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


parameterNames = "rateDecimals,baseDecimals,quoteDecimals,mustInvert"
parameterValues = list(product([6, 8, 18], [6, 8, 18], [0, 6, 8, 18], [True, False]))


@pytest.mark.parametrize(parameterNames, parameterValues)
def test_fetch_exchange_rate(
    accounts, MockAggregator, exchangeRate, rateDecimals, baseDecimals, quoteDecimals, mustInvert
):
    aggregator = accounts[0].deploy(MockAggregator, rateDecimals)
    aggregator.setAnswer(10 ** rateDecimals / 100)

    rateStorage = (aggregator.address, rateDecimals, mustInvert, 120, 80)

    (
        erRateDecimals,
        erBaseDecimals,
        erQuoteDecimals,
        erRate,
        erBuffer,
        erHaircut,
    ) = exchangeRate.fetchExchangeRate(rateStorage, baseDecimals, quoteDecimals)

    if quoteDecimals == 0:
        assert erQuoteDecimals == 0
    else:
        assert erQuoteDecimals == 10 ** quoteDecimals

    assert erRateDecimals == 10 ** rateDecimals
    assert erBaseDecimals == 10 ** baseDecimals

    if mustInvert:
        assert erRate == 10 ** rateDecimals * 100
    else:
        assert erRate == 10 ** rateDecimals / 100


def test_convert_to_eth(exchangeRate):
    rate = (1e18, 1e6, 0, 0.01e18, 120, 80)

    eth = exchangeRate.convertToETH(rate, 0)
    assert eth == 0

    eth = exchangeRate.convertToETH(rate, -100e6)
    assert eth == -1.2e18

    eth = exchangeRate.convertToETH(rate, 100e6)
    assert eth == 0.8e18

    rate = (1e8, 1e8, 0, 10e8, 120, 80)

    eth = exchangeRate.convertToETH(rate, 0)
    assert eth == 0

    eth = exchangeRate.convertToETH(rate, -1e8)
    assert eth == -12e18

    eth = exchangeRate.convertToETH(rate, 1e8)
    assert eth == 8e18


def test_convert_eth_to(exchangeRate):
    rate = (1e18, 1e6, 0, 0.01e18, 120, 80)

    usdc = exchangeRate.convertETHTo(rate, 0)
    assert usdc == 0

    # No buffer or haircut on this function
    usdc = exchangeRate.convertETHTo(rate, -1e18)
    assert usdc == -100e6

    usdc = exchangeRate.convertETHTo(rate, 1e18)
    assert usdc == 100e6

    rate = (1e18, 1e6, 0, 10e18, 120, 80)

    usdc = exchangeRate.convertETHTo(rate, 0)
    assert usdc == 0

    # No buffer or haircut on this function
    usdc = exchangeRate.convertETHTo(rate, -1e18)
    assert usdc == -0.1e6

    usdc = exchangeRate.convertETHTo(rate, 1e18)
    assert usdc == 0.1e6


def test_convert_to_underlying(exchangeRate):
    rate = (1e8, 1e6, 1e8, 0.01e8, 120, 80)

    underlying = exchangeRate.convertToUnderlying(rate, 0)
    assert underlying == 0

    underlying = exchangeRate.convertToUnderlying(rate, -100e6)
    assert underlying == -1e8

    underlying = exchangeRate.convertToUnderlying(rate, 100e6)
    assert underlying == 1e8

    rate = (1e8, 1e6, 1e8, 10e8, 120, 80)

    underlying = exchangeRate.convertToUnderlying(rate, 0)
    assert underlying == 0

    underlying = exchangeRate.convertToUnderlying(rate, -100e6)
    assert underlying == -1000e8

    underlying = exchangeRate.convertToUnderlying(rate, 100e6)
    assert underlying == 1000e8


def test_convert_from_underlying(exchangeRate):
    rate = (1e8, 1e6, 1e8, 0.01e8, 120, 80)

    asset = exchangeRate.convertFromUnderlying(rate, 0)
    assert asset == 0

    asset = exchangeRate.convertFromUnderlying(rate, -1e8)
    assert asset == -100e6

    asset = exchangeRate.convertFromUnderlying(rate, 1e8)
    assert asset == 100e6

    rate = (1e8, 1e6, 1e8, 10e8, 120, 80)

    asset = exchangeRate.convertFromUnderlying(rate, 0)
    assert asset == 0

    asset = exchangeRate.convertFromUnderlying(rate, -1e8)
    assert asset == -0.1e6

    asset = exchangeRate.convertFromUnderlying(rate, 1e8)
    assert asset == 0.1e6

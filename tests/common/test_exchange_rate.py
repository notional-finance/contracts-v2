from itertools import product

import pytest


@pytest.fixture(scope="module", autouse=True)
def exchangeRate(MockExchangeRate, accounts):
    return accounts[0].deploy(MockExchangeRate)


@pytest.fixture(scope="module", autouse=True)
def assetRate(MockAssetRate, accounts):
    return accounts[0].deploy(MockAssetRate)


@pytest.fixture(scope="module", autouse=True)
def aggregator(MockAggregator, accounts):
    return accounts[0].deploy(MockAggregator, 18)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


parameterNames = "rateDecimals,baseDecimals,mustInvert"
parameterValues = list(product([6, 8, 18], [6, 8, 18], [True, False]))


@pytest.mark.parametrize(parameterNames, parameterValues)
def test_build_exchange_rate(
    accounts, MockAggregator, exchangeRate, rateDecimals, baseDecimals, mustInvert
):
    aggregator = accounts[0].deploy(MockAggregator, rateDecimals)
    aggregator.setAnswer(10 ** rateDecimals / 100)

    rateStorage = (aggregator.address, rateDecimals, mustInvert, 120, 80, 0, baseDecimals)

    exchangeRate.setETHRateMapping(1, rateStorage)

    (erRateDecimals, erBaseDecimals, erRate, erBuffer, erHaircut) = exchangeRate.buildExchangeRate(
        1
    )

    assert erBuffer == 120
    assert erHaircut == 80

    assert erRateDecimals == 10 ** rateDecimals
    assert erBaseDecimals == 10 ** baseDecimals

    if mustInvert:
        assert erRate == 10 ** rateDecimals * 100
    else:
        assert erRate == 10 ** rateDecimals / 100


@pytest.mark.parametrize(parameterNames, parameterValues)
@pytest.mark.only
def test_build_asset_rate(
    accounts, MockCToken, cTokenAggregator, assetRate, rateDecimals, baseDecimals, mustInvert
):
    rateDecimals = 18
    mustInvert = False

    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})
    cToken.setAnswer(10 ** rateDecimals / 100)

    rateStorage = (aggregator.address, rateDecimals, mustInvert, 0, 0, 0, baseDecimals)

    assetRate.setAssetRateMapping(1, rateStorage)

    (rateOracle, erRate, rateDecimalPlaces) = assetRate.buildAssetRate(1)

    assert rateOracle == aggregator.address
    assert rateDecimalPlaces == rateDecimals
    assert erRate == 10 ** rateDecimals / 100


def test_convert_to_eth(exchangeRate):
    rate = (1e18, 1e6, 0.01e18, 120, 80)

    eth = exchangeRate.convertToETH(rate, 0)
    assert eth == 0

    eth = exchangeRate.convertToETH(rate, -100e6)
    assert eth == -1.2e18

    eth = exchangeRate.convertToETH(rate, 100e6)
    assert eth == 0.8e18

    rate = (1e8, 1e8, 10e8, 120, 80)

    eth = exchangeRate.convertToETH(rate, 0)
    assert eth == 0

    eth = exchangeRate.convertToETH(rate, -1e8)
    assert eth == -12e18

    eth = exchangeRate.convertToETH(rate, 1e8)
    assert eth == 8e18


def test_convert_eth_to(exchangeRate):
    rate = (1e18, 1e6, 0.01e18, 120, 80)

    usdc = exchangeRate.convertETHTo(rate, 0)
    assert usdc == 0

    # No buffer or haircut on this function
    usdc = exchangeRate.convertETHTo(rate, -1e18)
    assert usdc == -100e6

    usdc = exchangeRate.convertETHTo(rate, 1e18)
    assert usdc == 100e6

    rate = (1e18, 1e6, 10e18, 120, 80)

    usdc = exchangeRate.convertETHTo(rate, 0)
    assert usdc == 0

    # No buffer or haircut on this function
    usdc = exchangeRate.convertETHTo(rate, -1e18)
    assert usdc == -0.1e6

    usdc = exchangeRate.convertETHTo(rate, 1e18)
    assert usdc == 0.1e6


def test_convert_internal_to_underlying(assetRate, aggregator):
    rate = (aggregator.address, 0.01e18, 18)

    underlying = assetRate.convertInternalToUnderlying(rate, 0)
    assert underlying == 0

    underlying = assetRate.convertInternalToUnderlying(rate, -100e9)
    assert underlying == -1e9

    underlying = assetRate.convertInternalToUnderlying(rate, 100e9)
    assert underlying == 1e9

    rate = (aggregator.address, 10e18, 18)

    underlying = assetRate.convertInternalToUnderlying(rate, 0)
    assert underlying == 0

    underlying = assetRate.convertInternalToUnderlying(rate, -100e9)
    assert underlying == -1000e9

    underlying = assetRate.convertInternalToUnderlying(rate, 100e9)
    assert underlying == 1000e9


def test_convert_from_underlying(assetRate, aggregator):
    rate = (aggregator.address, 0.01e18, 18)

    asset = assetRate.convertInternalFromUnderlying(rate, 0)
    assert asset == 0

    asset = assetRate.convertInternalFromUnderlying(rate, -1e9)
    assert asset == -100e9

    asset = assetRate.convertInternalFromUnderlying(rate, 1e9)
    assert asset == 100e9

    rate = (aggregator.address, 10e18, 18)

    asset = assetRate.convertInternalFromUnderlying(rate, 0)
    assert asset == 0

    asset = assetRate.convertInternalFromUnderlying(rate, -1e9)
    assert asset == -0.1e9

    asset = assetRate.convertInternalFromUnderlying(rate, 1e9)
    assert asset == 0.1e9

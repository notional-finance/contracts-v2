from itertools import product

import pytest
from brownie.convert.datatypes import Wei
from tests.common.params import START_TIME, START_TIME_TREF


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


parameterNames = "rateDecimals,mustInvert"
parameterValues = list(product([6, 8, 18], [True, False]))


@pytest.mark.parametrize(parameterNames, parameterValues)
def test_build_exchange_rate(accounts, MockAggregator, exchangeRate, rateDecimals, mustInvert):
    aggregator = accounts[0].deploy(MockAggregator, rateDecimals)
    aggregator.setAnswer(10 ** rateDecimals / 100)

    rateStorage = (aggregator.address, rateDecimals, mustInvert, 120, 80, 105)

    # Currency ID 1 == ETH, rates are hardcoded
    exchangeRate.setETHRateMapping(1, rateStorage)
    (
        erRateDecimals,
        erRate,
        erBuffer,
        erHaircut,
        liquidationDiscount,
    ) = exchangeRate.buildExchangeRate(1)

    assert erBuffer == 120
    assert erHaircut == 80
    assert liquidationDiscount == 105
    assert erRateDecimals == int(1e18)
    assert erRate == int(1e18)

    # This is a non-ETH currency
    exchangeRate.setETHRateMapping(2, rateStorage)

    (
        erRateDecimals,
        erRate,
        erBuffer,
        erHaircut,
        liquidationDiscount,
    ) = exchangeRate.buildExchangeRate(2)

    assert erBuffer == 120
    assert erHaircut == 80
    assert liquidationDiscount == 105
    assert erRateDecimals == 10 ** rateDecimals

    if mustInvert:
        assert erRate == 10 ** rateDecimals * 100
    else:
        assert erRate == 10 ** rateDecimals / 100

    aggregator2 = accounts[0].deploy(MockAggregator, 9)
    aggregator2.setAnswer(10 ** 8 / 200)

    rateStorage = (aggregator2.address, 8, mustInvert, 120, 80, 105)
    exchangeRate.setETHRateMapping(3, rateStorage)
    baseER = exchangeRate.buildExchangeRate(2)
    quoteER = exchangeRate.buildExchangeRate(3)

    computedER = exchangeRate.exchangeRate(baseER, quoteER)
    assert (computedER * quoteER[1]) / int(1e8) == baseER[1]


@pytest.mark.parametrize(parameterNames, parameterValues)
def test_build_asset_rate(
    accounts, MockCToken, cTokenAggregator, assetRate, rateDecimals, mustInvert
):
    underlyingDecimals = rateDecimals
    rateDecimals = 18 + (underlyingDecimals - 8)

    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})
    cToken.setAnswer(10 ** rateDecimals / 100)

    rateStorage = (aggregator.address, underlyingDecimals)

    assetRate.setAssetRateMapping(1, rateStorage)

    (rateOracle, erRate, underlying) = assetRate.buildAssetRate(1)

    assert rateOracle == aggregator.address
    assert erRate == 10 ** rateDecimals / 100
    assert underlying == 10 ** underlyingDecimals


def test_convert_to_eth(exchangeRate):
    # All internal balances are in 1e8 precision
    rate = (1e18, 0.01e18, 120, 80, 106)

    eth = exchangeRate.convertToETH((1e18, 1e18, 120, 80, 106), 1e8)
    assert eth == 0.8e8

    eth = exchangeRate.convertToETH(rate, 0)
    assert eth == 0

    eth = exchangeRate.convertToETH(rate, -100e8)
    assert eth == -1.2e8

    eth = exchangeRate.convertToETH(rate, 100e8)
    assert eth == 0.8e8

    rate = (1e8, 10e8, 120, 80, 106)

    eth = exchangeRate.convertToETH(rate, 0)
    assert eth == 0

    eth = exchangeRate.convertToETH(rate, -1e8)
    assert eth == -12e8

    eth = exchangeRate.convertToETH(rate, 1e8)
    assert eth == 8e8


def test_convert_eth_to(exchangeRate):
    rate = (1e18, 0.01e18, 120, 80, 106)

    usdc = exchangeRate.convertETHTo((1e18, 1e18, 120, 80, 106), 1e8)
    assert usdc == 1e8

    usdc = exchangeRate.convertETHTo(rate, 0)
    assert usdc == 0

    # No buffer or haircut on this function
    usdc = exchangeRate.convertETHTo(rate, -1e8)
    assert usdc == -100e8

    usdc = exchangeRate.convertETHTo(rate, 1e8)
    assert usdc == 100e8

    rate = (1e18, 10e18, 120, 80, 106)

    usdc = exchangeRate.convertETHTo(rate, 0)
    assert usdc == 0

    # No buffer or haircut on this function
    usdc = exchangeRate.convertETHTo(rate, -1e8)
    assert usdc == -0.1e8

    usdc = exchangeRate.convertETHTo(rate, 1e8)
    assert usdc == 0.1e8


@pytest.mark.parametrize("underlyingDecimals", [6, 8, 18])
def test_convert_internal_to_underlying(assetRate, aggregator, underlyingDecimals):
    ar = 0.01 * (10 ** (18 + (underlyingDecimals - 8)))
    rate = (aggregator.address, ar, 10 ** underlyingDecimals)

    asset = assetRate.convertInternalToUnderlying(
        (aggregator.address, ar * 100, 10 ** underlyingDecimals), 1e8
    )
    assert asset == 1e8

    underlying = assetRate.convertInternalToUnderlying(rate, 0)
    assert underlying == 0

    underlying = assetRate.convertInternalToUnderlying(rate, -100e8)
    assert underlying == -1e8

    underlying = assetRate.convertInternalToUnderlying(rate, 100e8)
    assert underlying == 1e8

    ar = 10 * (10 ** (18 + (underlyingDecimals - 8)))
    rate = (aggregator.address, ar, 10 ** underlyingDecimals)

    underlying = assetRate.convertInternalToUnderlying(rate, 0)
    assert underlying == 0

    underlying = assetRate.convertInternalToUnderlying(rate, -100e8)
    assert underlying == -1000e8

    underlying = assetRate.convertInternalToUnderlying(rate, 100e8)
    assert underlying == 1000e8


@pytest.mark.parametrize("underlyingDecimals", [6, 8, 18])
def test_convert_from_underlying(assetRate, aggregator, underlyingDecimals):
    ar = 0.01 * (10 ** (18 + (underlyingDecimals - 8)))
    rate = (aggregator.address, ar, 10 ** underlyingDecimals)

    asset = assetRate.convertInternalFromUnderlying(
        (aggregator.address, ar * 100, 10 ** underlyingDecimals), 1e8
    )
    assert asset == 1e8

    asset = assetRate.convertInternalFromUnderlying(rate, 0)
    assert asset == 0

    asset = assetRate.convertInternalFromUnderlying(rate, -1e8)
    assert asset == -100e8

    asset = assetRate.convertInternalFromUnderlying(rate, 1e8)
    assert asset == 100e8

    ar = 10 * (10 ** (18 + (underlyingDecimals - 8)))
    rate = (aggregator.address, ar, 10 ** underlyingDecimals)

    asset = assetRate.convertInternalFromUnderlying(rate, 0)
    assert asset == 0

    asset = assetRate.convertInternalFromUnderlying(rate, -1e8)
    assert asset == -0.1e8

    asset = assetRate.convertInternalFromUnderlying(rate, 1e8)
    assert asset == 0.1e8


@pytest.mark.parametrize("underlyingDecimals", [6, 8, 18])
def test_build_settlement_rate(
    accounts, MockCToken, cTokenAggregator, assetRate, underlyingDecimals
):
    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})
    rateSet = 0.01 * (10 ** (18 + (underlyingDecimals - 8)))
    cToken.setAnswer(rateSet)

    rateStorage = (aggregator.address, underlyingDecimals)
    assetRate.setAssetRateMapping(1, rateStorage)
    txn = assetRate.buildSettlementRate(1, START_TIME_TREF, START_TIME)
    (_, rateSetStored, savedUnderlying) = txn.return_value
    assert Wei(rateSet) == rateSetStored
    assert savedUnderlying == 10 ** underlyingDecimals
    assert txn.events.count("SetSettlementRate") == 1
    assert txn.events["SetSettlementRate"]["currencyId"] == 1
    assert txn.events["SetSettlementRate"]["maturity"] == START_TIME_TREF
    assert txn.events["SetSettlementRate"]["rate"] == rateSetStored

    # Once settlement rate is set it cannot change
    cToken.setAnswer(rateSet * 2)
    txn = assetRate.buildSettlementRate(1, START_TIME_TREF, START_TIME)
    (_, rateSetStored, savedUnderlying) = txn.return_value
    assert Wei(rateSet) == rateSetStored
    assert savedUnderlying == 10 ** underlyingDecimals
    assert txn.events.count("SetSettlementRate") == 0

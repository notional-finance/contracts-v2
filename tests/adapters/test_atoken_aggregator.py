import pytest

index = {
    "WBTC": 1001573271772776897703553383,
    "USDC": 1067315037100876527756950379,
    "DAI": 1063789629594536684899576895,
}

rate = {
    "WBTC": 43210452416428256909894,
    "USDC": 31326248097049171154093258,
    "DAI": 27514290726918360393543997,
}


@pytest.fixture(scope="module", autouse=True)
def lendingPool(MockLendingPool, accounts):
    return MockLendingPool.deploy({"from": accounts[0]})


@pytest.fixture(scope="module", autouse=True)
def assetRate(MockAssetRate, accounts):
    return MockAssetRate.deploy({"from": accounts[0]})


@pytest.fixture(scope="module", autouse=True)
def aggregators(lendingPool, MockERC20, MockAToken, aTokenAggregator, accounts):
    agg = {}
    for (name, decimals) in [("USDC", 6), ("WBTC", 8), ("DAI", 18)]:
        underlying = MockERC20.deploy(name, name, decimals, 0, {"from": accounts[0]})
        mockAToken = MockAToken.deploy(underlying.address, "a" + name, {"from": accounts[0]})
        agg[name] = aTokenAggregator.deploy(
            lendingPool.address, mockAToken.address, {"from": accounts[0]}
        )
        lendingPool.setReserveNormalizedIncome(underlying.address, index[name])
        lendingPool.setCurrentLiquidityRate(underlying.address, rate[name])

    return agg


def test_get_exchange_rates(aggregators):
    # Test that decimal conversion works
    exRate = aggregators["USDC"].getExchangeRateView()
    assert exRate == aggregators["USDC"].getExchangeRateStateful().return_value
    assert pytest.approx(exRate / 1e10 / 1e6) == 1.0673150371

    exRate = aggregators["WBTC"].getExchangeRateView()
    assert exRate == aggregators["WBTC"].getExchangeRateStateful().return_value
    assert pytest.approx(exRate / 1e10 / 1e8) == 1.0015732717

    exRate = aggregators["DAI"].getExchangeRateView()
    assert exRate == aggregators["DAI"].getExchangeRateStateful().return_value
    assert pytest.approx(exRate / 1e10 / 1e18) == 1.063789629


def test_get_annualized_rate(aggregators):
    supplyRate = aggregators["WBTC"].getAnnualizedSupplyRate()
    assert pytest.approx(supplyRate / 1e9) == 0.00004321

    supplyRate = aggregators["USDC"].getAnnualizedSupplyRate()
    assert pytest.approx(supplyRate / 1e9) == 0.03132624809

    supplyRate = aggregators["DAI"].getAnnualizedSupplyRate()
    assert pytest.approx(supplyRate / 1e9) == 0.02751429072


def test_asset_rates(aggregators, assetRate, accounts):
    assetRate.setAssetRateMapping(1, (aggregators["USDC"].address, 6))
    ar = assetRate.buildAssetRate(1).return_value
    underlying = assetRate.convertToUnderlying(ar, 100e8)
    asset = assetRate.convertFromUnderlying(ar, underlying)
    assert (underlying - asset) < 7e8
    assert pytest.approx(asset, abs=1) == 100e8

    assetRate.setAssetRateMapping(1, (aggregators["DAI"].address, 18))
    ar = assetRate.buildAssetRate(1).return_value
    underlying = assetRate.convertToUnderlying(ar, 100e8)
    asset = assetRate.convertFromUnderlying(ar, underlying)
    assert (underlying - asset) < 7e8
    assert pytest.approx(asset, abs=1) == 100e8

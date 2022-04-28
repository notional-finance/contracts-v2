from brownie import cTokenLegacyAggregator, cTokenV2Aggregator
import pytest
from brownie.network.state import Chain
from scripts.mainnet.EnvironmentConfig import getEnvironment

chain = Chain()


@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()


@pytest.fixture(autouse=True)
def env():
    return getEnvironment()

def test_eth_aggregator(env):
    ethAggregator = cTokenLegacyAggregator.deploy("0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5", {"from": env.notional.owner()})
    assert ethAggregator.getExchangeRateView() == ethAggregator.getExchangeRateStateful.call()

def test_dai_aggregator(env):
    daiAggregator = cTokenV2Aggregator.deploy("0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643", {"from": env.notional.owner()})
    assert daiAggregator.getExchangeRateView() == daiAggregator.getExchangeRateStateful.call()

def test_usdc_aggregator(env):
    usdcAggregator = cTokenLegacyAggregator.deploy("0x39aa39c021dfbae8fac545936693ac917d5e7563", {"from": env.notional.owner()})
    assert usdcAggregator.getExchangeRateView() == usdcAggregator.getExchangeRateStateful.call()

def test_wbtc_aggregator(env):
    wbtcAggregator = cTokenV2Aggregator.deploy("0xccf4429db6322d5c611ee964527d42e5d685dd6a", {"from": env.notional.owner()})
    assert wbtcAggregator.getExchangeRateView() == wbtcAggregator.getExchangeRateStateful.call()

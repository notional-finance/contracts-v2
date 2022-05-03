from brownie import cTokenLegacyAggregator, cTokenV2Aggregator, interface
import pytest
from brownie.test import given, strategy
from brownie.network.state import Chain
from scripts.mainnet.EnvironmentConfig import getEnvironment

chain = Chain()


@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()

@given(mineBlocks=strategy("uint", min_value=1, max_value=2000))
def test_eth_aggregator(mineBlocks):
    env = getEnvironment()
    ethAggregator = cTokenLegacyAggregator.deploy("0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5", {"from": env.notional.owner()})
    assert ethAggregator.getExchangeRateView() == ethAggregator.getExchangeRateStateful.call()
    chain.mine(mineBlocks)
    assert ethAggregator.getExchangeRateView() == ethAggregator.getExchangeRateStateful.call()

@given(mineBlocks=strategy("uint", min_value=1, max_value=2000))
def test_dai_aggregator(mineBlocks):
    env = getEnvironment()
    daiAggregator = cTokenV2Aggregator.deploy("0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643", {"from": env.notional.owner()})
    assert daiAggregator.getExchangeRateView() == daiAggregator.getExchangeRateStateful.call()
    chain.mine(mineBlocks)
    assert daiAggregator.getExchangeRateView() == daiAggregator.getExchangeRateStateful.call()

@given(mineBlocks=strategy("uint", min_value=1, max_value=2000))
def test_usdc_aggregator(mineBlocks):
    env = getEnvironment()
    usdcAggregator = cTokenLegacyAggregator.deploy("0x39aa39c021dfbae8fac545936693ac917d5e7563", {"from": env.notional.owner()})
    assert usdcAggregator.getExchangeRateView() == usdcAggregator.getExchangeRateStateful.call()
    chain.mine(mineBlocks)
    assert usdcAggregator.getExchangeRateView() == usdcAggregator.getExchangeRateStateful.call()

@given(mineBlocks=strategy("uint", min_value=1, max_value=2000))
def test_wbtc_aggregator(mineBlocks):
    env = getEnvironment()
    wbtcAggregator = cTokenV2Aggregator.deploy("0xccf4429db6322d5c611ee964527d42e5d685dd6a", {"from": env.notional.owner()})
    assert wbtcAggregator.getExchangeRateView() == wbtcAggregator.getExchangeRateStateful.call()
    chain.mine(mineBlocks)
    assert wbtcAggregator.getExchangeRateView() == wbtcAggregator.getExchangeRateStateful.call()

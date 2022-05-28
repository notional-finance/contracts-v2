import pytest
from brownie import cTokenLegacyAggregator, cTokenV2Aggregator
from brownie.network.state import Chain
from brownie.test import given, strategy
from scripts.mainnet.EnvironmentConfig import getEnvironment

chain = Chain()


@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()


@given(
    currencyId=strategy("uint", min_value=1, max_value=4),
    mineBlocks=strategy("uint", min_value=1, max_value=2000),
)
def test_aggregator_matches(mineBlocks, currencyId):
    # This test takes about 5:32 seconds to run
    env = getEnvironment()
    symbols = ["cETH", "cDAI", "cUSDC", "cWBTC"]
    if currencyId == 1 or currencyId == 3:
        aggregator = cTokenLegacyAggregator.deploy(
            env.tokens[symbols[currencyId - 1]].address, {"from": env.notional.owner()}
        )
    else:
        aggregator = cTokenV2Aggregator.deploy(
            env.tokens[symbols[currencyId - 1]].address, {"from": env.notional.owner()}
        )

    chain.mine(mineBlocks)
    assert aggregator.getExchangeRateView() == aggregator.getExchangeRateStateful.call()

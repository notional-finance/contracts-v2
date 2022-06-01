import pytest
from tests.helpers import initialize_environment


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    env = initialize_environment(accounts)
    env.token["DAI"].transfer(accounts[1], 100_000_000e18, {"from": accounts[0]})
    env.token["USDC"].transfer(accounts[1], 100_000_000e6, {"from": accounts[0]})
    env.token["DAI"].approve(env.notional.address, 2 ** 256 - 1, {"from": accounts[1]})
    env.token["USDC"].approve(env.notional.address, 2 ** 256 - 1, {"from": accounts[1]})

    env.cToken["DAI"].transfer(accounts[1], 10_000_000e8, {"from": accounts[0]})
    env.cToken["USDC"].transfer(accounts[1], 10_000_000e8, {"from": accounts[0]})
    env.cToken["DAI"].approve(env.notional.address, 2 ** 256 - 1, {"from": accounts[1]})
    env.cToken["USDC"].approve(env.notional.address, 2 ** 256 - 1, {"from": accounts[1]})

    return env


@pytest.fixture(scope="module", autouse=True)
def vault(SimpleStrategyVault, environment, accounts):
    v = SimpleStrategyVault.deploy(
        "Simple Strategy", "SIMP", environment.notional.address, 2, {"from": accounts[0]}
    )
    v.setExchangeRate(1e18)

    return v

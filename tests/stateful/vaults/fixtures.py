import pytest
from tests.helpers import initialize_environment
from tests.internal.vaults.fixtures import get_vault_config, set_flags


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

    env.token["DAI"].transfer(accounts[2], 100_000_000e18, {"from": accounts[0]})
    env.token["USDC"].transfer(accounts[2], 100_000_000e6, {"from": accounts[0]})
    env.token["DAI"].approve(env.notional.address, 2 ** 256 - 1, {"from": accounts[2]})
    env.token["USDC"].approve(env.notional.address, 2 ** 256 - 1, {"from": accounts[2]})

    env.cToken["DAI"].transfer(accounts[2], 10_000_000e8, {"from": accounts[0]})
    env.cToken["USDC"].transfer(accounts[2], 10_000_000e8, {"from": accounts[0]})
    env.cToken["DAI"].approve(env.notional.address, 2 ** 256 - 1, {"from": accounts[2]})
    env.cToken["USDC"].approve(env.notional.address, 2 ** 256 - 1, {"from": accounts[2]})

    return env


@pytest.fixture(scope="module", autouse=True)
def vault(SimpleStrategyVault, environment, accounts):
    v = SimpleStrategyVault.deploy(
        "Simple Strategy", environment.notional.address, 2, {"from": accounts[0]}
    )
    v.setExchangeRate(1e18)

    return v


@pytest.fixture(scope="module")
def escrowed_account(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1),
            minAccountBorrowSize=100,
        ),
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.95e18)

    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 25_000e18, True, "", {"from": accounts[2]}
    )

    return accounts[1]

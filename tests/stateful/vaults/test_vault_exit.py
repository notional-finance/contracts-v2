import brownie
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

    return env


@pytest.fixture(scope="module", autouse=True)
def vault(SimpleStrategyVault, environment, accounts):
    v = SimpleStrategyVault.deploy(
        "Simple Strategy", "SIMP", environment.notional.address, 2, {"from": accounts[0]}
    )
    v.setExchangeRate(1e18)

    return v


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_only_vault_exit(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ONLY_VAULT_EXIT=1), currencyId=2),
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    with brownie.reverts("Unauthorized"):
        # User account cannot directly exit vault
        environment.notional.exitVault(
            accounts[1], vault.address, 50_000e8, 10_000e8, 0, False, "", {"from": accounts[1]}
        )

    # Execution from vault is allowed
    environment.notional.exitVault(
        accounts[1], vault.address, 50_000e8, 100_000e8, 0, False, "", {"from": vault.address}
    )


def test_exit_vault_min_borrow(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2)
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    with brownie.reverts("Min Borrow"):
        # User account cannot directly exit vault
        environment.notional.exitVault(
            accounts[1], vault.address, 50_000e8, 10_000e8, 0, False, "", {"from": accounts[1]}
        )


# TODO: test useUnderlying
def test_exit_vault_transfer_from_account(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2)
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[1])

    # If vault share value < exit cost then we need to transfer from the account
    environment.notional.exitVault(
        accounts[1], vault.address, 50_000e8, 100_000e8, 0, False, "", {"from": accounts[1]}
    )

    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getCurrentVaultState(vault).dict()

    assert balanceAfter - balanceBefore < 0
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == 0
    assert vaultAccount["maturity"] == environment.notional.getCurrentVaultMaturity(vault)
    assert vaultAccount["escrowedAssetCash"] == 0
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 50_000e8

    assert vaultState["totalfCash"] == 0
    assert vaultState["totalfCash"] == vaultState["totalfCashRequiringSettlement"]
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]


def test_exit_vault_transfer_to_account(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2)
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 200_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[1])

    # If vault share value > exit cost then we transfer to the account
    environment.notional.exitVault(
        accounts[1], vault.address, 150_000e8, 100_000e8, 0, False, "", {"from": accounts[1]}
    )

    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getCurrentVaultState(vault).dict()

    assert balanceAfter - balanceBefore > 0
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == 0
    assert vaultAccount["maturity"] == environment.notional.getCurrentVaultMaturity(vault)
    assert vaultAccount["escrowedAssetCash"] == 0
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 150_000e8

    assert vaultState["totalfCash"] == 0
    assert vaultState["totalfCash"] == vaultState["totalfCashRequiringSettlement"]
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]


def test_exit_vault_insufficient_collateral(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2)
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    # Cannot exit a vault below min collateral ratio
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.exitVault(
            accounts[1], vault.address, 10_000e8, 0, 0, False, "", {"from": accounts[1]}
        )


# def test_exit_vault_lending_fails(environment, accounts):

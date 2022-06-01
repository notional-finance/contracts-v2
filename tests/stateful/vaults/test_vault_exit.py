import brownie
import pytest
from brownie.network.state import Chain
from fixtures import *
from tests.helpers import initialize_environment
from tests.internal.vaults.fixtures import get_vault_config, set_flags

chain = Chain()


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
@pytest.mark.only
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

    (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, environment.notional.getCurrentVaultMaturity(vault), 0, chain.time()
    )

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

    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-9) == amountAsset - 50_000e8 * 50
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


@pytest.mark.only
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

    (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, environment.notional.getCurrentVaultMaturity(vault), 0, chain.time()
    )

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

    assert pytest.approx(balanceAfter - balanceBefore, rel=1e9) == 150_000e8 * 50 - amountAsset
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

# def test_exit_vault_after_settlement(environment, vault, accounts):
# def test_exit_vault_during_settlement(environment, vault, accounts):
# def test_exit_vault_with_escrowed_asset_cash(environment, vault, accounts):

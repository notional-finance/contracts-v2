import brownie
import pytest
from tests.helpers import initialize_environment
from tests.internal.vaults.fixtures import get_vault_config, set_flags

# from tests.stateful.invariants import check_system_invariants


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(scope="module", autouse=True)
def vault(SimpleStrategyVault, environment, accounts):
    return SimpleStrategyVault.deploy(
        "Simple Strategy", "SIMP", environment.notional.address, 2, {"from": accounts[0]}
    )


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.mark.only
def test_only_vault_entry(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True, ONLY_VAULT_ENTRY=1))
    )

    with brownie.reverts("Cannot Enter"):
        # User account cannot directly enter vault
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )

    # Execution from vault is allowed
    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": vault.address}
    )

    # Check that the user account is liquidated


@pytest.mark.only
def test_no_system_level_accounts(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True))
    )

    with brownie.reverts("Cannot Enter"):
        # Vault is disabled, cannot enter
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )


# @pytest.mark.only
# def test_enter_vault_in_settlement(environment, vault, accounts):

# def test_enter_vault_insufficient_deposit(environment, accounts):
# def test_enter_vault_with_matured_position_unable_to_settle(environment, accounts):
# def test_enter_vault_with_escrowed_asset_cash(environment, accounts):
# def test_enter_vault_insufficient_collateral(environment, accounts):
# def test_enter_vault_borrowing_failure(environment, accounts):
# def test_enter_vault_over_maximum_capacity(environment, accounts):
# def test_enter_vault_success(environment, accounts):
# def test_enter_vault_with_matured_position(environment, accounts):

# def test_exit_vault_normal(environment, accounts):
# def test_exit_vault_lending_fails(environment, accounts):
# def test_exit_vault_transfer_from_account(environment, accounts):
# def test_exit_vault_transfer_to_account(environment, accounts):
# def test_exit_vault_insufficient_collateral(environment, accounts):

# def test_roll_vault_disabled(environment, accounts):
# def test_roll_vault_lending_fails(environment, accounts):
# def test_roll_vault_insufficient_collateral(environment, accounts):
# def test_roll_vault_borrow_failure(environment, accounts):
# def test_roll_vault_over_maximum_capacity(environment, accounts):

# def test_deleverage_account(environment, accounts):
# def test_deleverage_account_sufficient_collateral(environment, accounts):
# def test_deleverage_account_over_deleverage(environment, accounts):

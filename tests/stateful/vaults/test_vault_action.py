import brownie
import pytest
from brownie.network.state import Chain
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF
from tests.helpers import initialize_environment
from tests.internal.vaults.fixtures import get_vault_config, set_flags

chain = Chain()


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


def test_initialize_and_enable_vault_authorization(environment, vault, accounts):
    with brownie.reverts():
        # Will revert on non-owner
        environment.notional.updateVault(
            vault.address, get_vault_config(flags=set_flags(0, ENABLED=True)), {"from": accounts[1]}
        )

    txn = environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True)), {"from": accounts[0]}
    )
    assert txn.events["VaultChange"]["vaultAddress"] == vault.address
    assert txn.events["VaultChange"]["enabled"]

    with brownie.reverts():
        # Will revert on non-owner
        environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[1]})

    environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[0]})


def test_pause_vault(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True))
    )
    environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[0]})

    with brownie.reverts("Cannot Enter"):
        # Vault is disabled, cannot enter
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )

    with brownie.reverts("No Roll Allowed"):
        # Vault is disabled, cannot enter
        environment.notional.rollVaultPosition(
            accounts[1], vault.address, 100_000, 100_000e8, (0, 0, "", ""), {"from": accounts[1]}
        )


def test_deposit_and_redeem_vault_auth(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True))
    )
    with brownie.reverts("Paused"):
        # This is not an activated vault
        environment.notional.depositVaultCashToStrategyTokens(
            START_TIME_TREF + SECONDS_IN_QUARTER, 100_000e8, "", {"from": accounts[1]}
        )

        environment.notional.redeemStrategyTokensToCash(
            START_TIME_TREF + SECONDS_IN_QUARTER, 100_000e8, "", {"from": accounts[1]}
        )


# @pytest.mark.only
# def test_deposit_asset_cash()
# def test_redeem_strategy_tokens()
# def test_settle_vault_no_manual_accounts()
# def test_settle_vault_partial_manual_accounts()
# def test_settle_vault_all_manual_accounts()
# def test_settle_vault_with_shortfall_no_manual_accounts()
# def test_settle_vault_with_shortfall_manual_accounts()

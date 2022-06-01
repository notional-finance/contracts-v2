import brownie
import pytest
from brownie.convert.datatypes import HexString
from fixtures import *
from tests.internal.vaults.fixtures import get_vault_config, set_flags

# from tests.stateful.invariants import check_system_invariants


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_only_vault_entry(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ONLY_VAULT_ENTRY=1), currencyId=2),
    )

    with brownie.reverts("Unauthorized"):
        # User account cannot directly enter vault
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )

    # Execution from vault is allowed
    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": vault.address}
    )


def test_no_system_level_accounts(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2)
    )

    with brownie.reverts():
        # No Zero Address
        environment.notional.enterVault(
            HexString(0, "bytes20"),
            vault.address,
            100_000e18,
            True,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )
        # No Notional Address
        environment.notional.enterVault(
            environment.notional.address,
            vault.address,
            100_000e18,
            True,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )
        # No nToken Address
        environment.notional.enterVault(
            environment.nToken["DAI"].address,
            vault.address,
            100_000e18,
            True,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )
        environment.notional.enterVault(
            environment.nToken["ETH"].address,
            vault.address,
            100_000e18,
            True,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )


def test_enter_vault_in_settlement(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )
    vault.setSettlement(True)

    with brownie.reverts("Cannot Enter"):
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )


def test_enter_vault_over_maximum_capacity(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, maxVaultBorrowSize=100_000e8, flags=set_flags(0, ENABLED=True)
        ),
    )

    with brownie.reverts("Insufficient capacity"):
        # User account borrowing over max vault size
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 100_001e8, 0, "", {"from": accounts[1]}
        )


def test_enter_vault_under_minimum_size(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    with brownie.reverts("Min Borrow"):
        # User account borrowing under minimum size
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 99_000e8, 0, "", {"from": accounts[1]}
        )


def test_enter_vault_borrowing_failure(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    with brownie.reverts("Trade failed, slippage"):
        # Fails on borrow slippage
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            True,
            100_000e8,
            0.01e9,
            "",
            {"from": accounts[1]},
        )

    with brownie.reverts("Trade failed, liquidity"):
        # Fails on liquidity
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 10_000_000e8, 0, "", {"from": accounts[1]}
        )


def test_enter_vault_insufficient_deposit(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    with brownie.reverts("Insufficient Collateral"):
        environment.notional.enterVault(
            accounts[1], vault.address, 0, True, 100_000e8, 0, "", {"from": accounts[1]}
        )

    with brownie.reverts("Insufficient Collateral"):
        environment.notional.enterVault(
            accounts[1], vault.address, 10_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )


def test_enter_vault_with_dai(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatio, _) = environment.notional.getVaultAccountCollateralRatio(accounts[1], vault)
    vaultState = environment.notional.getCurrentVaultState(vault).dict()

    assert 0.22e9 < collateralRatio and collateralRatio < 0.25e9
    assert vaultAccount["fCash"] == -100_000e8
    assert vaultAccount["maturity"] == environment.notional.getCurrentVaultMaturity(vault)
    assert vaultAccount["escrowedAssetCash"] == 0

    assert vaultState["totalfCash"] == -100_000e8
    assert vaultState["totalfCash"] == vaultState["totalfCashRequiringSettlement"]
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    totalValue = vault.convertStrategyToUnderlying(vaultState["totalStrategyTokens"])
    assert 122_000e18 < totalValue and totalValue < 125_000e18


# def test_enter_vault_with_matured_position_unable_to_settle(environment, vault, accounts):
# def test_enter_vault_with_matured_position(environment, accounts):
# def test_enter_vault_with_escrowed_asset_cash(environment, accounts):

# def test_enter_vault_with_cdai(environment, accounts):
# def test_enter_vault_with_usdc(environment, accounts):
# def test_enter_vault_with_cusdc(environment, accounts):
# def test_enter_vault_with_frax(environment, accounts):
# def test_enter_vault_with_afrax(environment, accounts):
# def test_enter_vault_with_eth(environment, accounts):

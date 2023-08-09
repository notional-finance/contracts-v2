import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF
from tests.helpers import get_lend_action
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_reenter_notional(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
        {"from": accounts[0]},
    )

    vault.setReenterNotional(True)
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    with brownie.reverts(dev_revert_msg="dev: reentered"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ALLOW_REENTRANCY=True), currencyId=2),
        100_000_000e8,
        {"from": accounts[0]},
    )

    environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.notional.enterVault(
        accounts[1], vault.address, 50_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )


def test_initialize_and_enable_vault_authorization(environment, vault, accounts):
    with brownie.reverts():
        # Will revert on non-owner
        environment.notional.updateVault(
            vault.address,
            get_vault_config(flags=set_flags(0, ENABLED=True)),
            100_000_000e8,
            {"from": accounts[1]},
        )

    txn = environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
        {"from": accounts[0]},
    )
    assert txn.events["VaultUpdated"]["vault"] == vault.address
    assert txn.events["VaultUpdated"]["enabled"]

    with brownie.reverts():
        # Will revert on non-owner
        environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[1]})

    environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[0]})


def test_pause_vault(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True)), 100_000_000e8
    )
    environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[0]})
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts():
        # Vault is disabled, cannot enter
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    with brownie.reverts():
        # Vault is disabled, cannot enter
        environment.notional.rollVaultPosition(
            accounts[1], vault.address, maturity, 100_000e8, 0, 0, 0, "", {"from": accounts[1]}
        )

def test_set_max_capacity(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True), minAccountBorrowSize=1e8),
        100_000_000e8,
    )
    with brownie.reverts("Ownable: caller is not the owner"):
        environment.notional.setMaxBorrowCapacity(vault.address, 100e8, {"from": accounts[1]})

    environment.notional.setMaxBorrowCapacity(vault.address, 100e8, {"from": accounts[0]})
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts("Max Capacity"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    environment.notional.enterVault(
        accounts[1], vault.address, 12e18, maturity, 50e8, 0, "", {"from": accounts[1]}
    )

def test_borrow_secondary_currency_fails_duplicate(environment, accounts, vault):
    with brownie.reverts():
        environment.notional.updateVault(
            vault.address,
            get_vault_config(
                currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[2, 0]
            ),
            100_000_000e8,
        )

    with brownie.reverts():
        environment.notional.updateVault(
            vault.address,
            get_vault_config(
                currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[0, 2]
            ),
            100_000_000e8,
        )

    with brownie.reverts():
        environment.notional.updateVault(
            vault.address,
            get_vault_config(
                currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[3, 3]
            ),
            100_000_000e8,
        )


def test_borrow_secondary_currency_fails_not_listed(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts():
        vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 0], [0, 0], [0, 0])

    # Reverts on zero currency id in prime cash
    with brownie.reverts():
        environment.notional.borrowSecondaryCurrencyToVault(
            accounts[1], maturity, [1e8, 0], [0, 0], [0, 0], {"from": accounts[1]}
        )

    with brownie.reverts("Ownable: caller is not the owner"):
        # Cannot update, unauthorized
        environment.notional.updateSecondaryBorrowCapacity(
            vault.address, 1, 100e8, {"from": accounts[1]}
        )

    with brownie.reverts():
        # Cannot update, not listed
        environment.notional.updateSecondaryBorrowCapacity(
            vault.address, 1, 100e8, {"from": environment.notional.owner()}
        )

def test_borrow_secondary_currency_fails_via_vault(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 3]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault.address, 1, 100e8, {"from": environment.notional.owner()}
    )

    with brownie.reverts():
        vault.borrowSecondaryCurrency(vault, maturity, [1e8, 1e8], [0, 0], [0, 0])

    check_system_invariants(environment, accounts, [vault])

def test_repay_secondary_currency_succeeds_over_max_capacity(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 0]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 100e8, {"from": environment.notional.owner()}
    )

    vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 0], [0, 0], [0, 0])

    # Lower the capacity
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 0.1e8, {"from": environment.notional.owner()}
    )

    # Can still repay existing debts
    accounts[0].transfer(vault.address, 50e18)
    vault.repaySecondaryCurrency(accounts[1], maturity, [0.5e8, 0], [0, 0], 0.5e18)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0, 0.5e8, 0.1e8)
    assert environment.notional.getSecondaryBorrow(vault.address, 1, maturity) == -0.5e8

    with brownie.reverts(""):
        vault.repaySecondaryCurrency(accounts[1], maturity, [0.6e8, 0], [0, 0], 0.6e18)

    # Clear the borrow
    vault.repaySecondaryCurrency(accounts[1], maturity, [0.5e8, 0], [0, 0], 0.5e18)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0, 0, 0.1e8)
    assert environment.notional.getSecondaryBorrow(vault.address, 1, maturity) == 0

    check_system_invariants(environment, accounts, [vault])

def test_revert_when_secondary_maturity_mismatch(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 3]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 100e8, {"from": environment.notional.owner()}
    )
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 3, 100e8, {"from": environment.notional.owner()}
    )

    vault.borrowSecondaryCurrency(accounts[2], maturity, [1e8, 1e8], [0, 0], [0, 0])
    vault.borrowSecondaryCurrency(
        accounts[1], maturity + SECONDS_IN_QUARTER, [1e8, 1e8], [0, 0], [0, 0]
    )

    with brownie.reverts():
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

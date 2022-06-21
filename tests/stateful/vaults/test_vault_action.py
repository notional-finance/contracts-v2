import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


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
    assert txn.events["VaultChange"]["vault"] == vault.address
    assert txn.events["VaultChange"]["enabled"]

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

    with brownie.reverts("Cannot Enter"):
        # Vault is disabled, cannot enter
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            True,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    with brownie.reverts("No Roll Allowed"):
        # Vault is disabled, cannot enter
        environment.notional.rollVaultPosition(
            accounts[1], vault.address, maturity, 100_000e8, (0, 0, ""), {"from": accounts[1]}
        )


def test_deposit_and_redeem_vault_auth(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True)), 100_000_000e8
    )

    with brownie.reverts("Paused"):
        # This is not an activated vault
        environment.notional.depositVaultCashToStrategyTokens(
            START_TIME_TREF + SECONDS_IN_QUARTER, 100_000e8, "", {"from": accounts[1]}
        )

        environment.notional.redeemStrategyTokensToCash(
            START_TIME_TREF + SECONDS_IN_QUARTER, 100_000e8, "", {"from": accounts[1]}
        )


def test_redeem_strategy_tokens(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettle(vault, maturity)
    assert underlyingCash == 100_000e18
    assert assetCash == 5_000_000e8

    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Redeems a portion of the strategy tokens to repay debt
    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Collateral ratio does not change when redeeming and depositing tokens, unless prices change
    assert collateralRatioBefore == collateralRatioAfter
    # Nothing about the vault account changes
    assert vaultAccountAfter == vaultAccountBefore

    assert vaultStateBefore["totalAssetCash"] == vaultStateAfter["totalAssetCash"] - 500_000e8
    assert (
        vaultStateBefore["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"] + 10_000e8
    )

    (assetCashAfter, underlyingCashAfter) = environment.notional.getCashRequiredToSettle(
        vault, maturity
    )
    assert underlyingCash - 10_000e18 == underlyingCashAfter
    assert assetCash - 500_000e8 == assetCashAfter

    check_system_invariants(environment, accounts, [vault])


def test_deposit_asset_cash(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    # Put some cash on the vault
    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettle(vault, maturity)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Redeems a portion of the strategy tokens to repay debt
    environment.notional.depositVaultCashToStrategyTokens(maturity, 250_000e8, "", {"from": vault})

    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Collateral ratio does not change when redeeming and depositing tokens, unless prices change
    assert collateralRatioBefore == collateralRatioAfter
    # Nothing about the vault account changes
    assert vaultAccountAfter == vaultAccountBefore

    assert vaultStateBefore["totalAssetCash"] == vaultStateAfter["totalAssetCash"] + 250_000e8
    assert (
        vaultStateBefore["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"] - 5_000e8
    )

    (assetCashAfter, underlyingCashAfter) = environment.notional.getCashRequiredToSettle(
        vault, maturity
    )
    assert underlyingCash + 5_000e18 == underlyingCashAfter
    assert assetCash + 250_000e8 == assetCashAfter

    check_system_invariants(environment, accounts, [vault])


def test_deposit_asset_cash_fails_collateral_ratio(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    # Lower the exchange rate, vault is insolvency right now
    vault.setExchangeRate(0.6e18)

    # Always possible to redeem strategy tokens to cash
    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    # Not possible to re-enter vault
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.depositVaultCashToStrategyTokens(
            maturity, 250_000e8, "", {"from": vault}
        )

    check_system_invariants(environment, accounts, [vault])


def test_settle_vault(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    with brownie.reverts("Cannot Settle"):
        # Cannot settle before maturity
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    chain.mine(1, timestamp=maturity)

    with brownie.reverts("Redeem all tokens"):
        # Cannot if the vault is reporting insufficient cash
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    # Settle the vault with sufficient cash
    environment.notional.redeemStrategyTokensToCash(maturity, 90_000e8, "", {"from": vault})

    vault.setExchangeRate(0.95e18)
    txn = environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    vaultState = environment.notional.getVaultState(vault, maturity)
    assert vaultState["isSettled"]
    assert vaultState["settlementStrategyTokenValue"] == 0.95e8
    assert "VaultShortfall" not in txn.events
    assert "ProtocolInsolvency" not in txn.events
    assert "VaultPauseStatus" not in txn.events

    with brownie.reverts("Cannot Settle"):
        # Cannot settle twice
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    check_system_invariants(environment, accounts, [vault])


def test_settle_vault_authentication(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True, ONLY_VAULT_SETTLE=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    with brownie.reverts("Cannot Settle"):
        # Cannot settle before maturity
        environment.notional.settleVault(vault, maturity, {"from": vault})

    with brownie.reverts("Unauthorized"):
        # Cannot settle before maturity
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    chain.mine(1, timestamp=maturity)

    with brownie.reverts("Unauthorized"):
        # Cannot if the vault is reporting insufficient cash
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    with brownie.reverts("Redeem all tokens"):
        # Cannot if the vault is reporting insufficient cash
        environment.notional.settleVault(vault, maturity, {"from": vault})

    # Settle the vault with sufficient cash
    environment.notional.redeemStrategyTokensToCash(maturity, 90_000e8, "", {"from": vault})

    vault.setExchangeRate(0.95e18)
    with brownie.reverts("Unauthorized"):
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    txn = environment.notional.settleVault(vault, maturity, {"from": vault})

    vaultState = environment.notional.getVaultState(vault, maturity)
    assert vaultState["isSettled"]
    assert vaultState["settlementStrategyTokenValue"] == 0.95e8
    assert "VaultShortfall" not in txn.events
    assert "ProtocolInsolvency" not in txn.events
    assert "VaultPauseStatus" not in txn.events

    with brownie.reverts("Unauthorized"):
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    with brownie.reverts("Cannot Settle"):
        # Cannot settle twice
        environment.notional.settleVault(vault, maturity, {"from": vault})

    check_system_invariants(environment, accounts, [vault])


def test_settle_vault_shortfall(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True, ONLY_VAULT_SETTLE=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    vault.setExchangeRate(0.808e18)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)

    environment.notional.redeemStrategyTokensToCash(
        maturity, vaultStateBefore["totalStrategyTokens"], "", {"from": vault}
    )

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False)

    (assetCashShortfall, _) = environment.notional.getCashRequiredToSettle(vault, maturity)
    reserveBalanceBefore = environment.notional.getReserveBalance(2)
    assert assetCashShortfall > 0 and assetCashShortfall < reserveBalanceBefore
    txn = environment.notional.settleVault(vault, maturity, {"from": vault})
    reserveBalanceAfter = environment.notional.getReserveBalance(2)

    vaultState = environment.notional.getVaultState(vault, maturity)
    assert vaultState["isSettled"]
    assert reserveBalanceAfter == reserveBalanceBefore - assetCashShortfall

    assert txn.events["VaultShortfall"]["currencyId"] == 2
    assert txn.events["VaultShortfall"]["vault"] == vault.address
    assert txn.events["VaultShortfall"]["shortfall"] == assetCashShortfall

    assert txn.events["VaultPauseStatus"]["vault"] == vault.address
    assert not txn.events["VaultPauseStatus"]["enabled"]

    # Vault is now disabled
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    with brownie.reverts("Cannot Enter"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            25_000e18,
            maturity,
            True,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    check_system_invariants(environment, accounts, [vault])


def test_settle_vault_insolvent(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True, ONLY_VAULT_SETTLE=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    maturity = environment.notional.getActiveMarkets(1)[0][1]
    vault.setExchangeRate(0.75e18)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)

    environment.notional.redeemStrategyTokensToCash(
        maturity, vaultStateBefore["totalStrategyTokens"], "", {"from": vault}
    )

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False)

    (assetCashShortfall, _) = environment.notional.getCashRequiredToSettle(vault, maturity)
    reserveBalanceBefore = environment.notional.getReserveBalance(2)
    txn = environment.notional.settleVault(vault, maturity, {"from": vault})
    reserveBalanceAfter = environment.notional.getReserveBalance(2)

    vaultState = environment.notional.getVaultState(vault, maturity)
    assert vaultState["isSettled"]
    assert vaultState["settlementStrategyTokenValue"] == 0.75e8
    assert reserveBalanceAfter == 0

    assert txn.events["VaultShortfall"]["currencyId"] == 2
    assert txn.events["VaultShortfall"]["vault"] == vault.address
    assert txn.events["VaultShortfall"]["shortfall"] == assetCashShortfall

    assert txn.events["ProtocolInsolvency"]["currencyId"] == 2
    assert txn.events["ProtocolInsolvency"]["vault"] == vault.address
    assert (
        txn.events["ProtocolInsolvency"]["shortfall"] == assetCashShortfall - reserveBalanceBefore
    )

    assert txn.events["VaultPauseStatus"]["vault"] == vault.address
    assert not txn.events["VaultPauseStatus"]["enabled"]

    # Vault is now disabled
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    with brownie.reverts("Cannot Enter"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            25_000e18,
            maturity,
            True,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    check_system_invariants(environment, accounts, [vault])


def test_borrow_secondary_currency_fails_duplicate(environment, accounts, vault):
    with brownie.reverts():
        environment.notional.updateVault(
            vault.address,
            get_vault_config(
                currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[2, 0, 0]
            ),
            100_000_000e8,
        )

    with brownie.reverts():
        environment.notional.updateVault(
            vault.address,
            get_vault_config(
                currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[0, 2, 0]
            ),
            100_000_000e8,
        )

    with brownie.reverts():
        environment.notional.updateVault(
            vault.address,
            get_vault_config(
                currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[0, 0, 2]
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
        vault.borrowSecondaryCurrency(1, maturity, 1e8, 0)

    with brownie.reverts("Paused"):
        environment.notional.borrowSecondaryCurrencyToVault(
            1, maturity, 1e8, 0, {"from": accounts[1]}
        )

    with brownie.reverts("Ownable: caller is not the owner"):
        # Cannot update, unauthorized
        environment.notional.updateSecondaryBorrowCapacity(
            vault.address, 1, 100e8, {"from": accounts[1]}
        )

    with brownie.reverts("Invalid Currency"):
        # Cannot update, not listed
        environment.notional.updateSecondaryBorrowCapacity(
            vault.address, 1, 100e8, {"from": environment.notional.owner()}
        )


def test_borrow_secondary_currency_fails_over_max_capacity(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 3, 0]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault.address, 1, 100e8, {"from": environment.notional.owner()}
    )

    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0, 100e8)

    txn = vault.borrowSecondaryCurrency(1, maturity, 1e8, 0)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (1e8, 100e8)
    assert environment.notional.getSecondaryBorrow(vault.address, 1, maturity) == 1e8
    assert txn.events["SecondaryBorrow"]["underlyingTokensTransferred"] == vault.balance()

    with brownie.reverts("Trade failed, slippage"):
        vault.borrowSecondaryCurrency(1, maturity, 1e8, 0.001e9)

    with brownie.reverts("Max Capacity"):
        vault.borrowSecondaryCurrency(1, maturity, 100e8, 0)


def test_repay_secondary_currency_succeeds_over_max_capacity(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 3, 0]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 100e8, {"from": environment.notional.owner()}
    )

    vault.borrowSecondaryCurrency(1, maturity, 1e8, 0)

    # Lower the capacity
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 0.1e8, {"from": environment.notional.owner()}
    )

    # Can still repay existing debts
    environment.cToken["ETH"].transfer(vault.address, 50e8, {"from": accounts[0]})
    vault.repaySecondaryCurrency(1, maturity, 0.5e8, 0, environment.cToken["ETH"].address)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0.5e8, 0.1e8)
    assert environment.notional.getSecondaryBorrow(vault.address, 1, maturity) == 0.5e8

    with brownie.reverts(""):
        vault.repaySecondaryCurrency(1, maturity, 0.6e8, 0, environment.cToken["ETH"].address)

    # Clear the borrow
    vault.repaySecondaryCurrency(1, maturity, 0.5e8, 0, environment.cToken["ETH"].address)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0, 0.1e8)
    assert environment.notional.getSecondaryBorrow(vault.address, 1, maturity) == 0


def test_settle_fails_on_secondary_currency_balance(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 3, 0]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 100e8, {"from": environment.notional.owner()}
    )
    vault.borrowSecondaryCurrency(1, maturity, 1e8, 0)

    chain.mine(1, maturity)

    with brownie.reverts("Unpaid Borrow"):
        environment.notional.settleVault(vault.address, maturity, {"from": accounts[1]})

    environment.cToken["ETH"].transfer(vault.address, 50e8, {"from": accounts[0]})
    vault.repaySecondaryCurrency(1, maturity, 1e8, 0, environment.cToken["ETH"].address)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0, 100e8)
    assert environment.notional.getSecondaryBorrow(vault.address, 1, maturity) == 0

    environment.notional.settleVault(vault.address, maturity, {"from": accounts[1]})


@pytest.mark.todo
def test_repay_secondary_currency_succeeds_at_zero_interest(environment, accounts, vault):
    pass


@pytest.mark.todo
def test_governance_reduce_borrow_capacity(environment, accounts, vault):
    pass

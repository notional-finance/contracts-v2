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
    with brownie.reverts("Reentrant call"):
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

    with brownie.reverts("Cannot Enter"):
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

    with brownie.reverts("No Roll Allowed"):
        # Vault is disabled, cannot enter
        environment.notional.rollVaultPosition(
            accounts[1], vault.address, maturity, 100_000e8, 0, 0, 0, "", {"from": accounts[1]}
        )


def test_set_max_capacity(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True), minAccountBorrowSize=1),
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
        accounts[1], vault.address, 100e18, maturity, 50e8, 0, "", {"from": accounts[1]}
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
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettle(vault, maturity)
    assert underlyingCash == Wei(100_000e18) + Wei(1e10)  # adds an adjustment
    assert assetCash == 5_000_000e8

    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Redeems a portion of the strategy tokens to repay debt
    vault.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": accounts[0]})

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
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    # Put some cash on the vault
    vault.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": accounts[0]})

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettle(vault, maturity)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Redeems a portion of the strategy tokens to repay debt
    vault.depositVaultCashToStrategyTokens(maturity, 250_000e8, "", {"from": accounts[0]})

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
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    # Lower the exchange rate, vault is insolvency right now
    vault.setExchangeRate(0.6e18)

    # Always possible to redeem strategy tokens to cash
    vault.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": accounts[0]})

    # Not possible to re-enter vault
    with brownie.reverts("Insufficient Collateral"):
        vault.depositVaultCashToStrategyTokens(maturity, 250_000e8, "", {"from": accounts[0]})

    check_system_invariants(environment, accounts, [vault])


def test_settle_vault(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": accounts[0]})

    with brownie.reverts("Cannot Settle"):
        # Cannot settle before maturity
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    chain.mine(1, timestamp=maturity)

    with brownie.reverts("Redeem all tokens"):
        # Cannot if the vault is reporting insufficient cash
        environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    # Settle the vault with sufficient cash
    vault.redeemStrategyTokensToCash(maturity, 90_000e8, "", {"from": accounts[0]})

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
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": accounts[0]})

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
    vault.redeemStrategyTokensToCash(maturity, 90_000e8, "", {"from": accounts[0]})

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
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.808e18)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)

    vault.redeemStrategyTokensToCash(
        maturity, vaultStateBefore["totalStrategyTokens"], "", {"from": accounts[0]}
    )

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False)

    (assetCashShortfall, _) = environment.notional.getCashRequiredToSettle(vault, maturity)
    reserveBalanceBefore = environment.notional.getReserveBalance(2)
    assert assetCashShortfall > 0 and assetCashShortfall < reserveBalanceBefore
    txn = environment.notional.settleVault(vault, maturity, {"from": accounts[0]})
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
            accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_settle_vault_insolvent(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    maturity = environment.notional.getActiveMarkets(1)[0][1]
    vault.setExchangeRate(0.75e18)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)

    vault.redeemStrategyTokensToCash(
        maturity, vaultStateBefore["totalStrategyTokens"], "", {"from": accounts[0]}
    )

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False)

    (assetCashShortfall, _) = environment.notional.getCashRequiredToSettle(vault, maturity)
    reserveBalanceBefore = environment.notional.getReserveBalance(2)
    txn = environment.notional.settleVault(vault, maturity, {"from": accounts[0]})
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
            accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


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

    with brownie.reverts("Paused"):
        environment.notional.borrowSecondaryCurrencyToVault(
            accounts[1], maturity, [1e8, 0], [0, 0], [0, 0], {"from": accounts[1]}
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
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 3]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault.address, 1, 100e8, {"from": environment.notional.owner()}
    )

    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0, 100e8)

    txn = vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 0], [0, 0], [0, 0])
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (1e8, 100e8)
    assert (
        environment.notional.getSecondaryBorrow(vault.address, 1, maturity)["totalfCashBorrowed"]
        == 1e8
    )
    assert txn.events["SecondaryBorrow"]["underlyingTokensTransferred"][0] == vault.balance()

    with brownie.reverts("Trade failed, slippage"):
        vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 0], [0.001e9, 0], [0, 0])

    with brownie.reverts("Max Capacity"):
        vault.borrowSecondaryCurrency(accounts[1], maturity, [100e8, 0], [0, 0], [0, 0])


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


def test_borrow_secondary_currency_account_factors(environment, accounts, vault):
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
    environment.notional.updateSecondaryBorrowCapacity(
        vault.address, 3, 100e8, {"from": environment.notional.owner()}
    )

    vault.borrowSecondaryCurrency(accounts[1], maturity, [4e8, 5e8], [0, 0], [0, 0])
    (debtMaturity, debtShares, strategyTokens) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtMaturity == maturity
    assert debtShares[0] == 4e8
    assert debtShares[1] == 5e8
    assert strategyTokens == 0

    vault.borrowSecondaryCurrency(accounts[1], maturity, [0, 1e8], [0, 0], [0, 0])
    (debtMaturity, debtShares, strategyTokens) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtMaturity == maturity
    assert debtShares[0] == 4e8
    assert debtShares[1] == 6e8
    assert strategyTokens == 0

    (totalfCashBorrowedETH, totalDebtSharesETH, _) = environment.notional.getSecondaryBorrow(
        vault.address, 1, maturity
    )
    (totalfCashBorrowedUSDC, totalDebtSharesUSDC, _) = environment.notional.getSecondaryBorrow(
        vault.address, 3, maturity
    )
    assert totalfCashBorrowedETH == 4e8
    assert totalfCashBorrowedUSDC == 6e8
    assert totalfCashBorrowedETH == totalDebtSharesETH
    assert totalfCashBorrowedUSDC == totalDebtSharesUSDC

    # Reverts when attempting to borrow at a different maturity
    with brownie.reverts("Invalid Secondary Maturity"):
        vault.borrowSecondaryCurrency(
            accounts[1], maturity + SECONDS_IN_QUARTER, [1e8, 0], [0, 0], [0, 0]
        )

    environment.token["USDC"].transfer(vault.address, 100e6, {"from": accounts[0]})
    accounts[0].transfer(vault.address, 5e18)

    # Repaying borrows
    vault.repaySecondaryCurrency(accounts[1], 3, maturity, 1e8, 0)
    (debtMaturity, debtShares, strategyTokens) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtMaturity == maturity
    assert debtShares[0] == 4e8
    assert debtShares[1] == 5e8
    assert strategyTokens == 0

    vault.repaySecondaryCurrency(accounts[1], 1, maturity, 4e8, 0)
    (debtMaturity, debtShares, strategyTokens) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtMaturity == maturity
    assert debtShares[0] == 0
    assert debtShares[1] == 5e8
    assert strategyTokens == 0

    vault.repaySecondaryCurrency(accounts[1], 3, maturity, 5e8, 0)
    (debtMaturity, debtShares, strategyTokens) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtMaturity == 0  # This must be cleared now
    assert debtShares[0] == 0
    assert debtShares[1] == 0
    assert strategyTokens == 0

    (totalfCashBorrowedETH, totalDebtSharesETH, _) = environment.notional.getSecondaryBorrow(
        vault.address, 1, maturity
    )
    (totalfCashBorrowedUSDC, totalDebtSharesUSDC, _) = environment.notional.getSecondaryBorrow(
        vault.address, 3, maturity
    )
    assert totalfCashBorrowedETH == 0
    assert totalfCashBorrowedUSDC == 0
    assert totalfCashBorrowedETH == totalDebtSharesETH
    assert totalfCashBorrowedUSDC == totalDebtSharesUSDC


def test_repay_secondary_currency_fails_with_no_borrow(environment, accounts, vault):
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
    environment.notional.updateSecondaryBorrowCapacity(
        vault.address, 3, 100e8, {"from": environment.notional.owner()}
    )

    # Repaying a zero debt shares should have no effect
    vault.repaySecondaryCurrency(accounts[1], 3, maturity, 0, 0)

    vault.borrowSecondaryCurrency(accounts[2], maturity, [0, 10e8], [0, 0], [0, 0])

    with brownie.reverts():
        # Reverts on an underflow inside _updateAccountDebtShares
        vault.repaySecondaryCurrency(accounts[1], 3, maturity, 5e8, 0)


def test_repay_secondary_currency_via_vault(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 3]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.token["USDC"].transfer(vault.address, 100e6, {"from": accounts[0]})
    accounts[0].transfer(vault.address, 5e18)

    environment.notional.updateSecondaryBorrowCapacity(
        vault.address, 1, 100e8, {"from": environment.notional.owner()}
    )
    environment.notional.updateSecondaryBorrowCapacity(
        vault.address, 3, 100e8, {"from": environment.notional.owner()}
    )

    # Account borrows on secondary currencies
    vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 5e8], [0, 0], [0, 0])
    (_, debtSharesBefore, _) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    (totalfCashBorrowedETH, totalDebtSharesETH, _) = environment.notional.getSecondaryBorrow(
        vault.address, 1, maturity
    )
    (totalfCashBorrowedUSDC, totalDebtSharesUSDC, _) = environment.notional.getSecondaryBorrow(
        vault.address, 3, maturity
    )
    assert totalfCashBorrowedETH == 1e8
    assert totalfCashBorrowedUSDC == 5e8
    assert totalfCashBorrowedETH == totalDebtSharesETH
    assert totalfCashBorrowedUSDC == totalDebtSharesUSDC

    # Vault repays secondary currencies and reduces account outstanding debt
    vault.repaySecondaryCurrency(vault.address, 3, maturity, 2.5e8, 0)
    (_, debtSharesAfter, _) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtSharesBefore == debtSharesAfter

    (
        totalfCashBorrowedUSDCAfter,
        totalDebtSharesUSDCAfter,
        _,
    ) = environment.notional.getSecondaryBorrow(vault.address, 3, maturity)
    # fCashBorrowed is reduced, debt shares is not
    assert totalfCashBorrowedUSDCAfter == 2.5e8
    assert totalDebtSharesUSDC == totalDebtSharesUSDCAfter

    # Repayment is based on accountDebtShare
    txn = vault.repaySecondaryCurrency(accounts[1], 3, maturity, 5e8, 0)
    assert txn.events["VaultRepaySecondaryBorrow"]["fCashLent"] == 2.5e8
    (debtMaturity, debtSharesAfter, _) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtSharesAfter[0] == 1e8
    assert debtSharesAfter[1] == 0
    assert debtMaturity == maturity

    vault.repaySecondaryCurrency(vault.address, 1, maturity, 1e8, 0)
    (
        totalfCashBorrowedETHAfter,
        totalDebtSharesETHAfter,
        _,
    ) = environment.notional.getSecondaryBorrow(vault.address, 1, maturity)
    # fCashBorrowed is reduced, debt shares is not
    assert totalfCashBorrowedETHAfter == 0
    assert totalDebtSharesETH == totalDebtSharesETHAfter

    # Nothing to repay here because it has already been repaid
    txn = vault.repaySecondaryCurrency(accounts[1], 1, maturity, 1e8, 0)
    assert txn.events["VaultRepaySecondaryBorrow"]["fCashLent"] == 0
    assert txn.events["VaultRepaySecondaryBorrow"]["debtSharesRepaid"] == 1e8
    (debtMaturity, debtSharesAfter, _) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtSharesAfter[0] == 0
    assert debtSharesAfter[1] == 0
    assert debtMaturity == 0


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
    vault.repaySecondaryCurrency(accounts[1], 1, maturity, 0.5e8, 0)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0.5e8, 0.1e8)
    assert (
        environment.notional.getSecondaryBorrow(vault.address, 1, maturity)["totalfCashBorrowed"]
        == 0.5e8
    )

    with brownie.reverts(""):
        vault.repaySecondaryCurrency(accounts[1], 1, maturity, 0.6e8, 0)

    # Clear the borrow
    vault.repaySecondaryCurrency(accounts[1], 1, maturity, 0.5e8, 0)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0, 0.1e8)
    assert (
        environment.notional.getSecondaryBorrow(vault.address, 1, maturity)["totalfCashBorrowed"]
        == 0
    )


def test_settle_fails_on_secondary_currency_balance(environment, vault, accounts):
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

    environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.notional.enterVault(
        accounts[1], vault.address, 50_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )
    vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 0], [0, 0], [0, 0])

    chain.mine(1, maturity)

    with brownie.reverts("Unpaid Borrow"):
        environment.notional.settleVault(vault.address, maturity, {"from": accounts[1]})

    accounts[0].transfer(vault.address, 50e18)
    environment.token["DAI"].transfer(vault.address, 100_000e18, {"from": accounts[0]})

    vault.initiateSecondaryBorrowSettlement(maturity, {"from": accounts[0]})
    vault.redeemStrategyTokensToCash(maturity, 105_000e8, "", {"from": accounts[0]})
    # TODO: assert that this is repaid at the settlement rate...
    vault.repaySecondaryCurrency(vault.address, 1, maturity, 1e8, 0)
    assert environment.notional.getBorrowCapacity(vault.address, 1) == (0, 100e8)
    assert (
        environment.notional.getSecondaryBorrow(vault.address, 1, maturity)["totalfCashBorrowed"]
        == 0
    )

    environment.notional.settleVault(vault.address, maturity, {"from": accounts[1]})

    # Test that the vault can safely exit the vault
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)

    (debtMaturity, debtShares, _) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtMaturity == maturity
    assert debtShares == [1e8, 0]

    environment.notional.exitVault(
        accounts[1],
        vault.address,
        accounts[1],
        vaultAccount["vaultShares"],
        0,
        0,
        "",
        {"from": accounts[1]},
    )
    (debtMaturity, debtShares, _) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )
    assert debtMaturity == 0
    assert debtShares == [0, 0]


def test_repay_secondary_currency_succeeds_at_zero_interest(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), secondaryBorrowCurrencies=[1, 3]
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 3, 20_000e8, {"from": environment.notional.owner()}
    )
    vault.borrowSecondaryCurrency(accounts[1], maturity, [0, 10_000e8], [0, 0], [0, 0])

    # Lend the market down to zero
    action = get_lend_action(
        3,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 95_000e8, "minSlippage": 0}],
        False,
    )
    environment.notional.batchLend(accounts[0], [action], {"from": accounts[0]})

    (amountUnderlying, _, _, _) = environment.notional.getDepositFromfCashLend(
        3, 10_000e8, maturity, 0, chain.time()
    )
    # Shows that lending will fail
    assert amountUnderlying == 0

    environment.token["USDC"].transfer(vault.address, 10_000e6, {"from": accounts[0]})

    usdcBalanceBefore = environment.token["USDC"].balanceOf(vault.address)
    txn = vault.repaySecondaryCurrency(vault.address, 3, maturity, 10_000e8, 0)
    assert txn.events["VaultRepaySecondaryBorrow"]["fCashLent"] == 10_000e8
    usdcBalanceAfter = environment.token["USDC"].balanceOf(vault.address)

    assert usdcBalanceBefore - usdcBalanceAfter == 10_000e6 + 1


def test_roll_secondary_borrow_forward(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
            secondaryBorrowCurrencies=[1, 3],
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 20_000e8, {"from": environment.notional.owner()}
    )
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 3, 20_000e8, {"from": environment.notional.owner()}
    )

    vault.borrowSecondaryCurrency(accounts[1], maturity, [4e8, 4e8], [0, 0], [0, 0])
    # Ensure we can increase the borrow position in an existing maturity
    vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 1e8], [0, 0], [0, 0])

    with brownie.reverts("Insufficient Secondary Borrow"):
        vault.borrowSecondaryCurrency(
            accounts[1], maturity + SECONDS_IN_QUARTER, [0, 0], [0, 0], [0, 0]
        )

    txn = vault.borrowSecondaryCurrency(
        accounts[1], maturity + SECONDS_IN_QUARTER, [6e8, 7e8], [0, 0], [0, 0]
    )
    (debtMaturityAfter, debtSharesAfter, _) = environment.notional.getVaultAccountDebtShares(
        accounts[1].address, vault.address
    )

    assert debtMaturityAfter == maturity + SECONDS_IN_QUARTER
    assert debtSharesAfter == [6e8, 7e8]
    assert txn.events["SecondaryBorrow"]["underlyingTokensTransferred"][0] < 1e18
    assert txn.events["SecondaryBorrow"]["underlyingTokensTransferred"][0] > 0.93e18
    assert txn.events["SecondaryBorrow"]["underlyingTokensTransferred"][1] < 2e6
    assert txn.events["SecondaryBorrow"]["underlyingTokensTransferred"][1] > 1.8e6


def test_roll_secondary_borrow_fails_lower_maturity(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
            secondaryBorrowCurrencies=[1, 3],
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 20_000e8, {"from": environment.notional.owner()}
    )
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 3, 20_000e8, {"from": environment.notional.owner()}
    )

    vault.borrowSecondaryCurrency(
        accounts[1], maturity + SECONDS_IN_QUARTER, [5e8, 5e8], [0, 0], [0, 0]
    )

    # Fails on a lower maturity
    with brownie.reverts():
        vault.borrowSecondaryCurrency(accounts[1], maturity, [6e8, 7e8], [0, 0], [0, 0])


def test_roll_secondary_borrow_fails_insufficient_cash(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
            secondaryBorrowCurrencies=[1, 3],
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 1, 20_000e8, {"from": environment.notional.owner()}
    )
    environment.notional.updateSecondaryBorrowCapacity(
        vault, 3, 20_000e8, {"from": environment.notional.owner()}
    )

    vault.borrowSecondaryCurrency(accounts[1], maturity, [5e8, 5e8], [0, 0], [0, 0])

    with brownie.reverts("Insufficient Secondary Borrow"):
        vault.borrowSecondaryCurrency(
            accounts[1], maturity + SECONDS_IN_QUARTER, [5e8, 5e8], [0, 0], [0, 0]
        )

    with brownie.reverts("Trade failed, slippage"):
        vault.borrowSecondaryCurrency(
            accounts[1], maturity + SECONDS_IN_QUARTER, [6e8, 7e8], [0.001e9, 0], [0, 0]
        )

    # Reverts but weird brownie RPC error here.
    # with brownie.reverts("Trade failed, slippage"):
    #     vault.borrowSecondaryCurrency(accounts[1], maturity + SECONDS_IN_QUARTER, [6e8, 7e8],
    #       [0, 0.001e9], [0, 0])

    with brownie.reverts("Trade failed, slippage"):
        vault.borrowSecondaryCurrency(
            accounts[1], maturity + SECONDS_IN_QUARTER, [6e8, 7e8], [0, 0], [1e9, 0]
        )

    with brownie.reverts("Trade failed, slippage"):
        vault.borrowSecondaryCurrency(
            accounts[1], maturity + SECONDS_IN_QUARTER, [6e8, 7e8], [0, 0], [0, 1e9]
        )


def test_governance_reduce_borrow_capacity(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000e8,
        {"from": accounts[0]},
    )

    maturity = environment.notional.getActiveMarkets(1)[0][1]
    environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    with brownie.reverts():
        # Reverts on non-owner
        environment.notional.reduceMaxBorrowCapacity(
            vault.address, 90_000e8, maturity, 10_000e8, "", {"from": accounts[1]}
        )

    vaultStateBefore = environment.notional.getVaultState(vault.address, maturity)
    environment.notional.reduceMaxBorrowCapacity(
        vault.address, 90_000e8, maturity, 10_000e8, "", {"from": environment.notional.owner()}
    )

    (totalUsedCapacity, maxCapacity) = environment.notional.getBorrowCapacity(vault.address, 2)
    assert totalUsedCapacity == 100_000e8
    assert maxCapacity == 90_000e8

    # TODO: is this the correct behavior?
    vaultStateAfter = environment.notional.getVaultState(vault.address, maturity)
    assert (
        vaultStateBefore["totalStrategyTokens"] - vaultStateAfter["totalStrategyTokens"] == 10_000e8
    )
    assert vaultStateBefore["totalVaultShares"] == vaultStateAfter["totalVaultShares"]
    assert vaultStateBefore["totalfCash"] == vaultStateAfter["totalfCash"]
    assert vaultStateAfter["totalAssetCash"] == 500_000e8


def test_settle_with_secondary_borrow_fail(environment, accounts, vault):
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
    vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 1e8], [0, 0], [0, 0])
    vault.initiateSecondaryBorrowSettlement(maturity, {"from": accounts[0]})

    # Cannot re-initiate secondary borrow
    with brownie.reverts("Cannot Reset Snapshot"):
        vault.initiateSecondaryBorrowSettlement(maturity, {"from": accounts[0]})

    # Cannot borrow secondary currency at this point
    with brownie.reverts("In Settlement"):
        vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 1e8], [0, 0], [0, 0])

    # Cannot repay secondary currency on the vault
    with brownie.reverts("In Settlement"):
        vault.repaySecondaryCurrency(accounts[1], 1, maturity, 1e8, 0)


def test_settle_with_secondary_borrow_fail_zero_borrows(environment, accounts, vault):
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
    vault.initiateSecondaryBorrowSettlement(maturity, {"from": accounts[0]})

    # Cannot re-initiate secondary borrow
    with brownie.reverts("Cannot Reset Snapshot"):
        vault.initiateSecondaryBorrowSettlement(maturity, {"from": accounts[0]})

    # Cannot borrow secondary currency at this point
    with brownie.reverts("In Settlement"):
        vault.borrowSecondaryCurrency(accounts[1], maturity, [1e8, 1e8], [0, 0], [0, 0])

    # Cannot repay secondary currency on the vault
    with brownie.reverts("In Settlement"):
        vault.repaySecondaryCurrency(accounts[1], 1, maturity, 1e8, 0)


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

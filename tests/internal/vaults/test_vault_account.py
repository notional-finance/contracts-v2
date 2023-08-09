import logging
import random

import brownie
import pytest
from brownie import SimpleStrategyVault
from brownie.network import Chain
from brownie.test import given, strategy
from fixtures import *
from tests.constants import (
    PRIME_CASH_VAULT_MATURITY,
    SECONDS_IN_MONTH,
    SECONDS_IN_QUARTER,
    START_TIME_TREF,
)
from tests.helpers import simulate_init_markets

LOGGER = logging.getLogger(__name__)

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_enforce_borrow_size(vaultConfigTokenTransfer, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigTokenTransfer.address, 1, {"from": accounts[0]}
    )
    vaultConfigTokenTransfer.setVaultConfig(
        vault.address, get_vault_config(minAccountBorrowSize=100_000e8)
    )

    with brownie.reverts("Min Borrow"):
        account = get_vault_account(accountDebtUnderlying=-100e8, vaultShares=100)
        vaultConfigTokenTransfer.setVaultAccount(account, vault.address)

    # Setting with negative accountDebtUnderlying and no vault shares is ok (insolvency)
    account = get_vault_account(accountDebtUnderlying=-100e8, vaultShares=0)
    vaultConfigTokenTransfer.setVaultAccount(account, vault.address)
    assert account == vaultConfigTokenTransfer.getVaultAccount(accounts[0].address, vault.address)

    # Setting with 0 accountDebtUnderlying is ok
    account = get_vault_account()
    vaultConfigTokenTransfer.setVaultAccount(account, vault.address)
    assert account == vaultConfigTokenTransfer.getVaultAccount(accounts[0].address, vault.address)

    # Borrowing at min borrow succeeds
    account = get_vault_account(accountDebtUnderlying=-100_000e8)
    vaultConfigTokenTransfer.setVaultAccount(account, vault.address)
    assert account == vaultConfigTokenTransfer.getVaultAccount(accounts[0].address, vault.address)

    # Borrowing above min borrow succeeds
    account = get_vault_account(accountDebtUnderlying=-500_000e8)
    vaultConfigTokenTransfer.setVaultAccount(account, vault.address)
    assert account == vaultConfigTokenTransfer.getVaultAccount(accounts[0].address, vault.address)


def test_enforce_temp_cash_balance(vaultConfigAccount, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigAccount.address, 1, {"from": accounts[0]}
    )
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config(currencyId=1))

    with brownie.reverts():
        # Any temp cash balance should fail
        account = get_vault_account(tempCashBalance=100e8)
        vaultConfigAccount.setVaultAccount(account, vault.address)


def test_enforce_secondary_currency_maturity(vaultConfigSecondaryBorrow, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigSecondaryBorrow.address, 1, {"from": accounts[0]}
    )
    vaultConfigSecondaryBorrow.setVaultConfig(
        vault.address, get_vault_config(currencyId=1, secondaryBorrowCurrencies=[2, 3])
    )
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 2, 100_000e8)
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 3, 100_000e8)
    vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault.address, accounts[1], START_TIME_TREF + SECONDS_IN_QUARTER, -100e8, -100e8, True
    )

    with brownie.reverts():
        account = get_vault_account(
            account=accounts[1].address,
            accountDebtUnderlying=-100e8,
            maturity=PRIME_CASH_VAULT_MATURITY,
        )
        vaultConfigSecondaryBorrow.setVaultAccount(account, vault.address)


@given(
    totalDebtUnderlying=strategy("int", min_value=-90_000e8, max_value=0),
    netAccountDebt=strategy("int", min_value=-9_000e8, max_value=0),
)
def test_vault_account_debt(vaultConfigAccount, totalDebtUnderlying, netAccountDebt):
    maturity = random.choice(
        [
            START_TIME_TREF + SECONDS_IN_QUARTER,
            START_TIME_TREF + 2 * SECONDS_IN_QUARTER,
            PRIME_CASH_VAULT_MATURITY,
        ]
    )
    (vaultState, vaultAccount) = vaultConfigAccount.updateAccountDebt(
        get_vault_account(maturity=maturity),
        get_vault_state(maturity=maturity, totalDebtUnderlying=totalDebtUnderlying),
        netAccountDebt,
        90_000e8,
    )

    assert vaultState["totalDebtUnderlying"] == totalDebtUnderlying + netAccountDebt
    assert vaultAccount["accountDebtUnderlying"] == netAccountDebt
    assert vaultAccount["tempCashBalance"] == 90_000e8


@given(currencyIndex=strategy("uint", min_value=0, max_value=3))
def test_set_vault_account_liquidation(vaultConfigAccount, accounts, currencyIndex):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigAccount.address, 1, {"from": accounts[0]}
    )
    vaultConfigAccount.setVaultConfig(
        vault.address,
        get_vault_config(currencyId=1, secondaryBorrowCurrencies=[2, 3], minAccountBorrowSize=50e8),
    )

    account = get_vault_account(accountDebtUnderlying=-100e8)
    vaultConfigAccount.setVaultAccount(account, vault.address)

    if currencyIndex == 3:
        with brownie.reverts():
            vaultConfigAccount.setVaultAccountForLiquidation(
                vault, account, currencyIndex, 100e8, True
            )

        return

    vaultConfigAccount.setVaultAccountForLiquidation(vault, account, currencyIndex, 100e8, True)

    newAccount = vaultConfigAccount.getVaultAccount(accounts[0], vault.address)
    if currencyIndex == 0:
        assert newAccount["tempCashBalance"] == 100e8
    else:
        assert (
            vaultConfigAccount.getSecondaryCashHeld(accounts[0], vault.address)[currencyIndex - 1]
            == 100e8
        )

    # Cannot set a vault account with any temp cash balance or secondary cash balance
    with brownie.reverts():
        vaultConfigAccount.setVaultAccount(newAccount, vault.address)

    # This increases the cash balance
    vaultConfigAccount.setVaultAccountForLiquidation(vault, newAccount, currencyIndex, 100e8, True)

    if currencyIndex == 0:
        assert (
            vaultConfigAccount.getVaultAccount(accounts[0], vault.address)["tempCashBalance"]
            == 200e8
        )
    else:
        assert (
            vaultConfigAccount.getSecondaryCashHeld(accounts[0], vault.address)[currencyIndex - 1]
            == 200e8
        )


def test_set_multiple_account_cash(vaultConfigAccount, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigAccount.address, 1, {"from": accounts[0]}
    )
    vaultConfigAccount.setVaultConfig(
        vault.address,
        get_vault_config(currencyId=1, secondaryBorrowCurrencies=[2, 3], minAccountBorrowSize=50e8),
    )

    account = get_vault_account(accountDebtUnderlying=-100e8)
    vaultConfigAccount.setVaultAccountForLiquidation(vault, account, 0, 100e8, True)
    vaultConfigAccount.setVaultAccountForLiquidation(vault, account, 1, 200e8, True)
    vaultConfigAccount.setVaultAccountForLiquidation(vault, account, 2, 300e8, True)
    vaultConfigAccount.setVaultAccountForLiquidation(vault, account, 0, 300e8, True)

    assert (
        vaultConfigAccount.getVaultAccount(accounts[0], vault.address)["tempCashBalance"] == 400e8
    )
    assert vaultConfigAccount.getSecondaryCashHeld(accounts[0], vault.address) == (200e8, 300e8)

@given(
    currencyId=strategy("uint", min_value=1, max_value=4),
    vaultShares=strategy("uint", min_value=1000e8, max_value=25_000e8),
    accountDebt=strategy("int", min_value=-25_000e8, max_value=-1000e8),
)
def test_settle_account_updates_state(
    vaultConfigAccount, accounts, currencyId, vaultShares, accountDebt
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigAccount.address, currencyId, {"from": accounts[0]}
    )
    vaultConfigAccount.setVaultConfig(
        vault.address,
        get_vault_config(currencyId=currencyId, flags=set_flags(0, ALLOW_ROLL_POSITION=True)),
    )
    vaultConfigAccount.setMaxBorrowCapacity(vault.address, currencyId, 100_000_000e8)

    # Setup the vault state
    totalDebtUnderlying = -100_000e8
    totalVaultShares = 100_000e8
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    state = get_vault_state(
        maturity=maturity,
        totalDebtUnderlying=totalDebtUnderlying,
        totalVaultShares=totalVaultShares,
    )
    vaultConfigAccount.setVaultState(vault.address, state)
    vaultConfigAccount.setfCashBorrowCapacity(vault.address, currencyId, totalDebtUnderlying)

    primeState = get_vault_state(
        maturity=PRIME_CASH_VAULT_MATURITY,
        totalDebtUnderlying=totalDebtUnderlying,
        totalVaultShares=totalVaultShares,
    )
    vaultConfigAccount.setVaultState(vault.address, primeState)

    # Settle the vault account
    account = get_vault_account(
        maturity=maturity, vaultShares=vaultShares, accountDebtUnderlying=accountDebt
    )

    # Check that no settlement happens prior to maturity
    txn = vaultConfigAccount.settleVaultAccount(vault, account)
    assert "VaultStateSettled" not in txn.events
    assert txn.return_value == account

    chain.mine(1, timestamp=maturity)
    (_, factorsBefore) = vaultConfigAccount.buildPrimeRateView(currencyId, chain.time())
    stateBefore = vaultConfigAccount.getVaultState(vault, maturity)
    primeStateBefore = vaultConfigAccount.getVaultState(vault, PRIME_CASH_VAULT_MATURITY)

    # Clear the 3mo market, simulates an init markets
    simulate_init_markets(vaultConfigAccount, currencyId)
    # Sets the prime settlement rate via init markets
    vaultConfigAccount.buildPrimeSettlementRateStateful(currencyId, maturity)
    txn = vaultConfigAccount.settleVaultAccount(vault, account)
    accountAfter = txn.return_value

    (pr, factorsAfter) = vaultConfigAccount.buildPrimeRateView(currencyId, txn.timestamp)
    stateAfter = vaultConfigAccount.getVaultState(vault, maturity)
    primeStateAfter = vaultConfigAccount.getVaultState(vault, PRIME_CASH_VAULT_MATURITY)

    # Assert vault account is correctly updated
    assert accountAfter["maturity"] == PRIME_CASH_VAULT_MATURITY
    # This should be approximately equal right after maturity
    assert pytest.approx(accountAfter["accountDebtUnderlying"], abs=5) == accountDebt
    # No fees when settling exactly at maturity
    assert accountAfter["tempCashBalance"] == 0
    assert accountAfter["lastUpdateBlockTime"] == txn.timestamp

    # Assert that only the total debt is transferred to the prime cash maturity
    assert (
        pytest.approx(
            primeStateAfter["totalDebtUnderlying"] - primeStateBefore["totalDebtUnderlying"],
            rel=1e-8,
        )
        == stateBefore["totalDebtUnderlying"]
    )
    assert (
        primeStateAfter["totalVaultShares"]
        == primeStateBefore["totalVaultShares"] + accountAfter["vaultShares"]
    )
    assert not primeStateAfter["isSettled"]
    # Assert that total prime debt has increased accordingly
    assert pytest.approx(totalDebtUnderlying, abs=100) == vaultConfigAccount.convertToUnderlying(
        pr,
        vaultConfigAccount.convertFromStorage(
            pr, factorsBefore["totalPrimeDebt"] - factorsAfter["totalPrimeDebt"]
        ),
    )

    # Assert vault state has been updated
    assert stateAfter["isSettled"]
    assert stateAfter["totalDebtUnderlying"] == 0
    assert stateBefore["totalVaultShares"] - stateAfter["totalVaultShares"] == vaultShares

    # Settle second vault account, no second settlement
    chain.mine(1, timedelta=SECONDS_IN_MONTH)
    account = get_vault_account(
        maturity=maturity, vaultShares=vaultShares * 2, accountDebtUnderlying=accountDebt
    )

    (_, factorsBefore) = vaultConfigAccount.buildPrimeRateView(currencyId, chain.time())
    stateBefore = vaultConfigAccount.getVaultState(vault, maturity)
    primeStateBefore = vaultConfigAccount.getVaultState(vault, PRIME_CASH_VAULT_MATURITY)

    txn = vaultConfigAccount.settleVaultAccount(vault, account)
    accountAfter = txn.return_value

    (pr, factorsAfter) = vaultConfigAccount.buildPrimeRateView(currencyId, txn.timestamp)
    stateAfter = vaultConfigAccount.getVaultState(vault, maturity)
    primeStateAfter = vaultConfigAccount.getVaultState(vault, PRIME_CASH_VAULT_MATURITY)

    # Assert vault account is correctly updated
    assert accountAfter["maturity"] == PRIME_CASH_VAULT_MATURITY
    # Should have accrued some interest over the month
    assert (accountAfter["accountDebtUnderlying"] / accountDebt) > 1
    assert (accountAfter["accountDebtUnderlying"] / accountDebt) < 1.03
    # Fees accrued on prime vault over the month
    assert pytest.approx(
        accountAfter["tempCashBalance"], abs=5_000, rel=1e-5
    ) == vaultConfigAccount.convertFromUnderlying(
        pr, accountAfter["accountDebtUnderlying"] * 0.01 / 12
    )
    assert accountAfter["lastUpdateBlockTime"] == txn.timestamp

    # Assert prime vault state does not change
    assert pytest.approx(primeStateBefore[1], rel=1e-8) == primeStateAfter[1]
    assert (
        primeStateAfter["totalVaultShares"]
        == primeStateBefore["totalVaultShares"] + accountAfter["vaultShares"]
    )

    # Assert vault state has been updated
    assert stateAfter["isSettled"]
    assert stateAfter["totalDebtUnderlying"] == 0
    assert stateBefore["totalVaultShares"] - stateAfter["totalVaultShares"] == vaultShares * 2

@given(
    currencyId=strategy("uint", min_value=1, max_value=4),
    vaultShares=strategy("uint", min_value=1000e8, max_value=25_000e8),
    accountDebt=strategy("int", min_value=-25_000e8, max_value=-1000e8),
    accountCash=strategy("int", min_value=0, max_value=25_000e8)
)
def test_settle_account_vault_has_prime_cash(
    vaultConfigAccount, accounts, currencyId, vaultShares, accountDebt, accountCash
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigAccount.address, currencyId, {"from": accounts[0]}
    )
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config(currencyId=currencyId))
    vaultConfigAccount.setMaxBorrowCapacity(vault.address, currencyId, 100_000_000e8)

    # Setup the vault state
    totalDebtUnderlying = -100_000e8
    totalVaultShares = 100_000e8
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    state = get_vault_state(
        maturity=maturity,
        totalDebtUnderlying=totalDebtUnderlying,
        totalVaultShares=totalVaultShares,
    )
    vaultConfigAccount.setVaultState(vault.address, state)
    vaultConfigAccount.setfCashBorrowCapacity(vault.address, currencyId, totalDebtUnderlying)
    vaultConfigAccount.setVaultAccountPrimaryCash(accounts[1], vault.address, accountCash)

    account = get_vault_account(
        maturity=maturity,
        vaultShares=vaultShares,
        accountDebtUnderlying=accountDebt,
        tempCashBalance=accountCash
    )

    chain.mine(1, timestamp=maturity)
    # Do not offset nToken, no trading has occurred
    simulate_init_markets(vaultConfigAccount, currencyId)
    vaultConfigAccount.buildPrimeSettlementRateStateful(currencyId, maturity)

    txn = vaultConfigAccount.settleVaultAccount(vault, account)
    accountAfter = txn.return_value
    (pr, _) = vaultConfigAccount.buildPrimeRateView(currencyId, txn.timestamp)
    # Cash is used to pay off debts
    cashInUnderlying = vaultConfigAccount.convertToUnderlying(pr, accountCash)
    if cashInUnderlying + accountDebt > 0:
        assert accountAfter['accountDebtUnderlying'] == 0
        assert pytest.approx(accountAfter["tempCashBalance"], abs=100) == vaultConfigAccount.convertFromUnderlying(pr, cashInUnderlying + accountDebt)
    else:
        assert pytest.approx(accountAfter['accountDebtUnderlying'], abs=100) == accountDebt + cashInUnderlying
        assert accountAfter['tempCashBalance'] == 0

@given(isPrimeCash=strategy("bool"))
def test_increase_secondary_debt_insufficient_capacity(
    vaultConfigSecondaryBorrow, accounts, isPrimeCash
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigSecondaryBorrow.address, 1, {"from": accounts[0]}
    )
    vaultConfigSecondaryBorrow.setVaultConfig(
        vault.address, get_vault_config(currencyId=1, secondaryBorrowCurrencies=[2, 3])
    )
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 2, 10_000e8)
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 3, 10_000e8)

    maturity = PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER
    with brownie.reverts("Max Capacity"):
        vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
            vault, accounts[1], maturity, -20_000e8, 0, True
        )

    with brownie.reverts("Max Capacity"):
        vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
            vault, accounts[1], maturity, -1_000e8, -11_000e8, True
        )


@given(isPrimeCash=strategy("bool"))
def test_increase_secondary_debt_enforce_min_borrow(
    vaultConfigSecondaryBorrow, accounts, isPrimeCash
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigSecondaryBorrow.address, 1, {"from": accounts[0]}
    )
    vaultConfigSecondaryBorrow.setVaultConfig(
        vault.address,
        get_vault_config(
            currencyId=1, secondaryBorrowCurrencies=[2, 3], minAccountSecondaryBorrow=[100e8, 200e8]
        ),
    )
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 2, 10_000e8)
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 3, 10_000e8)
    maturity = PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER

    # Passes
    vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault, accounts[1], maturity, -100e8, 0, True
    )

    vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault, accounts[2], maturity, 0, -200e8, True
    )

    # Fails Due to Min Borrow
    with brownie.reverts():
        vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
            vault, accounts[1], maturity, 50e8, -200e8, True
        )

    with brownie.reverts():
        vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
            vault, accounts[2], maturity, 0, 50e8, True
        )

    # Succeeds due to skip check
    vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault, accounts[1], maturity, 50e8, -200e8, False
    )
    results = vaultConfigSecondaryBorrow.getAccountSecondaryDebt(vault, accounts[1])
    assert results[0] == maturity
    assert pytest.approx(results[1], abs=100) == -50e8
    assert pytest.approx(results[2], abs=100) == -200e8

    vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault, accounts[2], maturity, 0, 50e8, False
    )
    results = vaultConfigSecondaryBorrow.getAccountSecondaryDebt(vault, accounts[2])
    assert results[0] == maturity
    assert pytest.approx(results[1], abs=100) == 0
    assert pytest.approx(results[2], abs=100) == -150e8

@given(
    isPrimeCash=strategy("bool"),
    netUnderlyingDebtOne=strategy(
        "int", min_value=-10_000e8, max_value=0, exclude=lambda x: x != 0 and x < -0.01e8
    ),
    netUnderlyingDebtTwo=strategy(
        "int", min_value=-10_000e8, max_value=0, exclude=lambda x: x != 0 and x < -0.01e8
    ),
)
def test_increase_secondary_debt(
    vaultConfigSecondaryBorrow, accounts, isPrimeCash, netUnderlyingDebtOne, netUnderlyingDebtTwo
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigSecondaryBorrow.address, 1, {"from": accounts[0]}
    )
    vaultConfigSecondaryBorrow.setVaultConfig(
        vault.address, get_vault_config(currencyId=1, secondaryBorrowCurrencies=[2, 3])
    )
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 2, 10_000e8)
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 3, 10_000e8)

    maturity = PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER
    txn = vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault, accounts[1], maturity, netUnderlyingDebtOne, netUnderlyingDebtTwo, True
    )

    # Check account value and maturity
    accountDebt = vaultConfigSecondaryBorrow.getAccountSecondaryDebt(vault, accounts[1])
    totalDebt = vaultConfigSecondaryBorrow.getTotalSecondaryDebtOutstanding(vault, maturity)
    assert accountDebt["maturity"] == maturity

    if isPrimeCash:
        assert pytest.approx(accountDebt["accountDebtOne"], abs=10) == netUnderlyingDebtOne
        assert pytest.approx(accountDebt["accountDebtTwo"], abs=10) == netUnderlyingDebtTwo
        assert pytest.approx(totalDebt["totalDebtOne"], abs=10) == netUnderlyingDebtOne
        assert pytest.approx(totalDebt["totalDebtTwo"], abs=10) == netUnderlyingDebtTwo
    else:
        assert accountDebt["accountDebtOne"] == netUnderlyingDebtOne
        assert accountDebt["accountDebtTwo"] == netUnderlyingDebtTwo
        assert totalDebt["totalDebtOne"] == netUnderlyingDebtOne
        assert totalDebt["totalDebtTwo"] == netUnderlyingDebtTwo


    if isPrimeCash:
        assert 'VaultBorrowCapacityChange' not in txn.events
    else:
        assert (
            txn.events["VaultBorrowCapacityChange"][0]["totalUsedBorrowCapacity"]
            == -netUnderlyingDebtOne
        )
        assert (
            txn.events["VaultBorrowCapacityChange"][1]["totalUsedBorrowCapacity"]
            == -netUnderlyingDebtTwo
        )
        assert txn.events["VaultBorrowCapacityChange"][0]["currencyId"] == 2
        assert txn.events["VaultBorrowCapacityChange"][1]["currencyId"] == 3

    # Clear debt to zero
    if isPrimeCash:
        txn = vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
            vault, accounts[1], maturity, -(2 ** 255), -(2 ** 255), True
        )
    else:
        txn = vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
            vault, accounts[1], maturity, -netUnderlyingDebtOne, -netUnderlyingDebtTwo, True
        )

    if isPrimeCash:
        assert 'VaultBorrowCapacityChange' not in txn.events
    else:
        assert vaultConfigSecondaryBorrow.getAccountSecondaryDebt(vault, accounts[1]) == (0, 0, 0)
        assert vaultConfigSecondaryBorrow.getTotalSecondaryDebtOutstanding(vault, maturity) == (
            0,
            0,
            0,
        )
        assert txn.events["VaultBorrowCapacityChange"][0]["totalUsedBorrowCapacity"] == 0
        assert txn.events["VaultBorrowCapacityChange"][1]["totalUsedBorrowCapacity"] == 0
        assert txn.events["VaultBorrowCapacityChange"][0]["currencyId"] == 2
        assert txn.events["VaultBorrowCapacityChange"][1]["currencyId"] == 3

def test_cannot_settle_prime_secondary_borrow(vaultConfigSecondaryBorrow, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigSecondaryBorrow.address, 1, {"from": accounts[0]}
    )
    vaultConfigSecondaryBorrow.setVaultConfig(
        vault.address, get_vault_config(currencyId=1, secondaryBorrowCurrencies=[2, 3])
    )
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 2, 100_000e8)
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 3, 100_000e8)
    vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault, accounts[1], PRIME_CASH_VAULT_MATURITY, -10_000e8, -10_000e8, True
    )

    with brownie.reverts():
        vaultConfigSecondaryBorrow.settleSecondaryBorrow(vault, accounts[1])

def test_settle_account_secondary_borrows(vaultConfigSecondaryBorrow, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigSecondaryBorrow.address, 1, {"from": accounts[0]}
    )
    vaultConfigSecondaryBorrow.setVaultConfig(
        vault.address, get_vault_config(currencyId=1, secondaryBorrowCurrencies=[2, 3])
    )
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 2, 100_000e8)
    vaultConfigSecondaryBorrow.setMaxBorrowCapacity(vault, 3, 100_000e8)

    vaultConfigSecondaryBorrow.setVaultAccount(
        get_vault_account(
            account=accounts[1],
            maturity=maturity,
            accountDebtUnderlying=-100_000e8,
            vaultShares=50_000e8,
        ),
        vault,
    )
    vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault, accounts[1], maturity, -10_000e8, -10_000e8, True
    )

    vaultConfigSecondaryBorrow.setVaultAccount(
        get_vault_account(
            account=accounts[2],
            maturity=maturity,
            accountDebtUnderlying=-100_000e8,
            vaultShares=50_000e8,
        ),
        vault,
    )
    vaultConfigSecondaryBorrow.updateAccountSecondaryDebt(
        vault, accounts[2], maturity, 0, -10_000e8, True
    )

    vaultConfigSecondaryBorrow.setVaultAccountSecondaryCash(accounts[1], vault, 1_000e8, 250_000e8)
    vaultConfigSecondaryBorrow.setVaultAccountSecondaryCash(accounts[2], vault, 0, 50_000e8)

    chain.mine(1, timestamp=maturity)
    simulate_init_markets(vaultConfigSecondaryBorrow, 1)
    simulate_init_markets(vaultConfigSecondaryBorrow, 2)
    simulate_init_markets(vaultConfigSecondaryBorrow, 3)
    vaultConfigSecondaryBorrow.buildPrimeSettlementRateStateful(1, maturity)
    vaultConfigSecondaryBorrow.buildPrimeSettlementRateStateful(2, maturity)
    vaultConfigSecondaryBorrow.buildPrimeSettlementRateStateful(3, maturity)

    txn = vaultConfigSecondaryBorrow.settleSecondaryBorrow(vault, accounts[1])
    accountDebt = vaultConfigSecondaryBorrow.getAccountSecondaryDebt(vault, accounts[1])
    totalDebt = vaultConfigSecondaryBorrow.getTotalSecondaryDebtOutstanding(vault, maturity)
    totalPrimeDebt = vaultConfigSecondaryBorrow.getTotalSecondaryDebtOutstanding(
        vault, PRIME_CASH_VAULT_MATURITY
    )

    assert accountDebt["maturity"] == PRIME_CASH_VAULT_MATURITY
    assert pytest.approx(accountDebt["accountDebtOne"], rel=1e-4) == -10_000e8 + 1_000e8
    assert pytest.approx(accountDebt["accountDebtTwo"], rel=1e-4) == -5_000e8

    # Assert fCash vault state has been cleared
    assert totalDebt == (0, 0, 0)
    assert txn.events["VaultBorrowCapacityChange"][0]["currencyId"] == 2
    assert txn.events["VaultBorrowCapacityChange"][1]["currencyId"] == 3
    assert txn.events["VaultBorrowCapacityChange"][0]["totalUsedBorrowCapacity"] == 0
    assert txn.events["VaultBorrowCapacityChange"][1]["totalUsedBorrowCapacity"] == 0

    assert pytest.approx(totalPrimeDebt["totalDebtOne"], abs=1) == accountDebt['accountDebtOne']
    # This still includes account debt two since it's cash balance has not been paid off yet
    assert pytest.approx(totalPrimeDebt["totalDebtTwo"], abs=1) == accountDebt['accountDebtTwo'] + -10_000e8

    chain.mine(1, timedelta=SECONDS_IN_MONTH)
    txn = vaultConfigSecondaryBorrow.settleSecondaryBorrow(vault, accounts[2])
    accountDebt = vaultConfigSecondaryBorrow.getAccountSecondaryDebt(vault, accounts[2])
    totalDebt = vaultConfigSecondaryBorrow.getTotalSecondaryDebtOutstanding(vault, maturity)
    totalPrimeDebt2 = vaultConfigSecondaryBorrow.getTotalSecondaryDebtOutstanding(
        vault, PRIME_CASH_VAULT_MATURITY
    )

    assert "VaultStateSettled" not in txn.events
    assert "VaultBorrowCapacityChange" not in txn.events

    assert accountDebt["maturity"] == PRIME_CASH_VAULT_MATURITY
    assert accountDebt["accountDebtOne"] == 0
    assert vaultConfigSecondaryBorrow.getSecondaryCashHeld(accounts[2], vault) == (0, 0)
    # Account has net debt of 10_000 - 5_000 - 1_000, final debt of 4_000e8
    assert (accountDebt["accountDebtTwo"] - -4_000e8) / 4_000e8 < 0.03
    assert totalDebt == (0, 0, 0)  # fcash debt is completely removed
    # Some debt has accrued in underlying terms
    assert (totalPrimeDebt2["totalDebtOne"] / totalPrimeDebt["totalDebtOne"]) > 1
    assert (totalPrimeDebt2["totalDebtOne"] / totalPrimeDebt["totalDebtOne"]) < 1.03

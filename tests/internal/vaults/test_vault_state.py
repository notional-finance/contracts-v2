import math
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
    ZERO_ADDRESS,
)

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

@given(
    currencyId=strategy("uint", min_value=1, max_value=4),
    totalDebtUnderlying=strategy("int", min_value=-100_000e8, max_value=0),
    totalVaultShares=strategy("uint", min_value=0, max_value=100_000e8),
)
def test_get_and_set_fcash_vault_state(
    vaultConfigState,
    currencyId,
    totalVaultShares,
    totalDebtUnderlying,
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigState.address, currencyId, {"from": accounts[0]}
    )
    vaultConfigState.setVaultConfig(vault.address, get_vault_config(currencyId=currencyId))
    vaultConfigState.setMaxBorrowCapacity(vault, currencyId, 200_000e8)

    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalDebtUnderlying=totalDebtUnderlying,
        totalVaultShares=totalVaultShares,
    )
    txn = vaultConfigState.setVaultState(vault.address, state)

    assert state == vaultConfigState.getVaultState(vault.address, state[0])
    if totalDebtUnderlying < 0:
        assert txn.events["VaultBorrowCapacityChange"]["vault"] == vault.address
        assert txn.events["VaultBorrowCapacityChange"]["currencyId"] == currencyId
        assert (
            txn.events["VaultBorrowCapacityChange"]["totalUsedBorrowCapacity"]
            == -totalDebtUnderlying
        )

    chain.mine(1, timedelta=SECONDS_IN_MONTH)
    # assert that values do not change over time
    assert state == vaultConfigState.getVaultState(vault.address, state[0])

@given(
    currencyId=strategy("uint", min_value=1, max_value=1),
    totalDebtUnderlying=strategy(
        "int", min_value=-100_000e8, max_value=0, exclude=lambda x: not (-1e8 < x and x != 0)
    ),
    totalVaultShares=strategy("uint", min_value=0, max_value=100_000e8),
)
def test_get_and_set_prime_vault_state(
    vaultConfigState,
    currencyId,
    totalVaultShares,
    totalDebtUnderlying,
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigState.address, currencyId, {"from": accounts[0]}
    )
    vaultConfigState.setVaultConfig(vault.address, get_vault_config(currencyId=currencyId))
    vaultConfigState.setMaxBorrowCapacity(vault, currencyId, 200_000e8)

    state = get_vault_state(
        maturity=PRIME_CASH_VAULT_MATURITY,
        totalDebtUnderlying=totalDebtUnderlying,
        totalVaultShares=totalVaultShares,
    )
    (_, factorsBefore) = vaultConfigState.buildPrimeRateView(currencyId, chain.time() + 1)
    txn = vaultConfigState.setVaultState(vault.address, state)
    (_, factorsAfter) = vaultConfigState.buildPrimeRateView(currencyId, chain.time() + 1)

    newState1 = vaultConfigState.getVaultState(vault.address, state[0])

    if totalDebtUnderlying < 0:
        assert pytest.approx(state[1], abs=5) == newState1[1]
        assert state[2:] == newState1[2:]
        (pr, _) = vaultConfigState.buildPrimeRateView(currencyId, txn.timestamp)
        assert (
            pytest.approx(
                vaultConfigState.convertToUnderlying(
                    pr,
                    vaultConfigState.convertFromStorage(
                        pr,
                        factorsBefore["totalPrimeDebt"] - factorsAfter["totalPrimeDebt"],
                    ),
                ),
                abs=10,
            )
            == totalDebtUnderlying
        )

        assert (
            pytest.approx(vaultConfigState.getCurrentPrimeDebt(vault.address), abs=1000)
            == totalDebtUnderlying
        )
    else:
        assert state == newState1
        assert factorsBefore["totalPrimeDebt"] == factorsAfter["totalPrimeDebt"]
        assert "VaultBorrowCapacityChange" not in txn.events

    chain.mine(1, timedelta=SECONDS_IN_MONTH)
    # assert that values do not change over time
    newState2 = vaultConfigState.getVaultState(vault.address, state[0])
    if totalDebtUnderlying < 0:
        assert state[1] > newState2[1]  # has accrued debt
        assert state[2:] == newState2[2:]
    else:
        assert state == newState2

    # Add debt a second time to ensure that we update the total debt outstanding properly
    state = get_vault_state(
        maturity=PRIME_CASH_VAULT_MATURITY,
        totalDebtUnderlying=newState2[1] - 1000e8,
        totalVaultShares=totalVaultShares,
    )
    factorsBefore = vaultConfigState.getPrimeFactors(currencyId)
    # (_, factors2) = vaultConfigState.buildPrimeRateView(currencyId, chain.time() + 1)
    txn2 = vaultConfigState.setVaultState(vault.address, state)
    vaultConfigState.setVaultState(vault.address, state)
    factorsAfter = vaultConfigState.getPrimeFactors(currencyId)
    assert pytest.approx(vaultConfigState.getCurrentPrimeDebt(vault.address), abs=100) == (
        newState2[1] - 1000e8
    )

    # TODO: quite a lot of rounding errors at this point, not sure what is causing it,
    # calculations match what is seen on chain
    # vaultConfigState.buildPrimeRateStateful(currencyId)
    (pr, _) = vaultConfigState.buildPrimeRateView(currencyId, chain.time() + 1)
    assert (
        pytest.approx(
            math.floor(
                (factorsBefore["totalPrimeDebt"] - factorsAfter["totalPrimeDebt"])
                * pr["debtFactor"]
                / 1e36
            ),
            abs=1000,
            rel=1e-6,
        )
        == -1000e8
    )


@given(isPrime=strategy("bool"))
def test_vault_capacity_on_set(vaultConfigState, isPrime):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigState.address, 1, {"from": accounts[0]}
    )
    vaultConfigState.setVaultConfig(vault.address, get_vault_config(currencyId=1))
    vaultConfigState.setMaxBorrowCapacity(vault.address, 1, 200_000e8)

    primeState = get_vault_state(maturity=PRIME_CASH_VAULT_MATURITY, totalDebtUnderlying=-100_000e8)
    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER, totalDebtUnderlying=-50_000e8
    )

    # Set some initial state
    vaultConfigState.setVaultState(vault.address, primeState)
    vaultConfigState.setVaultState(vault.address, state)

    maturity = PRIME_CASH_VAULT_MATURITY if isPrime else START_TIME_TREF + SECONDS_IN_QUARTER

    # Get the vault state and add some debt to it
    state = list(vaultConfigState.getVaultState(vault.address, maturity))
    state[1] = state[1] - 10_000e8
    # Can increase capacity
    vaultConfigState.setVaultState(vault.address, state)

    # cannot increase above max
    state = list(vaultConfigState.getVaultState(vault.address, maturity))
    state[1] = state[1] - 50_000e8
    with brownie.reverts("Max Capacity"):
        vaultConfigState.setVaultState(vault.address, state)

    # Cannot always decrease, even if above max. Total usage here is 150_000e8 capacity
    state = list(vaultConfigState.getVaultState(vault.address, maturity))
    state[1] = state[1] + 10_000e8
    vaultConfigState.setMaxBorrowCapacity(vault.address, 1, 10_000e8)
    vaultConfigState.setVaultState(vault.address, state)


def test_exit_maturity_pool_failures(vaultConfigState):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigState.address, 1, {"from": accounts[0]}
    )
    vaultConfigState.setVaultConfig(vault.address, get_vault_config(currencyId=1))
    account = get_vault_account(vaultShares=100e8, tempCashBalance=0)
    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalVaultShares=100_000e8,
    )

    with brownie.reverts():
        # fails due to mismatched maturities
        vaultConfigState.exitMaturity(vault.address, state, account, 1e8)

    with brownie.reverts():
        account = get_vault_account(
            maturity=START_TIME_TREF + SECONDS_IN_QUARTER, vaultShares=100e8, tempCashBalance=0
        )
        # fails due to insufficient balance
        vaultConfigState.exitMaturity(vault.address, state, account, 150e8)


@given(
    totalVaultShares=strategy("uint", min_value=100e8, max_value=100_000e8),
    sharesRedeem=strategy("uint", min_value=0, max_value=100e8),
)
def test_exit_maturity_pool(vaultConfigState, totalVaultShares, sharesRedeem):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigState.address, 1, {"from": accounts[0]}
    )
    vaultConfigState.setVaultConfig(vault.address, get_vault_config(currencyId=1))
    accountShares = 100e8
    tempCashBalance = 0

    account = get_vault_account(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        vaultShares=accountShares,
        tempCashBalance=tempCashBalance,
    )
    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalVaultShares=totalVaultShares,
    )

    txn = vaultConfigState.exitMaturity(vault.address, state, account, sharesRedeem)
    (newState, _) = txn.return_value
    # Total Vault Shares Net Off
    assert totalVaultShares - newState.dict()["totalVaultShares"] == sharesRedeem

def test_enter_maturity_with_old_maturity(vaultConfigState):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigState.address, 1, {"from": accounts[0]}
    )
    vaultConfigState.setVaultConfig(vault.address, get_vault_config())
    account = get_vault_account(maturity=START_TIME_TREF + 3 * SECONDS_IN_QUARTER)
    state = get_vault_state(maturity=START_TIME_TREF + 2 * SECONDS_IN_QUARTER)

    # Cannot enter a maturity pool with a mismatched maturity
    with brownie.reverts():
        vaultConfigState.enterMaturity(vault.address, state, account, 0, "")

    account = get_vault_account(maturity=START_TIME_TREF + SECONDS_IN_QUARTER, vaultShares=100e8)
    state = get_vault_state(maturity=START_TIME_TREF + 2 * SECONDS_IN_QUARTER)

    # Cannot enter a maturity pool with a mismatched maturity
    with brownie.reverts():
        vaultConfigState.enterMaturity(vault.address, state, account, 0, "")

@given(
    currencyId=strategy("uint", min_value=1, max_value=3),
    vaultShareDeposit=strategy("uint", min_value=0, max_value=200_000e8),
    tempCashBalance=strategy("uint", min_value=1e8, max_value=1_000e8),
)
def test_enter_maturity(
    vaultConfigState, currencyId, accounts, vaultShareDeposit, tempCashBalance, MockERC20
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigState.address, currencyId, {"from": accounts[0]}
    )
    vaultConfigState.setVaultConfig(vault.address, get_vault_config(currencyId=currencyId))
    totalVaultShares = 100_000e8

    maturities = [
        START_TIME_TREF + SECONDS_IN_QUARTER,
        START_TIME_TREF + 2 * SECONDS_IN_QUARTER,
        PRIME_CASH_VAULT_MATURITY,
        0,
    ]
    accountMaturity = random.choice(maturities)
    stateMaturity = random.choice(maturities)
    stateMaturity = maturities[0] if stateMaturity == 0 else stateMaturity
    accountVaultShares = 500e8 if accountMaturity == stateMaturity else 0

    account = get_vault_account(
        maturity=accountMaturity, tempCashBalance=tempCashBalance, vaultShares=accountVaultShares
    )
    state = get_vault_state(
        maturity=stateMaturity,
        totalVaultShares=totalVaultShares,
    )

    vault.setExchangeRate(2e18)
    txn = vaultConfigState.enterMaturity(
        vault.address, state, account, vaultShareDeposit,  ""
    )
    (newState, newAccount) = txn.return_value
    # Total Vault Shares Net Off
    assert (
        newState.dict()["totalVaultShares"] - totalVaultShares
        == newAccount.dict()["vaultShares"] - accountVaultShares
    )
    assert newAccount.dict()["tempCashBalance"] == 0

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from fixtures import *
from tests.constants import (
    BASIS_POINT,
    RATE_PRECISION,
    SECONDS_IN_QUARTER,
    SECONDS_IN_YEAR,
    START_TIME_TREF,
)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_set_vault_config(vaultConfig, accounts):
    with brownie.reverts():
        # Fails on liquidation ratio less than 100
        conf = get_vault_config()
        conf[5] = 99
        vaultConfig.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on reserve fee share over 100
        conf = get_vault_config()
        conf[6] = 102
        vaultConfig.setVaultConfig(accounts[0], conf)

    conf = get_vault_config()
    vaultConfig.setVaultConfig(accounts[0], conf)

    config = vaultConfig.getVaultConfigView(accounts[0]).dict()
    assert config["vault"] == accounts[0].address
    assert config["flags"] == conf[0]
    assert config["borrowCurrencyId"] == conf[1]
    assert config["minAccountBorrowSize"] == conf[2] * 1e8
    assert config["minCollateralRatio"] == conf[3] * BASIS_POINT
    assert config["feeRate"] == conf[4] * 5 * BASIS_POINT
    assert config["liquidationRate"] == conf[5] * RATE_PRECISION / 100
    assert config["reserveFeeShare"] == conf[6]
    assert config["maxBorrowMarketIndex"] == conf[7]


def test_pause_and_enable_vault(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    # Asserts are inside the method
    vaultConfig.setVaultEnabledStatus(accounts[0], True)
    vaultConfig.setVaultEnabledStatus(accounts[0], False)


def test_vault_fee_increases_with_debt(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address, get_vault_config(maxNTokenFeeRate5BPS=255, minCollateralRatioBPS=11000)
    )

    txn = vaultConfig.assessVaultFees(vault.address, get_vault_account(), 0, SECONDS_IN_QUARTER)
    (_, initTotalReserve, initNToken) = txn.return_value
    assert initTotalReserve == 0
    assert initNToken == 0

    fCash = 0
    decrement = 100e8
    lastTotalReserve = 0
    lastNTokenCashBalance = 0
    for i in range(0, 20):
        fCash -= decrement
        txn = vaultConfig.assessVaultFees(
            vault.address, get_vault_account(), fCash, SECONDS_IN_QUARTER
        )

        (vaultAccount, totalReserve, nTokenCashBalance) = txn.return_value
        assert totalReserve > lastTotalReserve
        assert nTokenCashBalance > lastNTokenCashBalance
        assert (totalReserve - lastTotalReserve) + (
            nTokenCashBalance - lastNTokenCashBalance
        ) == -vaultAccount.dict()["tempCashBalance"]

        lastTotalReserve = totalReserve
        lastNTokenCashBalance = nTokenCashBalance


def test_vault_fee_increases_with_time_to_maturity(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address, get_vault_config(maxNTokenFeeRate5BPS=255, minCollateralRatioBPS=11000)
    )

    txn = vaultConfig.assessVaultFees(vault.address, get_vault_account(), 0, SECONDS_IN_QUARTER)
    (_, initTotalReserve, initNToken) = txn.return_value
    assert initTotalReserve == 0
    assert initNToken == 0

    timeToMaturity = 0
    increment = Wei(SECONDS_IN_QUARTER / 20)
    lastTotalReserve = 0
    lastNTokenCashBalance = 0
    for i in range(0, 20):
        timeToMaturity += increment
        txn = vaultConfig.assessVaultFees(
            vault.address, get_vault_account(), -100_000e8, timeToMaturity
        )

        (vaultAccount, totalReserve, nTokenCashBalance) = txn.return_value
        assert totalReserve > lastTotalReserve
        assert nTokenCashBalance > lastNTokenCashBalance
        assert (totalReserve - lastTotalReserve) + (
            nTokenCashBalance - lastNTokenCashBalance
        ) == -vaultAccount.dict()["tempCashBalance"]

        lastTotalReserve = totalReserve
        lastNTokenCashBalance = nTokenCashBalance


def test_update_used_borrow_capacity_increases_with_borrowing(vaultConfig, vault):
    vaultConfig.setMaxBorrowCapacity(vault.address, 1, 100_000e8)

    runningTotal = 0
    for i in range(0, 5):
        fCash = 22_000e8
        runningTotal += fCash

        if runningTotal > 100_000e8:
            with brownie.reverts("Max Capacity"):
                vaultConfig.updateUsedBorrowCapacity(vault.address, 1, -fCash)
        else:
            assert (
                runningTotal
                == vaultConfig.updateUsedBorrowCapacity(vault.address, 1, -fCash).return_value
            )


def test_update_used_borrow_capacity_decreases_with_lending(vaultConfig, vault):
    vaultConfig.setMaxBorrowCapacity(vault.address, 1, 100_000e8)
    vaultConfig.updateUsedBorrowCapacity(vault.address, 1, -100_000e8)

    assert 90_000e8 == vaultConfig.updateUsedBorrowCapacity(vault.address, 1, 10_000e8).return_value

    vaultConfig.setMaxBorrowCapacity(vault.address, 1, 50_000e8)

    # Still allowed to decrease borrow capacity above max
    assert 80_000e8 == vaultConfig.updateUsedBorrowCapacity(vault.address, 1, 10_000e8).return_value

    with brownie.reverts("Max Capacity"):
        vaultConfig.updateUsedBorrowCapacity(vault.address, 1, -1)


def test_deposit_and_redeem_ctoken(vaultConfig, vault, accounts, cToken, underlying):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    vault.setExchangeRate(Wei(5e18))

    cToken.transfer(vaultConfig.address, 100_000e8, {"from": accounts[0]})
    balanceBefore = cToken.balanceOf(vaultConfig.address)
    txn = vaultConfig.deposit(
        vault.address, accounts[0], 100e8, START_TIME_TREF, "", {"from": accounts[0]}
    )
    balanceAfter = cToken.balanceOf(vaultConfig.address)

    assert balanceBefore - balanceAfter == 100e8
    assert cToken.balanceOf(vault.address) == 0
    assert underlying.balanceOf(vault.address) == 2e18

    txn = vaultConfig.redeem(
        vault.address, accounts[0], 0.2e8, START_TIME_TREF, "", {"from": accounts[0]}
    )
    balanceAfterRedeem = cToken.balanceOf(vaultConfig.address)

    assert cToken.balanceOf(vault.address) == 0
    assert underlying.balanceOf(vault.address) == 1e18
    assert balanceAfterRedeem - balanceAfter == txn.return_value


# This would be useful for completeness but doesnt test any additional
# behaviors
# def test_deposit_and_redeem_atoken(vaultConfig, vault, accounts):
#     pass

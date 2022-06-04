import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from fixtures import *
from tests.constants import BASIS_POINT, SECONDS_IN_QUARTER, SECONDS_IN_YEAR, START_TIME_TREF


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_set_vault_config(vaultConfig, accounts):
    with brownie.reverts():
        # Fails on liquidation ratio less than 100
        conf = get_vault_config()
        conf[8] = 99
        vaultConfig.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on reserve fee share over 100
        conf = get_vault_config()
        conf[9] = 102
        vaultConfig.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on zero term length
        conf = get_vault_config()
        conf[5] = 0
        vaultConfig.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on non-divisable term length
        conf = get_vault_config()
        conf[6] = 28
        vaultConfig.setVaultConfig(accounts[0], conf)

    conf = get_vault_config()
    vaultConfig.setVaultConfig(accounts[0], conf)

    config = vaultConfig.getVaultConfigView(accounts[0]).dict()
    assert config["vault"] == accounts[0].address
    assert config["flags"] == conf[0]
    assert config["borrowCurrencyId"] == conf[1]
    assert config["maxVaultBorrowCapacity"] == conf[2]
    assert config["minAccountBorrowSize"] == conf[3] * 1e8
    assert config["minCollateralRatio"] == conf[4] * BASIS_POINT
    assert config["termLengthInSeconds"] == conf[5] * 86400
    assert config["termOffsetInSeconds"] == 0
    assert config["feeRate"] == conf[7] * 5 * BASIS_POINT
    assert config["liquidationRate"] == conf[8]
    assert config["reserveFeeShare"] == conf[9]


def test_pause_and_enable_vault(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    # Asserts are inside the method
    vaultConfig.setVaultEnabledStatus(accounts[0], True)
    vaultConfig.setVaultEnabledStatus(accounts[0], False)


def test_current_maturity(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    currentMaturity = vaultConfig.getCurrentMaturity(accounts[0], START_TIME_TREF)
    assert currentMaturity == START_TIME_TREF + SECONDS_IN_QUARTER


@given(blockTimeOffset=strategy("uint", max_value=SECONDS_IN_QUARTER * 6))
def test_alternating_3mo_vaults(vaultConfig, accounts, blockTimeOffset):
    blockTime = START_TIME_TREF + blockTimeOffset
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())
    vaultConfig.setVaultConfig(accounts[1], get_vault_config(termOffsetInDays=90))

    assert (
        abs(
            vaultConfig.getCurrentMaturity(accounts[0], blockTime)
            - vaultConfig.getCurrentMaturity(accounts[1], blockTime)
        )
        == SECONDS_IN_QUARTER
    )


@pytest.mark.only
@given(blockTimeOffset=strategy("uint", max_value=SECONDS_IN_QUARTER * 12))
def test_alternating_6mo_vaults(vaultConfig, accounts, blockTimeOffset):
    blockTime = START_TIME_TREF + blockTimeOffset
    vaultConfig.setVaultConfig(accounts[0], get_vault_config(termLengthInDays=360))
    vaultConfig.setVaultConfig(
        accounts[1], get_vault_config(termLengthInDays=360, termOffsetInDays=180)
    )

    assert (
        abs(
            vaultConfig.getCurrentMaturity(accounts[0], blockTime)
            - vaultConfig.getCurrentMaturity(accounts[1], blockTime)
        )
        == SECONDS_IN_QUARTER * 2
    )


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


def test_max_borrow_capacity_no_reenter(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address, get_vault_config(flags=set_flags(0), maxVaultBorrowCapacity=100_000_000e8)
    )

    # Set current maturity
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
            totalfCash=-90_000_000e8,
            totalfCashRequiringSettlement=-80_000_000e8,
            totalAssetCash=250_000_000e8,
        ),
    )

    totalDebt = vaultConfig.getBorrowCapacity(
        vault.address, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    assert totalDebt == 90_000_000e8

    # Turn on settlement
    vault.setSettlement(True)

    totalDebt = vaultConfig.getBorrowCapacity(
        vault.address, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    assert totalDebt == 85_000_000e8


def test_max_borrow_capacity_with_reenter(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ALLOW_REENTER=True), maxVaultBorrowCapacity=100_000_000e8
        ),
    )

    # Set current maturity
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
            totalfCash=-90_000_000e8,
            totalfCashRequiringSettlement=-80_000_000e8,
            totalAssetCash=250_000_000e8,
        ),
    )

    # Next maturity
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=START_TIME_TREF + 2 * SECONDS_IN_QUARTER,
            totalfCash=-20_000_000e8,
            totalfCashRequiringSettlement=-20_000_000e8,
            totalAssetCash=100_000e8,
        ),
    )

    totalDebt = vaultConfig.getBorrowCapacity(
        vault.address, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    assert totalDebt == 110_000_000e8

    # Should see same capacity numbers if the vault state is the
    # next maturity
    totalDebt2 = vaultConfig.getBorrowCapacity(
        vault.address, START_TIME_TREF + 2 * SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    assert totalDebt == totalDebt2


def test_max_borrow_capacity_with_settlement_and_reenter(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ALLOW_REENTER=True), maxVaultBorrowCapacity=100_000_000e8
        ),
    )

    # Set current maturity
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
            totalfCash=-90_000_000e8,
            totalfCashRequiringSettlement=-80_000_000e8,
            totalAssetCash=250_000_000e8,
        ),
    )

    # Next maturity
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=START_TIME_TREF + 2 * SECONDS_IN_QUARTER,
            totalfCash=-20_000_000e8,
            totalfCashRequiringSettlement=-20_000_000e8,
            totalAssetCash=100_000e8,
        ),
    )

    vault.setSettlement(True)

    totalDebt = vaultConfig.getBorrowCapacity(
        vault.address, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    assert totalDebt == 105_000_000e8

    # Should see same capacity numbers if the vault state is the
    # next maturity
    totalDebt2 = vaultConfig.getBorrowCapacity(
        vault.address, START_TIME_TREF + 2 * SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    assert totalDebt == totalDebt2


def test_deposit_and_redeem_ctoken(vaultConfig, vault, accounts, cToken, underlying):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    vault.setExchangeRate(Wei(5e18))

    cToken.transfer(vaultConfig.address, 100_000e8, {"from": accounts[0]})
    balanceBefore = cToken.balanceOf(vaultConfig.address)
    txn = vaultConfig.deposit(vault.address, 100e8, START_TIME_TREF, "", {"from": accounts[0]})
    balanceAfter = cToken.balanceOf(vaultConfig.address)

    assert balanceBefore - balanceAfter == 100e8
    assert cToken.balanceOf(vault.address) == 0
    assert underlying.balanceOf(vault.address) == 2e18
    assert vault.balanceOf(vaultConfig.address) == txn.return_value

    txn = vaultConfig.redeem(vault.address, 0.2e8, START_TIME_TREF, "", {"from": accounts[0]})
    balanceAfterRedeem = cToken.balanceOf(vaultConfig.address)

    assert cToken.balanceOf(vault.address) == 0
    assert underlying.balanceOf(vault.address) == 1e18
    assert vault.balanceOf(vaultConfig.address) == 0.2e8
    assert balanceAfterRedeem - balanceAfter == txn.return_value


# This would be useful for completeness but doesnt test any additional
# behaviors
# def test_deposit_and_redeem_atoken(vaultConfig, vault, accounts):
#     pass

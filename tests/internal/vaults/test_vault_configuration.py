import brownie
import pytest
from brownie.convert.datatypes import Wei
from fixtures import *
from tests.constants import BASIS_POINT, RATE_PRECISION, SECONDS_IN_QUARTER, START_TIME_TREF


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_set_vault_config(vaultConfig, accounts):
    conf = get_vault_config()
    with brownie.reverts():
        # Fails on leverage ratio less than 1
        conf[4] = 100
        vaultConfig.setVaultConfig(accounts[0], conf)

    conf = get_vault_config()
    with brownie.reverts():
        # Fails on liquidation ratio less than 100
        conf[8] = 99
        vaultConfig.setVaultConfig(accounts[0], conf)

    conf = get_vault_config()
    vaultConfig.setVaultConfig(accounts[0], conf)

    config = vaultConfig.getVaultConfigView(accounts[0]).dict()
    assert config["vault"] == accounts[0].address
    assert config["flags"] == conf[0]
    assert config["borrowCurrencyId"] == conf[1]
    assert config["maxVaultBorrowSize"] == conf[2]
    assert config["minAccountBorrowSize"] == conf[3] * 1e8
    assert config["minCollateralRatio"] == conf[4] * BASIS_POINT
    assert config["termLengthInSeconds"] == conf[5] * 86400
    assert config["maxNTokenFeeRate"] == conf[6] * 5 * BASIS_POINT
    assert config["capacityMultiplierPercentage"] == conf[7]
    assert config["liquidationRate"] == conf[8]


def test_pause_and_enable_vault(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    # Asserts are inside the method
    vaultConfig.setVaultEnabledStatus(accounts[0], True)
    vaultConfig.setVaultEnabledStatus(accounts[0], False)


def test_current_maturity(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    currentMaturity = vaultConfig.getCurrentMaturity(accounts[0], START_TIME_TREF)
    assert currentMaturity == START_TIME_TREF + SECONDS_IN_QUARTER


@pytest.mark.only
def test_ntoken_fee_no_debt(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config(maxNTokenFeeRate5BPS=255))

    # no fee when at max
    assert vaultConfig.getNTokenFee(accounts[0], 2 ** 255 - 1, -100e8, SECONDS_IN_QUARTER) == 0


def test_ntoken_fee_decreases_with_collateral(vaultConfig, accounts):
    vaultConfig.setVaultConfig(
        accounts[0],
        get_vault_config(
            maxNTokenFeeRate5BPS=255, minCollateralRatioBPS=11000
        ),  # 110% collateral ratio
    )

    collateralRatio = 1.1 * RATE_PRECISION
    # go over the max leverage ratio and see what happens to the fee
    increment = 0.1 * RATE_PRECISION
    lastFee = 255 * 5 * BASIS_POINT * 100_000e8 / 4
    for i in range(0, 20):
        collateralRatio += increment
        fee = vaultConfig.getNTokenFee(accounts[0], collateralRatio, -100_000e8, SECONDS_IN_QUARTER)
        assert fee < lastFee
        lastFee = fee


def test_ntoken_fee_increases_with_debt(vaultConfig, accounts):
    vaultConfig.setVaultConfig(
        accounts[0], get_vault_config(maxNTokenFeeRate5BPS=255, minCollateralRatioBPS=11000)
    )

    assert vaultConfig.getNTokenFee(accounts[0], 1.2 * RATE_PRECISION, 0, SECONDS_IN_QUARTER) == 0

    fCash = 0
    decrement = 100e8
    lastFee = 0
    for i in range(0, 20):
        fCash -= decrement
        fee = vaultConfig.getNTokenFee(accounts[0], 1.2 * RATE_PRECISION, fCash, SECONDS_IN_QUARTER)
        assert fee > lastFee
        lastFee = fee


def test_ntoken_fee_increases_with_time_to_maturity(vaultConfig, accounts):
    vaultConfig.setVaultConfig(
        accounts[0], get_vault_config(maxNTokenFeeRate5BPS=255, minCollateralRatioBPS=11000)
    )

    assert vaultConfig.getNTokenFee(accounts[0], 1.2 * RATE_PRECISION, 100_000e8, 0) == 0

    timeToMaturity = 0
    # go over the max leverage ratio and see what happens to the fee
    increment = Wei(SECONDS_IN_QUARTER / 20)
    lastFee = 0
    for i in range(0, 20):
        timeToMaturity += increment
        fee = vaultConfig.getNTokenFee(
            accounts[0], 1.2 * RATE_PRECISION, -100_000e8, timeToMaturity
        )
        assert fee > lastFee
        lastFee = fee


def test_max_borrow_capacity_no_reenter(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            flags=set_flags(0), maxVaultBorrowSize=100_000_000e8, capacityMultiplierPercentage=200
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

    (
        totalCapacity,
        nextMaturityCapacity,
        totalDebt,
        nextMaturityDebt,
    ) = vaultConfig.getBorrowCapacity(
        vault.address,
        START_TIME_TREF + SECONDS_IN_QUARTER,
        100_000_000e8,
        80_000_000e8,
        START_TIME_TREF + 100,
    )

    assert totalCapacity == 200_000_000e8
    assert nextMaturityCapacity == 0
    assert totalDebt == 90_000_000e8
    assert nextMaturityDebt == 0

    # Turn on settlement
    vault.setSettlement(True)

    (
        totalCapacity,
        nextMaturityCapacity,
        totalDebt,
        nextMaturityDebt,
    ) = vaultConfig.getBorrowCapacity(
        vault.address,
        START_TIME_TREF + SECONDS_IN_QUARTER,
        100_000_000e8,
        80_000_000e8,
        START_TIME_TREF + 100,
    )

    assert totalCapacity == 200_000_000e8
    assert nextMaturityCapacity == 0
    assert totalDebt == 85_000_000e8
    assert nextMaturityDebt == 0


def test_max_borrow_capacity_with_reenter(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ALLOW_REENTER=True),
            maxVaultBorrowSize=100_000_000e8,
            capacityMultiplierPercentage=200,
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

    (
        totalCapacity,
        nextMaturityCapacity,
        totalDebt,
        nextMaturityDebt,
    ) = vaultConfig.getBorrowCapacity(
        vault.address,
        START_TIME_TREF + SECONDS_IN_QUARTER,
        100_000_000e8,
        80_000_000e8,
        START_TIME_TREF + 100,
    )

    assert totalCapacity == 200_000_000e8
    assert nextMaturityCapacity == 160_000_000e8
    assert totalDebt == 110_000_000e8
    assert nextMaturityDebt == 20_000_000e8

    # Should see same capacity numbers if the vault state is the
    # next maturity
    (
        totalCapacity2,
        nextMaturityCapacity2,
        totalDebt2,
        nextMaturityDebt2,
    ) = vaultConfig.getBorrowCapacity(
        vault.address,
        START_TIME_TREF + 2 * SECONDS_IN_QUARTER,
        100_000_000e8,
        80_000_000e8,
        START_TIME_TREF + 100,
    )

    assert totalCapacity == totalCapacity2
    assert nextMaturityCapacity == nextMaturityCapacity2
    assert totalDebt == totalDebt2
    assert nextMaturityDebt == nextMaturityDebt2


def test_max_borrow_capacity_with_settlement_and_reenter(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ALLOW_REENTER=True),
            maxVaultBorrowSize=100_000_000e8,
            capacityMultiplierPercentage=200,
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

    (
        totalCapacity,
        nextMaturityCapacity,
        totalDebt,
        nextMaturityDebt,
    ) = vaultConfig.getBorrowCapacity(
        vault.address,
        START_TIME_TREF + SECONDS_IN_QUARTER,
        100_000_000e8,
        80_000_000e8,
        START_TIME_TREF + 100,
    )

    assert totalCapacity == 200_000_000e8
    assert nextMaturityCapacity == 160_000_000e8
    assert totalDebt == 105_000_000e8
    assert nextMaturityDebt == 20_000_000e8

    # Should see same capacity numbers if the vault state is the
    # next maturity
    (
        totalCapacity2,
        nextMaturityCapacity2,
        totalDebt2,
        nextMaturityDebt2,
    ) = vaultConfig.getBorrowCapacity(
        vault.address,
        START_TIME_TREF + 2 * SECONDS_IN_QUARTER,
        100_000_000e8,
        80_000_000e8,
        START_TIME_TREF + 100,
    )

    assert totalCapacity == totalCapacity2
    assert nextMaturityCapacity == nextMaturityCapacity2
    assert totalDebt == totalDebt2
    assert nextMaturityDebt == nextMaturityDebt2


def test_deposit_and_redeem_ctoken(vaultConfig, vault, accounts, cToken):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    vault.setExchangeRate(Wei(5e28))

    cToken.transfer(vaultConfig.address, 100_000e8, {"from": accounts[0]})
    balanceBefore = cToken.balanceOf(vaultConfig.address)
    txn = vaultConfig.deposit(vault.address, 100e8, "", {"from": accounts[0]})
    balanceAfter = cToken.balanceOf(vaultConfig.address)

    assert balanceBefore - balanceAfter == 100e8
    assert cToken.balanceOf(vault.address) == 100e8
    assert vault.balanceOf(vaultConfig.address) == 500e8
    assert cToken.allowance(vaultConfig.address, vault.address) == 0
    assert txn.return_value == 500e8

    txn = vaultConfig.redeem(vault.address, 250e8, "", {"from": accounts[0]})
    balanceAfterRedeem = cToken.balanceOf(vaultConfig.address)

    assert cToken.balanceOf(vault.address) == 50e8
    assert vault.balanceOf(vaultConfig.address) == 250e8
    assert balanceAfterRedeem - balanceAfter == 50e8
    assert txn.return_value == 50e8


# This would be useful for completeness but doesnt test any additional
# behaviors
# def test_deposit_and_redeem_atoken(vaultConfig, vault, accounts):
#     pass

import brownie
import pytest
from brownie import MockCToken, MockERC20, SimpleStrategyVault
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

    with brownie.reverts():
        # Fails on min ratio above max deleverage ratio
        conf = get_vault_config()
        conf[8] = 1000
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
    assert config["maxDeleverageCollateralRatio"] == conf[8] * BASIS_POINT


def test_pause_and_enable_vault(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    # Asserts are inside the method
    vaultConfig.setVaultEnabledStatus(accounts[0], True)
    vaultConfig.setVaultEnabledStatus(accounts[0], False)


def test_vault_fee_increases_with_debt(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            maxNTokenFeeRate5BPS=255,
            minCollateralRatioBPS=11000,
            maxDeleverageCollateralRatioBPS=12000,
        ),
    )

    txn = vaultConfig.assessVaultFees(vault.address, get_vault_account(), 0, SECONDS_IN_QUARTER, 0)
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
            vault.address, get_vault_account(), fCash, SECONDS_IN_QUARTER, 0
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
        vault.address,
        get_vault_config(
            maxNTokenFeeRate5BPS=255,
            minCollateralRatioBPS=11000,
            maxDeleverageCollateralRatioBPS=12000,
        ),
    )

    txn = vaultConfig.assessVaultFees(vault.address, get_vault_account(), 0, SECONDS_IN_QUARTER, 0)
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
            vault.address, get_vault_account(), -100_000e8, timeToMaturity, 0
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


def test_transfer_eth_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=1))
    balanceBefore = vault.balance()
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 10e18, {"value": 10e18, "from": accounts[0]}
    ).return_value
    balanceAfter = vault.balance()
    assert cTokenVaultConfig.balance() == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 10e18


def test_transfer_dai_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=2))
    token = MockERC20.at(cTokenVaultConfig.getUnderlyingToken(2))
    token.approve(cTokenVaultConfig.address, 2 ** 255, {"from": accounts[0]})

    balanceBefore = token.balanceOf(vault)
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 100e18, {"from": accounts[0]}
    ).return_value
    balanceAfter = token.balanceOf(vault)

    assert token.balanceOf(cTokenVaultConfig) == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 100e18


def test_transfer_usdc_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=4))
    token = MockERC20.at(cTokenVaultConfig.getUnderlyingToken(4))
    token.approve(cTokenVaultConfig.address, 2 ** 255, {"from": accounts[0]})

    balanceBefore = token.balanceOf(vault)
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 100e6, {"from": accounts[0]}
    ).return_value
    balanceAfter = token.balanceOf(vault)

    assert token.balanceOf(cTokenVaultConfig) == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 100e6


def test_transfer_non_mintable_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=5))
    token = MockERC20.at(cTokenVaultConfig.getAssetToken(5))
    token.approve(cTokenVaultConfig.address, 2 ** 255, {"from": accounts[0]})

    balanceBefore = token.balanceOf(vault)
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 100e18, {"from": accounts[0]}
    ).return_value
    balanceAfter = token.balanceOf(vault)

    assert token.balanceOf(cTokenVaultConfig) == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 100e18


def test_reverts_on_token_with_transfer_fee(cTokenVaultConfig, accounts):
    vault = SimpleStrategyVault.deploy("TEST", cTokenVaultConfig.address, 3, {"from": accounts[0]})
    with brownie.reverts():
        cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=3))


def get_redeem_vault(currencyId, cTokenVaultConfig, accounts):
    vault = SimpleStrategyVault.deploy(
        "TEST", cTokenVaultConfig.address, currencyId, {"from": accounts[0]}
    )
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=currencyId))

    token = None
    # Put some tokens on the vault
    if currencyId == 1:
        accounts[0].transfer(vault.address, 100e18)
        balanceBefore = accounts[1].balance()
        decimals = 18
    elif currencyId == 5:
        token = MockERC20.at(cTokenVaultConfig.getAssetToken(5))
        token.transfer(vault.address, 100e18, {"from": accounts[0]})
        balanceBefore = token.balanceOf(accounts[1])
        decimals = token.decimals()
    else:
        token = MockERC20.at(cTokenVaultConfig.getUnderlyingToken(currencyId))
        decimals = token.decimals()
        token.transfer(vault.address, 100 * (10 ** decimals), {"from": accounts[0]})
        balanceBefore = token.balanceOf(accounts[1])

    vault.setExchangeRate(2 * 10 ** (18 - (18 - decimals)))

    return (vault, token, decimals, balanceBefore)


@given(currencyId=strategy("uint", min_value=1, max_value=5))
def test_redeem_no_debt_to_repay(cTokenVaultConfig, currencyId, accounts):
    if currencyId == 3:
        return
    (vault, token, decimals, balanceBefore) = get_redeem_vault(
        currencyId, cTokenVaultConfig, accounts
    )

    # In this redemption, without debts to repay, all of the profits are transferred to the account
    assetCash = cTokenVaultConfig.redeem(
        vault.address, 5e8, 0, accounts[1], "", {"from": accounts[1]}
    ).return_value
    assert assetCash == 0

    if currencyId == 1:
        balanceAfter = accounts[1].balance()
        assert balanceAfter - balanceBefore == 10e18
        assert vault.balance() == 90e18
        assert cTokenVaultConfig.balance() == 0
    else:
        balanceAfter = token.balanceOf(accounts[1])
        assert balanceAfter - balanceBefore == 10 * (10 ** decimals)
        assert token.balanceOf(vault.address) == 90 * (10 ** decimals)
        assert token.balanceOf(cTokenVaultConfig.address) == 0


@given(currencyId=strategy("uint", min_value=1, max_value=5))
def test_redeem_sufficient_to_repay_debt(cTokenVaultConfig, currencyId, accounts):
    if currencyId == 3:
        return

    (vault, token, decimals, balanceBefore) = get_redeem_vault(
        currencyId, cTokenVaultConfig, accounts
    )

    # In this redemption, the debt is split back with Notional
    if currencyId == 5:
        debtToRepay = -5e18
        assetToken = MockERC20.at(cTokenVaultConfig.getAssetToken(currencyId))
    else:
        debtToRepay = -250e8
        assetToken = MockCToken.at(cTokenVaultConfig.getAssetToken(currencyId))

    assetCash = cTokenVaultConfig.redeem(
        vault.address, 5e8, debtToRepay, accounts[1], "", {"from": accounts[1]}
    ).return_value

    if currencyId == 1:
        balanceAfter = accounts[1].balance()
        assert balanceAfter - balanceBefore == 10e18 / 2 - 1e10
        assert vault.balance() == 90e18
        assert cTokenVaultConfig.balance() == 0
    elif currencyId == 5:
        # non mintable tokens have no adjustment
        balanceAfter = token.balanceOf(accounts[1])
        assert balanceAfter - balanceBefore == 10 * (10 ** decimals) / 2
        assert token.balanceOf(vault.address) == 90 * (10 ** decimals)
        assert token.balanceOf(cTokenVaultConfig.address) == -debtToRepay
    else:
        balanceAfter = token.balanceOf(accounts[1])
        adjustment = 1e10 if decimals > 8 else 1
        assert balanceAfter - balanceBefore == 10 * (10 ** decimals) / 2 - adjustment
        assert token.balanceOf(vault.address) == 90 * (10 ** decimals)
        assert token.balanceOf(cTokenVaultConfig.address) == 0

    if currencyId != 5:
        assert assetToken.balanceOf(cTokenVaultConfig.address) == assetCash
        assert assetToken.balanceOf(vault.address) == 0
        assert assetToken.balanceOf(accounts[1]) == 0
        if decimals < 8:
            assert (
                pytest.approx(assetToken.balanceOf(cTokenVaultConfig.address), abs=5000)
                == -debtToRepay
            )
        else:
            assert (
                pytest.approx(assetToken.balanceOf(cTokenVaultConfig.address), abs=50)
                == -debtToRepay
            )


def test_redeem_insufficient_to_repay_debt_eth(cTokenVaultConfig, accounts):
    (vault, token, decimals, balanceBefore) = get_redeem_vault(1, cTokenVaultConfig, accounts)
    debtToRepay = -750e8
    assetToken = MockCToken.at(cTokenVaultConfig.getAssetToken(1))

    with brownie.reverts("Insufficient repayment"):
        cTokenVaultConfig.redeem(
            vault.address, 5e8, debtToRepay, accounts[1], "", {"from": accounts[1]}
        )

    with brownie.reverts("Insufficient repayment"):
        cTokenVaultConfig.redeem(
            vault.address, 5e8, debtToRepay, accounts[1], "", {"from": accounts[1], "value": 1e18}
        )

    assetCash = cTokenVaultConfig.redeem(
        vault.address, 5e8, debtToRepay, accounts[1], "", {"from": accounts[1], "value": 5.1e18}
    ).return_value
    assert assetToken.balanceOf(cTokenVaultConfig.address) == assetCash

    balanceAfter = accounts[1].balance()
    assert balanceBefore - balanceAfter == 5e18 + 1e10
    assert vault.balance() == 90e18
    assert cTokenVaultConfig.balance() == 0

    assert assetToken.balanceOf(vault.address) == 0
    assert assetToken.balanceOf(accounts[1]) == 0
    assert pytest.approx(assetToken.balanceOf(cTokenVaultConfig.address), abs=50) == -debtToRepay


@given(currencyId=strategy("uint", min_value=2, max_value=5))
def test_redeem_insufficient_to_repay_debt_tokens(cTokenVaultConfig, currencyId, accounts):
    if currencyId == 3:
        return

    (vault, token, decimals, balanceBefore) = get_redeem_vault(
        currencyId, cTokenVaultConfig, accounts
    )

    # In this redemption, everything is repaid to Notional and then more is transferred from the
    # account
    if currencyId == 5:
        debtToRepay = -15e18
        assetToken = MockERC20.at(cTokenVaultConfig.getAssetToken(currencyId))
    else:
        debtToRepay = -750e8
        assetToken = MockCToken.at(cTokenVaultConfig.getAssetToken(currencyId))

    # Reverts on allowance
    with brownie.reverts():
        cTokenVaultConfig.redeem(
            vault.address, 5e8, debtToRepay, accounts[1], "", {"from": accounts[1]}
        )
    token.approve(cTokenVaultConfig.address, 2 ** 255, {"from": accounts[1]})

    # Reverts on insufficient balance
    with brownie.reverts():
        cTokenVaultConfig.redeem(
            vault.address, 5e8, debtToRepay, accounts[1], "", {"from": accounts[1]}
        )

    token.transfer(accounts[1], 100 * (10 ** decimals), {"from": accounts[0]})
    balanceBefore = token.balanceOf(accounts[1])
    cTokenVaultConfig.redeem(
        vault.address, 5e8, debtToRepay, accounts[1], "", {"from": accounts[1]}
    )

    if currencyId == 5:
        # non mintable tokens have no adjustment
        balanceAfter = token.balanceOf(accounts[1])
        assert balanceBefore - balanceAfter == 10 * (10 ** decimals) / 2
        assert token.balanceOf(vault.address) == 90 * (10 ** decimals)
        assert token.balanceOf(cTokenVaultConfig.address) == -debtToRepay
    else:
        balanceAfter = token.balanceOf(accounts[1])
        adjustment = 1e10 if decimals > 8 else 1
        assert balanceBefore - balanceAfter == 10 * (10 ** decimals) / 2 + adjustment
        assert token.balanceOf(vault.address) == 90 * (10 ** decimals)
        assert token.balanceOf(cTokenVaultConfig.address) == 0

        assert assetToken.balanceOf(vault.address) == 0
        assert assetToken.balanceOf(accounts[1]) == 0
        if decimals < 8:
            assert (
                pytest.approx(assetToken.balanceOf(cTokenVaultConfig.address), abs=5000)
                == -debtToRepay
            )
        else:
            assert (
                pytest.approx(assetToken.balanceOf(cTokenVaultConfig.address), abs=50)
                == -debtToRepay
            )


@given(currencyId=strategy("uint", min_value=1, max_value=5))
def test_redeem_with_vault_address(cTokenVaultConfig, currencyId, accounts):
    if currencyId == 3:
        return

    if currencyId == 5:
        assetToken = MockERC20.at(cTokenVaultConfig.getAssetToken(currencyId))
    else:
        assetToken = MockCToken.at(cTokenVaultConfig.getAssetToken(currencyId))

    (vault, token, decimals, balanceBefore) = get_redeem_vault(
        currencyId, cTokenVaultConfig, accounts
    )
    assetCash = cTokenVaultConfig.redeem(
        vault.address, 5e8, 0, vault.address, "", {"from": accounts[1]}
    ).return_value

    if currencyId == 1:
        assert vault.balance() == 90 * (10 ** decimals)
    else:
        assert token.balanceOf(vault.address) == 90 * (10 ** decimals)

    assert assetToken.balanceOf(accounts[1]) == 0

    if currencyId == 5:
        assert assetToken.balanceOf(cTokenVaultConfig.address) == 10e18
        assert assetCash == 10e8
    else:
        assert assetToken.balanceOf(cTokenVaultConfig.address) == assetCash
        assert assetCash == 500e8


def test_resolve_shortfall_with_reserve_sufficient():
    pass


def test_resolve_shortfall_with_reserve_insolvent():
    pass

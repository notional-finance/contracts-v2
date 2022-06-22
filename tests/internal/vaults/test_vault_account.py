import logging

import brownie
import pytest
from brownie import MockCToken, MockERC20
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from fixtures import *
from tests.constants import SECONDS_IN_MONTH, SECONDS_IN_QUARTER, START_TIME_TREF


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_enforce_borrow_size(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config(minAccountBorrowSize=100_000))

    with brownie.reverts("Min Borrow"):
        account = get_vault_account(fCash=-100e8)
        vaultConfig.setVaultAccount(account, vault.address)

    # Setting with 0 fCash is ok
    account = get_vault_account()
    vaultConfig.setVaultAccount(account, vault.address)
    assert account == vaultConfig.getVaultAccount(accounts[0].address, vault.address)

    # Borrowing at min borrow succeeds
    account = get_vault_account(fCash=-100_000e8)
    vaultConfig.setVaultAccount(account, vault.address)
    assert account == vaultConfig.getVaultAccount(accounts[0].address, vault.address)

    # Borrowing above min borrow succeeds
    account = get_vault_account(fCash=-500_000e8)
    vaultConfig.setVaultAccount(account, vault.address)
    assert account == vaultConfig.getVaultAccount(accounts[0].address, vault.address)


def test_enforce_temp_cash_balance(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())

    with brownie.reverts():
        # Any temp cash balance should fail
        account = get_vault_account(tempCashBalance=100e8)
        vaultConfig.setVaultAccount(account, vault.address)


@given(
    fCash=strategy("int", min_value=-100_000e8, max_value=-10_000e8),
    initialRatio=strategy("uint", min_value=0, max_value=30),
)
def test_calculate_deleverage_amount(vaultConfig, accounts, vault, fCash, initialRatio):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            maxDeleverageCollateralRatioBPS=4000, minAccountBorrowSize=10_000, liquidationRate=104
        ),
    )
    vault.setExchangeRate(1e18)
    vaultShares = -fCash + initialRatio * 1000e8
    state = get_vault_state(
        totalfCash=fCash * 10, totalVaultShares=100_000e8, totalStrategyTokens=100_000e8
    )
    account = get_vault_account(fCash=fCash, vaultShares=vaultShares)

    (collateralRatio, vaultShareValue) = vaultConfig.calculateCollateralRatio(
        vault.address, account, state
    )

    (maxDeposit, mustLiquidate) = vaultConfig.calculateDeleverageAmount(
        account, vault.address, vaultShareValue
    )

    if mustLiquidate:
        # In this case, the entire debt must be repaid
        assert maxDeposit == -fCash * 50
    else:
        vaultSharesPurchased = Wei((maxDeposit * 104 * vaultShares) / (vaultShareValue * 100))
        accountAfter = get_vault_account(
            fCash=fCash + maxDeposit / 50, vaultShares=vaultShares - vaultSharesPurchased
        )
        (collateralRatioAfter, _) = vaultConfig.calculateCollateralRatio(
            vault.address, accountAfter, state
        )

        assert pytest.approx(collateralRatioAfter, abs=2) == 0.4e9


def test_settle_fails(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    account = get_vault_account(maturity=maturity, fCash=-100_00e8)

    with brownie.reverts("Not Settled"):
        vaultConfig.settleVaultAccount(
            vault.address, account, START_TIME_TREF + SECONDS_IN_QUARTER + 100
        )


@given(residual=strategy("uint", max_value=100_000e8))
def test_settle_asset_cash_with_residual(vaultConfig, accounts, vault, residual):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000_000e8,
            totalStrategyTokens=100_000e8,  # This represents profits
            totalAssetCash=50_000_000e8 + residual,
            totalfCash=-1_000_000e8,
        ),
    )
    vaultConfig.setSettledVaultState(vault.address, maturity, maturity + 100)

    account = get_vault_account(maturity=maturity, fCash=-10_000e8, vaultShares=10_000e8)

    account2 = get_vault_account(
        maturity=maturity, fCash=-1_000_000e8 + 10_000e8, vaultShares=1_000_000e8 - 10_000e8
    )

    txn1 = vaultConfig.settleVaultAccount(vault.address, account, maturity + 100)
    (accountAfter, strategyTokens) = txn1.return_value

    txn2 = vaultConfig.settleVaultAccount(vault.address, account2, maturity + 100)
    (accountAfter2, strategyTokens2) = txn2.return_value
    assert accountAfter["fCash"] == 0
    assert accountAfter["maturity"] == 0
    assert accountAfter["vaultShares"] == 0
    assert accountAfter2["fCash"] == 0
    assert accountAfter2["maturity"] == 0
    assert accountAfter2["vaultShares"] == 0

    # Account gets their share of strategy tokens here, nothing else
    assert strategyTokens + strategyTokens2 <= 100_000e8
    assert pytest.approx(strategyTokens + strategyTokens2, abs=3) == 100_000e8
    # Account gets their share of the residuals
    assert accountAfter["tempCashBalance"] + accountAfter2["tempCashBalance"] <= residual
    assert (
        pytest.approx(accountAfter["tempCashBalance"] + accountAfter2["tempCashBalance"], abs=3)
        == residual
    )

    (remainingStrategyTokens, remainingAssetCash) = vaultConfig.getRemainingSettledTokens(
        vault.address, maturity
    )
    assert pytest.approx(remainingStrategyTokens, abs=5) == 0
    assert pytest.approx(remainingAssetCash, abs=5) == 0
    assert remainingStrategyTokens >= 0
    assert remainingAssetCash >= 0


def test_settle_insolvent_account(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000_000e8,
            totalStrategyTokens=100_000e8,  # This represents profits
            totalAssetCash=50_000_000e8,
            totalfCash=-1_000_000e8,
        ),
    )
    vaultConfig.setSettledVaultState(vault.address, maturity, maturity + 100)

    account = get_vault_account(maturity=maturity, fCash=-10_000e8, vaultShares=0)
    account2 = get_vault_account(
        maturity=maturity, fCash=-1_000_000e8 + 10_000e8, vaultShares=1_000_000e8
    )

    assert vaultConfig.getRemainingSettledTokens(vault.address, maturity) == (100_000e8, 0)
    vaultConfig.setReserveBalance(1, 50_000_000e8)

    txn1 = vaultConfig.settleVaultAccount(vault.address, account, maturity + 100)
    (accountAfter, strategyTokens) = txn1.return_value

    txn2 = vaultConfig.settleVaultAccount(vault.address, account2, maturity + 100)
    (accountAfter2, strategyTokens2) = txn2.return_value

    assert accountAfter["fCash"] == 0
    assert accountAfter["maturity"] == 0
    assert accountAfter["vaultShares"] == 0
    assert accountAfter2["fCash"] == 0
    assert accountAfter2["maturity"] == 0
    assert accountAfter2["vaultShares"] == 0

    # Account gets their share of strategy tokens here, nothing else
    assert strategyTokens == 0
    assert strategyTokens2 == 100_000e8
    # Account gets their share of the residuals
    assert pytest.approx(accountAfter["tempCashBalance"], abs=100) == -500_000e8
    assert accountAfter2["tempCashBalance"] == 500_000e8

    assert vaultConfig.getRemainingSettledTokens(vault.address, maturity) == (0, 0)
    assert vaultConfig.getReserveBalance(1) == 50_000_000e8 - 500_000e8


def test_settle_insolvent_vault(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000_000e8,
            totalStrategyTokens=0,
            totalAssetCash=49_500_000e8,
            totalfCash=-1_000_000e8,
        ),
    )
    vaultConfig.setSettledVaultState(vault.address, maturity, maturity + 100)

    account = get_vault_account(maturity=maturity, fCash=-10_000e8, vaultShares=0)
    account2 = get_vault_account(maturity=maturity, fCash=-900_000e8, vaultShares=1_000_000e8)

    assert vaultConfig.getRemainingSettledTokens(vault.address, maturity) == (0, -500_000e8)
    vaultConfig.setReserveBalance(1, 50_000_000e8)

    txn1 = vaultConfig.settleVaultAccount(vault.address, account, maturity + 100)
    (accountAfter, strategyTokens) = txn1.return_value

    txn2 = vaultConfig.settleVaultAccount(vault.address, account2, maturity + 100)
    (accountAfter2, strategyTokens2) = txn2.return_value

    assert accountAfter["fCash"] == 0
    assert accountAfter["maturity"] == 0
    assert accountAfter["vaultShares"] == 0
    assert accountAfter2["fCash"] == 0
    assert accountAfter2["maturity"] == 0
    assert accountAfter2["vaultShares"] == 0

    # No strategy tokens remaining
    assert strategyTokens == 0
    assert strategyTokens2 == 0
    # Account gets their share of the residuals
    assert pytest.approx(accountAfter["tempCashBalance"], abs=100) == -500_000e8
    assert accountAfter2["tempCashBalance"] == 4_500_000e8

    assert vaultConfig.getRemainingSettledTokens(vault.address, maturity) == (0, -500_000e8)
    assert vaultConfig.getReserveBalance(1) == 50_000_000e8 - 4_500_000e8


def get_collateral_ratio(vaultConfig, vault, **kwargs):
    vault.setExchangeRate(kwargs.get("exchangeRate", 1.2e28))

    account = get_vault_account(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        fCash=kwargs.get("fCash", -100_000e8),
        tempCashBalance=kwargs.get("tempCashBalance", 100e8),
        vaultShares=kwargs.get("accountVaultShares", 100_000e8),
    )

    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalAssetCash=kwargs.get("totalAssetCash", 100_000e8),
        totalVaultShares=kwargs.get("totalVaultShares", 100_000e8),
        totalStrategyTokens=kwargs.get("totalStrategyTokens", 100_000e8),
    )

    (collateralRatio, _) = vaultConfig.calculateCollateralRatio(vault.address, account, state)
    return collateralRatio


def test_collateral_ratio_decreases_with_debt(vaultConfig, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())

    fCash = 0
    decrement = -10_000e8
    lastCollateral = 2 ** 255
    for i in range(0, 20):
        ratio = get_collateral_ratio(vaultConfig, vault, fCash=fCash)
        fCash += decrement
        assert ratio < lastCollateral
        lastCollateral = ratio


def test_collateral_ratio_increases_with_exchange_rate(vaultConfig, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())

    exchangeRate = 1.2e28
    increment = 0.01e28
    lastCollateral = 0
    for i in range(0, 20):
        ratio = get_collateral_ratio(vaultConfig, vault, exchangeRate=exchangeRate)
        exchangeRate += increment
        assert ratio > lastCollateral
        lastCollateral = ratio


def test_collateral_ratio_increases_with_vault_shares(vaultConfig, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())

    vaultShares = 1000e8
    increment = 1000e8
    lastCollateral = 0
    for i in range(0, 20):
        ratio = get_collateral_ratio(
            vaultConfig, vault, fCash=-100e8, accountVaultShares=vaultShares, totalAssetCash=0
        )
        vaultShares += increment
        assert ratio > lastCollateral
        lastCollateral = ratio


def test_collateral_ratio_increases_with_vault_asset_cash(vaultConfig, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())

    assetCashHeld = 0
    increment = 10_000e8
    lastCollateral = 0
    for i in range(0, 20):
        ratio = get_collateral_ratio(vaultConfig, vault, totalAssetCash=assetCashHeld)
        assetCashHeld += increment
        assert ratio > lastCollateral
        lastCollateral = ratio

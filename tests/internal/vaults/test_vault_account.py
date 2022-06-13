import logging

import brownie
import pytest
from brownie import MockCToken, MockERC20
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from fixtures import *
from tests.constants import SECONDS_IN_MONTH, SECONDS_IN_QUARTER, START_TIME_TREF

VAULT_EPOCH_START = 1640736000


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


def test_settle_fails(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    account = get_vault_account(maturity=maturity, fCash=-100_00e8)

    with brownie.reverts("Not Settled"):
        vaultConfig.settleVaultAccount(
            vault.address, account, START_TIME_TREF + SECONDS_IN_QUARTER + 100
        )


def test_set_vault_settled_state(vaultConfig, accounts, vault):
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

    with brownie.reverts():
        vaultConfig.setSettledVaultState(vault.address, maturity, START_TIME_TREF + 100)

    vaultConfig.setSettledVaultState(vault.address, maturity, maturity + 100)
    state = vaultConfig.getVaultState(vault.address, maturity)
    assert state["isSettled"]
    assert state["settlementStrategyTokenValue"] == 1e8

    with brownie.reverts():
        vaultConfig.setSettledVaultState(vault.address, maturity, START_TIME_TREF + 200)


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


@pytest.mark.skip
@given(escrowedAssetCash=strategy("uint", min_value=100_000e8, max_value=300_000e8))
def test_settle_insolvent_account(vaultConfig, accounts, vault, escrowedAssetCash):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfig.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000_000e8,
            totalStrategyTokens=100_000e8,  # This represents profits
            totalAssetCash=50_000_000e8 - escrowedAssetCash,
            totalfCash=-1_000_000e8,
            totalEscrowedAssetCash=escrowedAssetCash,
        ),
    )
    vaultConfig.setSettledVaultState(vault.address, maturity, maturity + 100)

    account = get_vault_account(
        maturity=maturity, fCash=-10_000e8, escrowedAssetCash=escrowedAssetCash, vaultShares=0
    )
    account2 = get_vault_account(
        maturity=maturity,
        fCash=-1_000_000e8 + 10_000e8,
        escrowedAssetCash=0,
        vaultShares=1_000_000e8,
    )

    txn1 = vaultConfig.settleVaultAccount(vault.address, account, maturity + 100)
    (accountAfter, strategyTokens) = txn1.return_value

    txn2 = vaultConfig.settleVaultAccount(vault.address, account2, maturity + 100)
    (accountAfter2, strategyTokens2) = txn2.return_value

    assert accountAfter["fCash"] == 0
    assert accountAfter["maturity"] == 0
    assert accountAfter["escrowedAssetCash"] == 0
    assert accountAfter["vaultShares"] == 0
    assert accountAfter2["fCash"] == 0
    assert accountAfter2["maturity"] == 0
    assert accountAfter2["escrowedAssetCash"] == 0
    assert accountAfter2["vaultShares"] == 0

    # Account gets their share of strategy tokens here, nothing else
    assert strategyTokens == 0
    assert strategyTokens2 == 100_000e8
    # Account gets their share of the residuals
    assert pytest.approx(accountAfter["tempCashBalance"], abs=100) == -500_000e8 + escrowedAssetCash
    assert accountAfter2["tempCashBalance"] == 0


@given(
    currencyId=strategy("uint16", min_value=1, max_value=3),
    tempCashBalance=strategy("uint88", min_value=100_000e8, max_value=100_000_000e8),
    useUnderlying=strategy("bool"),
)
def test_transfer_cash_underlying_positive(
    cTokenVaultConfig, accounts, currencyId, useUnderlying, tempCashBalance
):
    account = get_vault_account(tempCashBalance=Wei(tempCashBalance))
    (assetToken, underlyingToken, _, _) = cTokenVaultConfig.getCurrencyAndRates(currencyId)
    cToken = MockCToken.at(assetToken["tokenAddress"])
    cToken.transfer(cTokenVaultConfig.address, 125_000_000e8, {"from": accounts[0]})

    if useUnderlying:
        token = MockERC20.at(underlyingToken["tokenAddress"])
        balanceBefore = token.balanceOf(accounts[0])
        expectedBalanceChange = Wei((tempCashBalance * cToken.exchangeRateStored()) / 1e18)
    else:
        token = MockCToken.at(assetToken["tokenAddress"])
        balanceBefore = token.balanceOf(accounts[0])
        expectedBalanceChange = tempCashBalance

    accountAfter = cTokenVaultConfig.transferTempCashBalance(
        account, currencyId, useUnderlying
    ).return_value
    balanceAfter = token.balanceOf(accounts[0])

    if useUnderlying and currencyId == 1:
        assert pytest.approx(balanceAfter - balanceBefore, abs=1e11) == expectedBalanceChange
    elif useUnderlying:
        assert pytest.approx(balanceAfter - balanceBefore, abs=2) == expectedBalanceChange
    else:
        assert balanceAfter - balanceBefore == expectedBalanceChange

    underlyingToken = MockERC20.at(underlyingToken["tokenAddress"])
    assert underlyingToken.balanceOf(cTokenVaultConfig) == 0
    assert accountAfter["tempCashBalance"] == 0


@given(
    currencyId=strategy("uint16", min_value=1, max_value=3),
    tempCashBalance=strategy("uint88", min_value=100_000e8, max_value=100_000_000e8),
    useUnderlying=strategy("bool"),
)
def test_transfer_cash_underlying_negative(
    cTokenVaultConfig, accounts, currencyId, useUnderlying, tempCashBalance
):
    account = get_vault_account(tempCashBalance=-Wei(tempCashBalance))
    (assetToken, underlyingToken, _, _) = cTokenVaultConfig.getCurrencyAndRates(currencyId)

    if useUnderlying:
        token = MockERC20.at(underlyingToken["tokenAddress"])
        token.approve(cTokenVaultConfig, 2 ** 255, {"from": accounts[0]})
        balanceBefore = token.balanceOf(accounts[0])
        cToken = MockCToken.at(assetToken["tokenAddress"])
        expectedBalanceChange = Wei((tempCashBalance * cToken.exchangeRateStored()) / 1e18)
    else:
        token = MockCToken.at(assetToken["tokenAddress"])
        token.approve(cTokenVaultConfig, 2 ** 255, {"from": accounts[0]})
        balanceBefore = token.balanceOf(accounts[0])
        expectedBalanceChange = tempCashBalance

    accountAfter = cTokenVaultConfig.transferTempCashBalance(
        account, currencyId, useUnderlying
    ).return_value
    balanceAfter = token.balanceOf(accounts[0])

    if useUnderlying and currencyId == 1:
        assert pytest.approx(balanceBefore - balanceAfter, abs=1e11) == expectedBalanceChange
    elif useUnderlying:
        assert pytest.approx(balanceBefore - balanceAfter, abs=2) == expectedBalanceChange
    else:
        assert balanceBefore - balanceAfter == expectedBalanceChange

    underlyingToken = MockERC20.at(underlyingToken["tokenAddress"])
    assert underlyingToken.balanceOf(cTokenVaultConfig) == 0
    assert accountAfter["tempCashBalance"] == 0


@given(
    currencyId=strategy("uint16", min_value=1, max_value=3),
    depositAmount=strategy("uint88", min_value=100_000, max_value=100_000_000),
    useUnderlying=strategy("bool"),
)
def test_deposit_into_account(
    cTokenVaultConfig, accounts, currencyId, useUnderlying, depositAmount
):
    account = get_vault_account()
    (assetToken, underlyingToken, _, _) = cTokenVaultConfig.getCurrencyAndRates(currencyId)

    if useUnderlying:
        token = MockERC20.at(underlyingToken["tokenAddress"])
        token.approve(cTokenVaultConfig, 2 ** 255, {"from": accounts[0]})
        balanceBefore = token.balanceOf(accounts[0])
        cToken = MockCToken.at(assetToken["tokenAddress"])
        depositAmount = depositAmount * (10 ** token.decimals())
        expectedTempCash = Wei((depositAmount * 1e18) / cToken.exchangeRateStored())
    else:
        token = MockCToken.at(assetToken["tokenAddress"])
        token.approve(cTokenVaultConfig, 2 ** 255, {"from": accounts[0]})
        balanceBefore = token.balanceOf(accounts[0])
        depositAmount = depositAmount * (10 ** token.decimals())
        expectedTempCash = depositAmount

    accountAfter = cTokenVaultConfig.depositIntoAccount(
        account, accounts[0], currencyId, depositAmount, useUnderlying
    ).return_value
    balanceAfter = token.balanceOf(accounts[0])
    assert balanceBefore - balanceAfter == depositAmount

    underlyingToken = MockERC20.at(underlyingToken["tokenAddress"])
    assert underlyingToken.balanceOf(cTokenVaultConfig) == 0
    assert pytest.approx(accountAfter["tempCashBalance"], abs=100) == expectedTempCash


# def test_deposit_aave_token_larger_decimals(vaultState):
#     pass

# def test_deposit_aave_token_smaller_decimals(vaultState):
#     pass


# def test_transfer_cash_aave_token_larger_decimals(vaultState):
#     pass

# def test_transfer_cash_aave_token_smaller_decimals(vaultState):
#     pass

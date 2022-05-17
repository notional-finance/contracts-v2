import brownie
import pytest
from brownie.test import given, strategy
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF

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


@given(epoch=strategy("uint16", min_value=1))
def test_maturities_and_epochs(vaultConfig, accounts, vault, epoch):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())

    account = get_vault_account(
        fCash=-100_000e8, maturity=VAULT_EPOCH_START + epoch * SECONDS_IN_QUARTER
    )
    vaultConfig.setVaultAccount(account, vault.address)
    assert account == vaultConfig.getVaultAccount(accounts[0].address, vault.address)


def test_settle_account_normal_conditions(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    state = get_vault_state(maturity=maturity)

    # No settlement (no fCash)
    account = get_vault_account(maturity=START_TIME_TREF + SECONDS_IN_QUARTER, fCash=0)
    (accountAfter, stateAfter) = vaultConfig.settleVaultAccount(
        vault.address, account, state, maturity + 100
    ).return_value
    assert account == accountAfter
    assert state == stateAfter

    # No settlement (before maturity)
    account = get_vault_account(maturity=maturity, fCash=-100e8, vaultShares=100e8)
    (accountAfter, stateAfter) = vaultConfig.settleVaultAccount(
        vault.address, account, state, maturity - 100
    ).return_value
    assert account == accountAfter
    assert state == stateAfter

    # Settlement fails, not fully settled
    with brownie.reverts("Vault not settled"):
        vaultConfig.settleVaultAccount(vault.address, account, state, maturity + 100)

    # Settlement succeeds, fully settled
    state = get_vault_state(maturity=maturity, isFullySettled=True)
    (accountAfter, stateAfter) = vaultConfig.settleVaultAccount(
        vault.address, account, state, maturity + 100
    ).return_value
    assert accountAfter.dict()["fCash"] == 0
    assert accountAfter.dict()["maturity"] == account[2]
    assert state == stateAfter
    assert not vaultConfig.requiresSettlement(accountAfter)


def test_settle_account_with_escrowed_asset_cash(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    state = get_vault_state(maturity=maturity, accountsRequiringSettlement=1, totalfCash=-1000e8)
    account = get_vault_account(maturity=maturity, fCash=-100e8, escrowedAssetCash=5010e8)

    (accountAfter, stateAfter) = vaultConfig.settleVaultAccount(
        vault.address, account, state, maturity + 100
    ).return_value
    assert stateAfter.dict()["accountsRequiringSettlement"] == 0
    assert stateAfter.dict()["totalfCash"] == -900e8
    assert accountAfter.dict()["fCash"] == 0
    assert accountAfter.dict()["escrowedAssetCash"] == 0
    assert accountAfter.dict()["tempCashBalance"] == 10e8
    assert not vaultConfig.requiresSettlement(accountAfter)

    account = get_vault_account(maturity=maturity, fCash=-100e8, escrowedAssetCash=5010e8)
    (accountAfter, stateAfter) = vaultConfig.settleVaultAccount(
        vault.address, account, state, maturity + 100
    ).return_value
    assert stateAfter.dict()["accountsRequiringSettlement"] == 0
    assert stateAfter.dict()["totalfCash"] == -900e8
    assert accountAfter.dict()["fCash"] == 0
    assert accountAfter.dict()["escrowedAssetCash"] == 0
    assert accountAfter.dict()["tempCashBalance"] == 10e8
    assert not vaultConfig.requiresSettlement(accountAfter)


def test_settle_account_escrowed_cash_insolvent(vaultConfig, accounts, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    state = get_vault_state(maturity=maturity, accountsRequiringSettlement=1, totalfCash=-1000e8)
    account = get_vault_account(
        maturity=maturity, fCash=-100e8, escrowedAssetCash=4990e8, vaultShares=100e8
    )

    # Need to sell more shares
    with brownie.reverts():
        vaultConfig.settleVaultAccount(vault.address, account, state, maturity + 100)

    account = get_vault_account(
        maturity=maturity, fCash=-100e8, escrowedAssetCash=4990e8, vaultShares=0
    )
    (accountAfter, stateAfter) = vaultConfig.settleVaultAccount(
        vault.address, account, state, maturity + 100
    ).return_value
    assert stateAfter.dict()["totalfCash"] == -900e8
    assert accountAfter.dict()["fCash"] == 0
    assert accountAfter.dict()["escrowedAssetCash"] == 0
    assert accountAfter.dict()["tempCashBalance"] == -10e8


# def test_deposit_asset_token_larger_decimals(vaultState):
#     pass

# def test_deposit_asset_token_smaller_decimals(vaultState):
#     pass

# def test_deposit_aave_token_larger_decimals(vaultState):
#     pass

# def test_deposit_aave_token_smaller_decimals(vaultState):
#     pass

# def test_deposit_underlying_token_larger_decimals(vaultState):
#     pass

# def test_deposit_underlying_token_smaller_decimals(vaultState):
#     pass

# def test_transfer_cash_asset_token_larger_decimals(vaultState):
#     pass

# def test_transfer_cash_asset_token_smaller_decimals(vaultState):
#     pass

# def test_transfer_cash_aave_token_larger_decimals(vaultState):
#     pass

# def test_transfer_cash_aave_token_smaller_decimals(vaultState):
#     pass

# def test_transfer_cash_underlying_token_larger_decimals(vaultState):
#     pass

# def test_transfer_cash_underlying_token_smaller_decimals(vaultState):
#     pass

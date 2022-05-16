import brownie
import pytest
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


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

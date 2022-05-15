import brownie
import pytest
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_cash_value_of_shares(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalAssetCash=1_000e8,
        totalVaultShares=100_000e8,
        totalStrategyTokens=100_000e8,
    )
    vault.setExchangeRate(1.2e28)

    assetCashValue = vaultConfig.getCashValueOfShare(vault.address, state, 100e8)

    assert assetCashValue == 6001e8


def test_get_and_set_vault_state(vaultConfig, vault):
    # TODO: randomize these values
    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalAssetCash=1_000e8,
        totalVaultShares=100_000e8,
        totalStrategyTokens=100_000e8,
    )
    vaultConfig.setVaultState(vault.address, state)

    assert state == vaultConfig.getVaultState(vault.address, state[0])


def test_exit_maturity_pool_failures(vaultConfig, vault):
    account = get_vault_account(vaultShares=100e8, tempCashBalance=0)
    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalAssetCash=1_000e8,
        totalVaultShares=100_000e8,
        totalStrategyTokens=100_000e8,
    )

    with brownie.reverts():
        # fails due to mismatched maturities
        vaultConfig.exitMaturityPool(state, account, 1e8)

    with brownie.reverts():
        account = get_vault_account(
            maturity=START_TIME_TREF + SECONDS_IN_QUARTER, vaultShares=100e8, tempCashBalance=0
        )
        # fails due to insufficient balance
        vaultConfig.exitMaturityPool(state, account, 150e8)


def test_exit_maturity_pool(vaultConfig, vault):
    accountShares = 100e8
    sharesRedeem = 10e8
    totalVaultShares = 100_000e8
    totalAssetCash = 100_000e8
    totalStrategyTokens = 100_000e8
    tempCashBalance = 0

    account = get_vault_account(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        vaultShares=accountShares,
        tempCashBalance=tempCashBalance,
    )
    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalAssetCash=totalAssetCash,
        totalVaultShares=totalVaultShares,
        totalStrategyTokens=totalStrategyTokens,
    )

    (tokens, newState, newAccount) = vaultConfig.exitMaturityPool(state, account, sharesRedeem)
    # Total Vault Shares Net Off
    assert totalVaultShares - newState.dict()["totalVaultShares"] == sharesRedeem
    # Total Cash Balance Nets Off
    assert (
        totalAssetCash - newState.dict()["totalAssetCash"]
        == newAccount.dict()["tempCashBalance"] - tempCashBalance
    )
    # Total Strategy Tokens Nets Off
    assert totalStrategyTokens - newState.dict()["totalStrategyTokens"] == tokens


# @pytest.mark.only
# def test_enter_maturity_pool_no_previous(vaultConfig, vault):
#     pass


# def test_enter_maturity_with_previous(vaultConfig, vault):
#     pass


# def test_enter_maturity_with_same(vaultConfig, vault):
#     pass


# def test_leverage_calculation(vaultState):
#     pass

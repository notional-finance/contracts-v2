import brownie
import pytest
from brownie.test import given, strategy
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
    vault.setExchangeRate(1.2e18)

    assetCashValue = vaultConfig.getCashValueOfShare(vault.address, accounts[0], state, 100e8)

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
        vaultConfig.exitMaturity(state, account, 1e8)

    with brownie.reverts():
        account = get_vault_account(
            maturity=START_TIME_TREF + SECONDS_IN_QUARTER, vaultShares=100e8, tempCashBalance=0
        )
        # fails due to insufficient balance
        vaultConfig.exitMaturity(state, account, 150e8)


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

    (tokens, newState, newAccount) = vaultConfig.exitMaturity(state, account, sharesRedeem)
    # Total Vault Shares Net Off
    assert totalVaultShares - newState.dict()["totalVaultShares"] == sharesRedeem
    # Total Cash Balance Nets Off
    assert (
        totalAssetCash - newState.dict()["totalAssetCash"]
        == newAccount.dict()["tempCashBalance"] - tempCashBalance
    )
    # Total Strategy Tokens Nets Off
    assert totalStrategyTokens - newState.dict()["totalStrategyTokens"] == tokens


@given(
    strategyTokenDeposit=strategy("uint", min_value=0, max_value=200_000e8),
    isMaturity=strategy("bool"),
)
def test_enter_maturity(vaultConfig, vault, cToken, accounts, strategyTokenDeposit, isMaturity):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    tempCashBalance = 500e8
    totalVaultShares = 100_000e8
    totalStrategyTokens = 100_000e8

    maturity = START_TIME_TREF + SECONDS_IN_QUARTER if isMaturity else 0
    accountVaultShares = 500e8 if isMaturity else 0

    account = get_vault_account(
        maturity=maturity, tempCashBalance=tempCashBalance, vaultShares=accountVaultShares
    )
    state = get_vault_state(
        maturity=maturity,
        totalVaultShares=totalVaultShares,
        totalStrategyTokens=totalStrategyTokens,
    )

    cToken.transfer(vaultConfig.address, tempCashBalance, {"from": accounts[0]})
    vault.setExchangeRate(2e18)

    (newState, newAccount) = vaultConfig.enterMaturity(
        vault.address, state, account, strategyTokenDeposit, tempCashBalance / 50, ""
    ).return_value
    # Total Vault Shares Net Off
    assert (
        newState.dict()["totalVaultShares"] - totalVaultShares
        == newAccount.dict()["vaultShares"] - accountVaultShares
    )
    # Total Cash Balance Nets Off
    assert newState.dict()["totalAssetCash"] == 0
    assert newAccount.dict()["tempCashBalance"] == 0
    # Total Strategy Tokens Nets Off
    assert (
        newState.dict()["totalStrategyTokens"] - totalStrategyTokens == 5e8 + strategyTokenDeposit
    )

    (assetCash, strategyTokens) = vaultConfig.getPoolShare(
        newState, newAccount.dict()["vaultShares"] - accountVaultShares
    )
    assert assetCash == 0
    # Account has a claim on all new strategy tokens
    assert strategyTokens == newState.dict()["totalStrategyTokens"] - totalStrategyTokens


def test_enter_maturity_with_old_maturity(vaultConfig, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    account = get_vault_account(maturity=START_TIME_TREF + 3 * SECONDS_IN_QUARTER)
    state = get_vault_state(maturity=START_TIME_TREF + 2 * SECONDS_IN_QUARTER)

    # Cannot enter a maturity pool with a mismatched maturity
    with brownie.reverts():
        vaultConfig.enterMaturity(vault.address, state, account, 0, 0, "")

    account = get_vault_account(maturity=START_TIME_TREF + SECONDS_IN_QUARTER, vaultShares=100e8)
    state = get_vault_state(maturity=START_TIME_TREF + 2 * SECONDS_IN_QUARTER)

    # Cannot enter a maturity pool with a mismatched maturity
    with brownie.reverts():
        vaultConfig.enterMaturity(vault.address, state, account, 0, 0, "")


def test_enter_maturity_with_asset_cash(vaultConfig, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    account = get_vault_account(maturity=START_TIME_TREF + SECONDS_IN_QUARTER)
    state = get_vault_state(maturity=START_TIME_TREF + SECONDS_IN_QUARTER, totalAssetCash=100_000e8)

    # Cannot enter a maturity pool with asset cash
    with brownie.reverts():
        vaultConfig.enterMaturity(vault.address, state, account, 0, 0, "")

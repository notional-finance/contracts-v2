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
    vault.setExchangeRate(1.2e18)

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


def test_enter_maturity_pool_no_maturity(vaultConfig, vault, cToken, accounts):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    tempCashBalance = 500e8
    totalVaultShares = 100_000e8
    totalStrategyTokens = 100_000e8

    account = get_vault_account(tempCashBalance=tempCashBalance)

    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalVaultShares=totalVaultShares,
        totalStrategyTokens=totalStrategyTokens,
    )

    cToken.transfer(vaultConfig.address, tempCashBalance, {"from": accounts[0]})
    vault.setExchangeRate(2e18)

    (newState, newAccount) = vaultConfig.enterMaturityPool(
        vault.address, state, account, 0, ""
    ).return_value
    # Total Vault Shares Net Off
    assert (
        newState.dict()["totalVaultShares"] - totalVaultShares == newAccount.dict()["vaultShares"]
    )
    # Total Cash Balance Nets Off
    assert newState.dict()["totalAssetCash"] == 0
    assert newAccount.dict()["tempCashBalance"] == 0
    # Total Strategy Tokens Nets Off
    assert newState.dict()["totalStrategyTokens"] - totalStrategyTokens == 5e8

    (assetCash, strategyTokens) = vaultConfig.getPoolShare(
        newState, newAccount.dict()["vaultShares"]
    )
    assert assetCash == 0
    # Account has a claim on all new strategy tokens
    assert strategyTokens == newState.dict()["totalStrategyTokens"] - totalStrategyTokens


# TODO: test with strategy token deposit
def test_enter_maturity_with_same_maturity(vaultConfig, vault, cToken, accounts):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    tempCashBalance = 500e8
    accountVaultShares = 500e8
    totalVaultShares = 100_000e8
    totalStrategyTokens = 100_000e8

    account = get_vault_account(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        tempCashBalance=tempCashBalance,
        vaultShares=accountVaultShares,
    )

    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalVaultShares=totalVaultShares,
        totalStrategyTokens=totalStrategyTokens,
    )

    cToken.transfer(vaultConfig.address, tempCashBalance, {"from": accounts[0]})
    vault.setExchangeRate(2e18)

    (newState, newAccount) = vaultConfig.enterMaturityPool(
        vault.address, state, account, 0, ""
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
    assert newState.dict()["totalStrategyTokens"] - totalStrategyTokens == 5e8

    (assetCash, strategyTokens) = vaultConfig.getPoolShare(
        newState, newAccount.dict()["vaultShares"] - accountVaultShares
    )
    assert assetCash == 0
    # Account has a claim on all new strategy tokens
    assert strategyTokens == newState.dict()["totalStrategyTokens"] - totalStrategyTokens


def test_enter_maturity_with_old_maturity(vaultConfig, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())
    account = get_vault_account(maturity=START_TIME_TREF + SECONDS_IN_QUARTER)
    state = get_vault_state(maturity=START_TIME_TREF + 2 * SECONDS_IN_QUARTER)

    # Cannot enter a maturity pool with a mismatched maturity
    with brownie.reverts():
        vaultConfig.enterMaturityPool(vault.address, state, account, 0, "")


def get_collateral_ratio(vaultConfig, vault, **kwargs):
    vault.setExchangeRate(kwargs.get("exchangeRate", 1.2e28))

    account = get_vault_account(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        fCash=kwargs.get("fCash", -100_000e8),
        escrowedAssetCash=kwargs.get("escrowedAssetCash", 0),
        tempCashBalance=kwargs.get("tempCashBalance", 100e8),
        vaultShares=kwargs.get("accountVaultShares", 100_000e8),
    )

    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalAssetCash=kwargs.get("totalAssetCash", 100_000e8),
        totalVaultShares=kwargs.get("totalVaultShares", 100_000e8),
        totalStrategyTokens=kwargs.get("totalStrategyTokens", 100_000e8),
    )

    return vaultConfig.calculateCollateralRatio(vault.address, account, state)


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


def test_collateral_ratio_increases_with_escrowed_cash(vaultConfig, vault):
    vaultConfig.setVaultConfig(vault.address, get_vault_config())

    escrowedAssetCash = 0
    increment = 1000e8
    lastCollateral = 0
    for i in range(0, 20):
        ratio = get_collateral_ratio(vaultConfig, vault, escrowedAssetCash=escrowedAssetCash)
        escrowedAssetCash += increment
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

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_initialize_and_enable_vault_authorization(environment, vault, accounts):
    with brownie.reverts():
        # Will revert on non-owner
        environment.notional.updateVault(
            vault.address,
            get_vault_config(flags=set_flags(0, ENABLED=True)),
            100_000_000e8,
            {"from": accounts[1]},
        )

    txn = environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
        {"from": accounts[0]},
    )
    assert txn.events["VaultChange"]["vaultAddress"] == vault.address
    assert txn.events["VaultChange"]["enabled"]

    with brownie.reverts():
        # Will revert on non-owner
        environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[1]})

    environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[0]})


def test_pause_vault(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True)), 100_000_000e8
    )
    environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[0]})
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts("Cannot Enter"):
        # Vault is disabled, cannot enter
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            True,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    with brownie.reverts("No Roll Allowed"):
        # Vault is disabled, cannot enter
        environment.notional.rollVaultPosition(
            accounts[1], vault.address, maturity, 100_000e8, (0, 0, ""), {"from": accounts[1]}
        )


def test_deposit_and_redeem_vault_auth(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True)), 100_000_000e8
    )

    with brownie.reverts("Paused"):
        # This is not an activated vault
        environment.notional.depositVaultCashToStrategyTokens(
            START_TIME_TREF + SECONDS_IN_QUARTER, 100_000e8, "", {"from": accounts[1]}
        )

        environment.notional.redeemStrategyTokensToCash(
            START_TIME_TREF + SECONDS_IN_QUARTER, 100_000e8, "", {"from": accounts[1]}
        )


def test_redeem_strategy_tokens(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettle(vault, maturity)
    assert underlyingCash == 100_000e18
    assert assetCash == 5_000_000e8

    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Redeems a portion of the strategy tokens to repay debt
    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Collateral ratio does not change when redeeming and depositing tokens, unless prices change
    assert collateralRatioBefore == collateralRatioAfter
    # Nothing about the vault account changes
    assert vaultAccountAfter == vaultAccountBefore

    assert vaultStateBefore["totalAssetCash"] == vaultStateAfter["totalAssetCash"] - 500_000e8
    assert (
        vaultStateBefore["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"] + 10_000e8
    )

    (assetCashAfter, underlyingCashAfter) = environment.notional.getCashRequiredToSettle(
        vault, maturity
    )
    assert underlyingCash - 10_000e18 == underlyingCashAfter
    assert assetCash - 500_000e8 == assetCashAfter

    check_system_invariants(environment, accounts, [vault])


def test_deposit_asset_cash(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    # Put some cash on the vault
    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettle(vault, maturity)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Redeems a portion of the strategy tokens to repay debt
    environment.notional.depositVaultCashToStrategyTokens(maturity, 250_000e8, "", {"from": vault})

    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Collateral ratio does not change when redeeming and depositing tokens, unless prices change
    assert collateralRatioBefore == collateralRatioAfter
    # Nothing about the vault account changes
    assert vaultAccountAfter == vaultAccountBefore

    assert vaultStateBefore["totalAssetCash"] == vaultStateAfter["totalAssetCash"] + 250_000e8
    assert (
        vaultStateBefore["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"] - 5_000e8
    )

    (assetCashAfter, underlyingCashAfter) = environment.notional.getCashRequiredToSettle(
        vault, maturity
    )
    assert underlyingCash + 5_000e18 == underlyingCashAfter
    assert assetCash + 250_000e8 == assetCashAfter

    check_system_invariants(environment, accounts, [vault])


@pytest.mark.only
def test_deposit_asset_cash_fails_collateral_ratio(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    # Lower the exchange rate, vault is insolvency right now
    vault.setExchangeRate(0.6e18)

    # Always possible to redeem strategy tokens to cash
    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    # Not possible to re-enter vault
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.depositVaultCashToStrategyTokens(
            maturity, 250_000e8, "", {"from": vault}
        )

    check_system_invariants(environment, accounts, [vault])


@pytest.mark.skip
def test_settle_vault_vault_not_ready(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    maturity = environment.notional.getCurrentVaultMaturity(vault)
    environment.notional.redeemStrategyTokensToCash(maturity, 10_000e8, "", {"from": vault})

    with brownie.reverts("Cannot Settle"):
        # Cannot settle before maturity
        environment.notional.settleVault(vault, maturity, [], [], "", {"from": accounts[1]})

    chain.mine(1, timestamp=maturity)

    with brownie.reverts("Cannot Settle"):
        # Cannot if the vault is reporting insufficient cash
        environment.notional.settleVault(vault, maturity, [], [], "", {"from": accounts[1]})

    check_system_invariants(environment, accounts, [vault])


@pytest.mark.skip
def test_settle_vault_no_manual_accounts(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    maturity = environment.notional.getCurrentVaultMaturity(vault)
    environment.notional.redeemStrategyTokensToCash(maturity, 100_000e8, "", {"from": vault})

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettleCurrent(vault)
    assert assetCash == 0
    assert underlyingCash == 0

    chain.mine(1, timestamp=maturity)

    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    environment.notional.settleVault(vault, maturity, [], [], "", {"from": accounts[1]})

    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    assert vaultAccountBefore == vaultAccountAfter
    assert collateralRatioBefore == collateralRatioAfter

    assert vaultStateAfter["totalfCash"] == 0
    assert vaultStateAfter["totalfCashRequiringSettlement"] == 0
    assert vaultStateAfter["isFullySettled"]
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateBefore["totalVaultShares"] == vaultStateAfter["totalVaultShares"]
    assert vaultStateAfter["totalAssetCash"] == 0
    assert vaultStateBefore["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"]

    check_system_invariants(environment, accounts, [vault])


@pytest.mark.skip
def test_settle_vault_shortfall_failed_to_sell_tokens(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    maturity = environment.notional.getCurrentVaultMaturity(vault)
    vaultState = environment.notional.getCurrentVaultState(vault)
    vault.setExchangeRate(0.75e18)
    environment.notional.redeemStrategyTokensToCash(
        maturity, vaultState["totalVaultShares"] - 100, "", {"from": vault}
    )

    chain.mine(1, timestamp=maturity)
    vault.setForceSettle(True)
    assert vault.totalSupply() > 0

    with brownie.reverts("Redeem all tokens"):
        # There are still strategy tokens left to redeem
        environment.notional.settleVault(vault, maturity, [], [], "", {"from": accounts[1]})

    check_system_invariants(environment, accounts, [vault])


@pytest.mark.skip
def test_settle_vault_cover_shortfall_with_reserve_no_manual(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    maturity = environment.notional.getCurrentVaultMaturity(vault)
    vaultState = environment.notional.getCurrentVaultState(vault)
    vault.setExchangeRate(0.75e18)
    environment.notional.redeemStrategyTokensToCash(
        maturity, vaultState["totalStrategyTokens"], "", {"from": vault}
    )

    chain.mine(1, timestamp=maturity)

    vaultStateBefore = environment.notional.getVaultState(vault, maturity)

    reserveBalance = environment.notional.getReserveBalance(2)
    environment.cToken["DAI"].transfer(
        environment.notional.address, 5_000_000e8, {"from": accounts[0]}
    )
    environment.notional.setReserveCashBalance(
        2, 5_000_000e8 + reserveBalance, {"from": accounts[0]}
    )

    environment.notional.settleVault(vault, maturity, [], [], "", {"from": accounts[1]})

    reserveBalance = environment.notional.getReserveBalance(2)
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    assert vaultStateAfter["totalfCash"] == 0
    assert vaultStateAfter["totalfCashRequiringSettlement"] == 0
    assert vaultStateAfter["isFullySettled"]
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateAfter["totalVaultShares"] == vaultStateBefore["totalVaultShares"]
    assert vaultStateAfter["totalAssetCash"] == 0
    assert vaultStateAfter["totalStrategyTokens"] == 0

    assert reserveBalance < 5_000_000e8

    # Vault is now disabled
    with brownie.reverts("Cannot Enter"):
        environment.notional.enterVault(
            accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


@pytest.mark.skip
def test_settle_vault_insolvent_no_manual_accounts(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    maturity = environment.notional.getCurrentVaultMaturity(vault)
    vaultState = environment.notional.getCurrentVaultState(vault)
    vault.setExchangeRate(0.75e18)
    environment.notional.redeemStrategyTokensToCash(
        maturity, vaultState["totalVaultShares"], "", {"from": vault}
    )

    chain.mine(1, timestamp=maturity)

    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)

    reserveBalance = environment.notional.getReserveBalance(2)
    environment.cToken["DAI"].transfer(
        environment.notional.address, 50_000e8, {"from": accounts[0]}
    )
    environment.notional.setReserveCashBalance(2, 50_000e8 + reserveBalance, {"from": accounts[0]})

    txn = environment.notional.settleVault(vault, maturity, [], [], "", {"from": accounts[1]})

    assert environment.notional.getReserveBalance(2) == 0

    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    assert vaultStateAfter["totalfCash"] == 0
    assert vaultStateAfter["totalfCashRequiringSettlement"] == 0
    assert vaultStateAfter["isFullySettled"]
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateAfter["totalVaultShares"] == vaultStateBefore["totalVaultShares"]
    assert vaultStateAfter["totalAssetCash"] == 0
    assert vaultStateBefore["totalStrategyTokens"] == 0

    assert txn.events["ProtocolInsolvency"]

    # Vault is now disabled
    with brownie.reverts("Cannot Enter"):
        environment.notional.enterVault(
            accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )

    # Transfer the shortfall amount in so that we can check all the other invariants
    environment.cToken["DAI"].transfer(
        environment.notional.address,
        txn.events["ProtocolInsolvency"]["shortfall"],
        {"from": accounts[0]},
    )
    check_system_invariants(environment, accounts, [vault])


@pytest.mark.skip
def test_settle_vault_manual_insufficient_shares_sold(
    environment, vault, escrowed_account, accounts
):
    maturity = environment.notional.getCurrentVaultMaturity(vault)
    chain.mine(1, timestamp=maturity)

    with brownie.reverts():
        # Not enough vault shares are sold to resolve this settlement
        environment.notional.settleVault(
            vault, maturity, [escrowed_account.address], [100e8], "", {"from": accounts[0]}
        )

    check_system_invariants(environment, accounts, [vault])


@pytest.mark.skip
def test_settle_vault_no_shortfall_manual_accounts(environment, vault, escrowed_account, accounts):
    # TODO: need to simulate part of the asset cash being pulled as well...

    maturity = environment.notional.getCurrentVaultMaturity(vault)
    chain.mine(1, timestamp=maturity)
    vaultAccount = environment.notional.getVaultAccount(escrowed_account, vault)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)

    vaultSharesRequiredToSettle = (
        Wei(-(vaultAccount["escrowedAssetCash"] / 50 + vaultAccount["fCash"]) / 0.95) + 100
    )
    environment.notional.settleVault(
        vault,
        maturity,
        [escrowed_account.address],
        [vaultSharesRequiredToSettle],
        "",
        {"from": accounts[0]},
    )

    vaultAccountAfter = environment.notional.getVaultAccount(escrowed_account, vault)
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)

    assert vaultStateAfter["totalfCash"] == 0
    assert vaultStateAfter["totalfCashRequiringSettlement"] == 0
    assert vaultStateAfter["isFullySettled"]
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert (
        vaultStateAfter["totalVaultShares"]
        == vaultStateBefore["totalVaultShares"] - vaultSharesRequiredToSettle
    )
    assert vaultStateAfter["totalAssetCash"] == 0
    assert (
        vaultStateAfter["totalStrategyTokens"]
        == vaultStateBefore["totalVaultShares"] - vaultSharesRequiredToSettle
    )

    assert vaultAccountAfter["fCash"] == 0
    assert vaultAccountAfter["escrowedAssetCash"] == 0
    assert (
        vaultAccountAfter["vaultShares"]
        == vaultAccount["vaultShares"] - vaultSharesRequiredToSettle
    )
    check_system_invariants(environment, accounts, [vault])

import brownie
import pytest
from brownie.network.state import Chain
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF
from tests.internal.vaults.fixtures import get_vault_config, set_flags

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_initialize_and_enable_vault_authorization(environment, vault, accounts):
    with brownie.reverts():
        # Will revert on non-owner
        environment.notional.updateVault(
            vault.address, get_vault_config(flags=set_flags(0, ENABLED=True)), {"from": accounts[1]}
        )

    txn = environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True)), {"from": accounts[0]}
    )
    assert txn.events["VaultChange"]["vaultAddress"] == vault.address
    assert txn.events["VaultChange"]["enabled"]

    with brownie.reverts():
        # Will revert on non-owner
        environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[1]})

    environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[0]})


def test_pause_vault(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True))
    )
    environment.notional.setVaultPauseStatus(vault.address, False, {"from": accounts[0]})

    with brownie.reverts("Cannot Enter"):
        # Vault is disabled, cannot enter
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
        )

    with brownie.reverts("No Roll Allowed"):
        # Vault is disabled, cannot enter
        environment.notional.rollVaultPosition(
            accounts[1], vault.address, 100_000, 100_000e8, (0, 0, "", ""), {"from": accounts[1]}
        )


def test_deposit_and_redeem_vault_auth(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True))
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
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettleCurrent(vault)
    assert underlyingCash == 100_000e18
    assert assetCash == 5_000_000e8

    vaultStateBefore = environment.notional.getCurrentVaultState(vault)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Redeems a portion of the strategy tokens to repay debt
    environment.notional.redeemStrategyTokensToCash(
        environment.notional.getCurrentVaultMaturity(vault), 10_000e8, "", {"from": vault}
    )

    vaultStateAfter = environment.notional.getCurrentVaultState(vault)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Collateral ratio increases due to less debt
    assert collateralRatioBefore < collateralRatioAfter
    # Nothing about the vault account changes
    assert vaultAccountAfter == vaultAccountBefore

    assert vaultStateBefore["totalfCash"] == vaultStateAfter["totalfCash"]
    assert (
        vaultStateBefore["totalfCashRequiringSettlement"]
        == vaultStateAfter["totalfCashRequiringSettlement"]
    )
    assert not vaultStateAfter["isFullySettled"]
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateBefore["totalVaultShares"] == vaultStateAfter["totalVaultShares"]
    assert vaultStateBefore["totalAssetCash"] == vaultStateAfter["totalAssetCash"] - 500_000e8
    assert (
        vaultStateBefore["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"] + 10_000e8
    )

    (assetCashAfter, underlyingCashAfter) = environment.notional.getCashRequiredToSettleCurrent(
        vault
    )
    assert underlyingCash - 10_000e18 == underlyingCashAfter
    assert assetCash - 500_000e8 == assetCashAfter


def test_deposit_asset_cash(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    # Put some cash on the vault
    environment.notional.redeemStrategyTokensToCash(
        environment.notional.getCurrentVaultMaturity(vault), 10_000e8, "", {"from": vault}
    )

    (assetCash, underlyingCash) = environment.notional.getCashRequiredToSettleCurrent(vault)
    vaultStateBefore = environment.notional.getCurrentVaultState(vault)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Redeems a portion of the strategy tokens to repay debt
    environment.notional.depositVaultCashToStrategyTokens(
        environment.notional.getCurrentVaultMaturity(vault), 250_000e8, "", {"from": vault}
    )

    vaultStateAfter = environment.notional.getCurrentVaultState(vault)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Collateral ratio increases due to more debt
    assert collateralRatioBefore > collateralRatioAfter
    # Nothing about the vault account changes
    assert vaultAccountAfter == vaultAccountBefore

    assert vaultStateBefore["totalfCash"] == vaultStateAfter["totalfCash"]
    assert (
        vaultStateBefore["totalfCashRequiringSettlement"]
        == vaultStateAfter["totalfCashRequiringSettlement"]
    )
    assert not vaultStateAfter["isFullySettled"]
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateBefore["totalVaultShares"] == vaultStateAfter["totalVaultShares"]
    assert vaultStateBefore["totalAssetCash"] == vaultStateAfter["totalAssetCash"] + 250_000e8
    assert (
        vaultStateBefore["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"] - 5_000e8
    )

    (assetCashAfter, underlyingCashAfter) = environment.notional.getCashRequiredToSettleCurrent(
        vault
    )
    assert underlyingCash + 5_000e18 == underlyingCashAfter
    assert assetCash + 250_000e8 == assetCashAfter


def test_deposit_asset_cash_fails_collateral_ratio(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    # Lower the exchange rate, vault is insolvency right now
    vault.setExchangeRate(0.6e18)

    # Always possible to redeem strategy tokens to cash
    environment.notional.redeemStrategyTokensToCash(
        environment.notional.getCurrentVaultMaturity(vault), 10_000e8, "", {"from": vault}
    )

    # Not possible to re-enter vault
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.depositVaultCashToStrategyTokens(
            environment.notional.getCurrentVaultMaturity(vault), 250_000e8, "", {"from": vault}
        )


def test_settle_vault_vault_not_ready(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
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


def test_settle_vault_no_manual_accounts(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
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


# @pytest.mark.only
# def test_settle_vault_with_shortfall_no_manual_accounts(environment, vault, account):
#     environment.notional.updateVault(
#         vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
#     )

#     environment.notional.enterVault(
#         accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
#     )

#     maturity = environment.notional.getCurrentVaultMaturity(vault)
#     environment.notional.redeemStrategyTokensToCash(maturity, 100_000e8, "", {"from": vault})


# def test_settle_vault_partial_manual_accounts()
# def test_settle_vault_all_manual_accounts()
# def test_settle_vault_with_shortfall_manual_accounts()

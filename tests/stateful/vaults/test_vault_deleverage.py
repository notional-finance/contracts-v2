import brownie
import pytest
from brownie.network.state import Chain
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF
from tests.internal.vaults.fixtures import get_vault_config, set_flags


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_deleverage_authentication(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True, ONLY_VAULT_DELEVERAGE=1)),
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )
    vault.setExchangeRate(0.85e18)
    (cr, _) = environment.notional.getVaultAccountCollateralRatio(accounts[1], vault)
    assert cr < 0.2e9

    with brownie.reverts("Unauthorized"):
        # Only vault can call liquidation
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, True, "", {"from": accounts[2]}
        )

    with brownie.reverts("Unauthorized"):
        # Liquidator cannot equal account
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[1], 25_000e18, True, "", {"from": vault.address}
        )

    # Anyone can call deleverage now
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    with brownie.reverts("Unauthorized"):
        # Cannot liquidate self
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[1], 25_000e18, True, "", {"from": accounts[1]}
        )

    with brownie.reverts("Unauthorized"):
        # Cannot liquidate self, second test
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, True, "", {"from": accounts[1]}
        )


def test_deleverage_account_sufficient_collateral(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    with brownie.reverts("Sufficient Collateral"):
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, True, "", {"from": accounts[2]}
        )


def test_deleverage_account_over_balance(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.85e18)

    with brownie.reverts():
        # This is more shares than the vault has
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 150_000e18, True, "", {"from": accounts[2]}
        )


def test_deleverage_account_over_deleverage(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.85e18)

    with brownie.reverts("Over Deleverage Limit"):
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 100_000e18, True, "", {"from": accounts[2]}
        )


def test_deleverage_account(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.95e18)

    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    vaultStateBefore = environment.notional.getCurrentVaultState(vault)
    balanceBefore = environment.token["DAI"].balanceOf(accounts[2])

    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 25_000e18, True, "", {"from": accounts[2]}
    )

    balanceAfter = environment.token["DAI"].balanceOf(accounts[2])
    vaultStateAfter = environment.notional.getCurrentVaultState(vault)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    assert collateralRatioBefore < collateralRatioAfter
    vaultSharesSold = vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"]
    # Shares sold is approx equal to amount deposited scaled by the exchange rate and multiplied by
    # the liquidation discount
    assert pytest.approx(vaultSharesSold, rel=1e-08) == (25_000e8 / 0.95 * 1.04)
    assert vaultAccountBefore["maturity"] == vaultAccountAfter["maturity"]
    # 25_000e18 in asset cash terms
    assert vaultAccountAfter["escrowedAssetCash"] == 25_000e8 * 50

    # Simple vault lets these redeem at par
    assert pytest.approx((balanceAfter - balanceBefore) / 1e10, rel=1e-08) == (
        vaultSharesSold / 0.95 - 25_000e8
    )
    assert (
        vaultStateBefore["totalVaultShares"] - vaultStateAfter["totalVaultShares"]
        == vaultSharesSold
    )
    assert vaultStateAfter["accountsRequiringSettlement"] == 1
    assert vaultStateAfter["totalfCash"] == -100_000e8
    assert vaultStateAfter["totalfCashRequiringSettlement"] == 0


# def test_exit_vault_with_escrowed_asset_cash(environment, vault, accounts)
# def test_enter_vault_with_escrowed_asset_cash(environment, accounts):
# def test_roll_vault_with_escrowed_asset_cash(environment, accounts):

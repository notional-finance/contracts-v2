import brownie
import pytest
from brownie.network.state import Chain
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_deleverage_authentication(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True, ONLY_VAULT_DELEVERAGE=1)),
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
    vault.setExchangeRate(0.85e18)
    (cr, _) = environment.notional.getVaultAccountCollateralRatio(accounts[1], vault)
    assert cr < 0.2e9

    with brownie.reverts("Unauthorized"):
        # Only vault can call liquidation
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, "", {"from": accounts[2]}
        )

    with brownie.reverts("Unauthorized"):
        # Liquidator cannot equal account
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[1], 25_000e18, "", {"from": vault.address}
        )

    # Anyone can call deleverage now
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )

    with brownie.reverts("Unauthorized"):
        # Cannot liquidate self
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[1], 25_000e18, "", {"from": accounts[1]}
        )

    with brownie.reverts("Unauthorized"):
        # Cannot liquidate self, second test
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, "", {"from": accounts[1]}
        )


def test_deleverage_account_sufficient_collateral(environment, accounts, vault):
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

    with brownie.reverts("Sufficient Collateral"):
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, "", {"from": accounts[2]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_deleverage_account_over_balance(environment, accounts, vault):
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

    vault.setExchangeRate(0.85e18)

    with brownie.reverts():
        # This is more shares than the vault has
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 150_000e18, "", {"from": accounts[2]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_deleverage_account_over_deleverage(environment, accounts, vault):
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

    vault.setExchangeRate(0.85e18)

    with brownie.reverts("Over Deleverage Limit"):
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 100_000e18, "", {"from": accounts[2]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_cannot_deleverage_account_after_maturity(environment, accounts, vault):
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

    vault.setExchangeRate(0.85e18)
    chain.mine(1, timestamp=maturity)

    with brownie.reverts():
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 100_000e18, "", {"from": accounts[2]}
        )


def test_deleverage_account(environment, accounts, vault):
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

    vault.setExchangeRate(0.95e18)

    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    balanceBefore = environment.token["DAI"].balanceOf(accounts[2])

    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 25_000e18, "", {"from": accounts[2]}
    )

    balanceAfter = environment.token["DAI"].balanceOf(accounts[2])
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
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
    assert vaultAccountBefore["fCash"] == vaultAccountAfter["fCash"] + 25_000e8

    assert pytest.approx((balanceAfter - balanceBefore) / 1e10, rel=1e-08) == (
        vaultSharesSold * 0.95 - 25_000e8
    )
    assert (
        vaultStateBefore["totalVaultShares"] - vaultStateAfter["totalVaultShares"]
        == vaultSharesSold
    )

    check_system_invariants(environment, accounts, [vault])


def test_cannot_deleverage_liquidator_matured_shares(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True, TRANSFER_SHARES_ON_DELEVERAGE=True)
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    # Set up the liquidator such that they have matured vault shares
    environment.notional.enterVault(
        accounts[2],
        vault.address,
        25_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[2]},
    )

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False, {"from": accounts[0]})
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

    vault.setExchangeRate(0.95e18)

    with brownie.reverts("Vault Shares Mismatch"):
        # account[2] cannot liquidate this account because they have matured vault shares
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, "", {"from": accounts[2]}
        )


def test_deleverage_account_transfer_shares(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True, TRANSFER_SHARES_ON_DELEVERAGE=True)
        ),
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

    vault.setExchangeRate(0.95e18)

    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 25_000e18, "", {"from": accounts[2]}
    )

    liquidatorAccount = environment.notional.getVaultAccount(accounts[2], vault)
    # vaultStateAfter = environment.notional.getVaultState(vault, maturity)
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
    assert vaultAccountBefore["fCash"] == vaultAccountAfter["fCash"] + 25_000e8

    assert liquidatorAccount["maturity"] == vaultAccountAfter["maturity"]
    assert liquidatorAccount["vaultShares"] == vaultSharesSold

    check_system_invariants(environment, accounts, [vault])

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
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )
    vault.setExchangeRate(0.85e18)
    (cr, _, _, _) = environment.notional.getVaultAccountCollateralRatio(accounts[1], vault)
    assert cr < 0.2e9

    with brownie.reverts("Unauthorized"):
        # Only vault can call liquidation
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, False, "", {"from": accounts[2]}
        )

    with brownie.reverts("Unauthorized"):
        # Liquidator cannot equal account
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[1], 25_000e18, False, "", {"from": vault.address}
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
            accounts[1], vault.address, accounts[1], 25_000e18, False, "", {"from": accounts[1]}
        )

    with brownie.reverts("Unauthorized"):
        # Cannot liquidate self, second test
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, False, "", {"from": accounts[1]}
        )

    with brownie.reverts("Unauthorized"):
        # Liquidator must equal msg.sender
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, False, "", {"from": accounts[3]}
        )

    with brownie.reverts("Unauthorized"):
        # Vault cannot liquidate
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, False, "", {"from": vault.address}
        )


def test_disable_deleverage(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )
    vault.setExchangeRate(0.85e18)
    (cr, _, _, _) = environment.notional.getVaultAccountCollateralRatio(accounts[1], vault)
    assert cr < 0.2e9

    # Only owner can set deleverage status
    with brownie.reverts("Ownable: caller is not the owner"):
        environment.notional.setVaultDeleverageStatus(vault.address, True, {"from": accounts[1]})

    environment.notional.setVaultDeleverageStatus(vault.address, True, {"from": accounts[0]})

    # Cannot deleverage
    with brownie.reverts():
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, False, "", {"from": accounts[2]}
        )

    environment.notional.setVaultDeleverageStatus(vault.address, False, {"from": accounts[0]})

    # Can deleverage
    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 25_000e18, False, "", {"from": accounts[2]}
    )


def test_deleverage_account_sufficient_collateral(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    with brownie.reverts("Sufficient Collateral"):
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, False, "", {"from": accounts[2]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_deleverage_account_over_max_liquidate_amount(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), minAccountBorrowSize=1_000
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 50_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.97e18)

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    balanceBefore = environment.token["DAI"].balanceOf(accounts[2])
    cTokenBalanceBefore = environment.cToken["DAI"].balanceOf(accounts[2])
    (
        _,
        _,
        maxLiquidateDebt,
        vaultSharesToLiquidator,
    ) = environment.notional.getVaultAccountCollateralRatio(accounts[1], vault)

    environment.notional.deleverageAccount(
        accounts[1],
        vault.address,
        accounts[2],
        maxLiquidateDebt * 1.2,
        False,
        "",
        {"from": accounts[2]},
    )

    balanceAfter = environment.token["DAI"].balanceOf(accounts[2])
    cTokenBalanceAfter = environment.cToken["DAI"].balanceOf(accounts[2])
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    assert pytest.approx(collateralRatioAfter, abs=5) == 0.4e9
    vaultSharesSold = vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"]
    # Shares sold is approx equal to amount deposited scaled by the exchange rate and multiplied by
    # the liquidation discount
    assert pytest.approx(vaultSharesSold, rel=1e-08) == (maxLiquidateDebt / 50 * 1.04 / 0.97)
    assert vaultSharesSold == vaultSharesToLiquidator
    assert vaultAccountBefore["maturity"] == vaultAccountAfter["maturity"]
    assert pytest.approx(vaultAccountAfter["fCash"], abs=5) == -(200_000e8 - maxLiquidateDebt / 50)

    # Liquidator deposit is cut down to account for max debt, but still has profit
    assert cTokenBalanceBefore - cTokenBalanceAfter == maxLiquidateDebt
    assert pytest.approx(balanceAfter - balanceBefore, rel=1e-8) == vaultSharesSold * 0.97 * 1e10

    assert (
        vaultStateBefore["totalVaultShares"] - vaultStateAfter["totalVaultShares"]
        == vaultSharesSold
    )

    # Accounts for lending at 0% interest
    environment.notional.setReserveCashBalance(
        2, environment.notional.getReserveBalance(2) + maxLiquidateDebt
    )
    vaultfCashOverrides = [
        {"currencyId": 2, "maturity": maturity, "fCash": -(maxLiquidateDebt / 50)}
    ]
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)


def test_cannot_deleverage_account_after_maturity(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.85e18)
    chain.mine(1, timestamp=maturity)

    with brownie.reverts():
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 100_000e18, False, "", {"from": accounts[2]}
        )


def test_deleverage_account_full(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 50_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.95e18)

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    cTokenBalanceBefore = environment.cToken["DAI"].balanceOf(accounts[2])
    balanceBefore = environment.token["DAI"].balanceOf(accounts[2])

    with brownie.reverts("Must Liquidate All Debt"):
        # The account is below the min borrow threshold at this point
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 9_000_000e8, False, "", {"from": accounts[2]}
        )

    # Liquidator is allowed to deleverage a small portion of the debt
    txn = environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 1000e8, False, "", {"from": accounts[2]}
    )
    assert txn.events["Transfer"][0]["amount"] == 1000e8

    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 10_200_000e8, False, "", {"from": accounts[2]}
    )

    cTokenBalanceAfter = environment.cToken["DAI"].balanceOf(accounts[2])
    balanceAfter = environment.token["DAI"].balanceOf(accounts[2])
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    assert collateralRatioBefore < collateralRatioAfter
    vaultSharesSold = vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"]
    # Shares sold is approx equal to amount deposited scaled by the exchange rate and multiplied by
    # the liquidation discount
    assert pytest.approx(vaultSharesSold, rel=1e-08) == (200_000e8 / 0.95 * 1.04)
    assert vaultAccountBefore["maturity"] == vaultAccountAfter["maturity"]
    assert vaultAccountAfter["fCash"] == 0

    # Liquidator deposit is cut down to account for max debt, still has profit
    assert cTokenBalanceBefore - cTokenBalanceAfter == 10_000_000e8
    assert pytest.approx((balanceAfter - balanceBefore), rel=1e-8) == vaultSharesSold * 0.95 * 1e10
    assert (
        vaultStateBefore["totalVaultShares"] - vaultStateAfter["totalVaultShares"]
        == vaultSharesSold
    )

    # Accounts for lending at 0% interest
    environment.notional.setReserveCashBalance(
        2, environment.notional.getReserveBalance(2) + 10_000_000e8
    )
    vaultfCashOverrides = [{"currencyId": 2, "maturity": maturity, "fCash": -200_000e8}]
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)


def test_cannot_deleverage_liquidator_matured_shares(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    # Set up the liquidator such that they have matured vault shares
    environment.notional.enterVault(
        accounts[2], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[2]}
    )

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False, {"from": accounts[0]})
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.95e18)

    with brownie.reverts("Vault Shares Mismatch"):
        # account[2] cannot liquidate this account because they have matured vault shares
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 25_000e18, True, "", {"from": accounts[2]}
        )


def test_deleverage_account_transfer_shares(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.95e18)

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[2])
    # In this case we have to deleverage the account down to zero
    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 5_000_000e8, True, "", {"from": accounts[2]}
    )
    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[2])

    liquidatorAccount = environment.notional.getVaultAccount(accounts[2], vault)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    assert balanceBefore - balanceAfter == 5_000_000e8
    assert collateralRatioBefore < collateralRatioAfter
    vaultSharesSold = vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"]
    # Shares sold is approx equal to amount deposited scaled by the exchange rate and multiplied by
    # the liquidation discount
    assert pytest.approx(vaultSharesSold, rel=1e-08) == (100_000e8 / 0.95 * 1.04)
    assert vaultAccountBefore["maturity"] == vaultAccountAfter["maturity"]
    assert vaultAccountAfter["fCash"] == 0

    assert liquidatorAccount["maturity"] == vaultAccountAfter["maturity"]
    assert liquidatorAccount["vaultShares"] == vaultSharesSold

    # Accounts for lending at 0% interest
    environment.notional.setReserveCashBalance(
        2, environment.notional.getReserveBalance(2) + 5_000_000e8
    )
    vaultfCashOverrides = [{"currencyId": 2, "maturity": maturity, "fCash": -100_000e8}]
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)


def test_deleverage_insolvent_account(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.80e18)

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[2])
    # In this case we have to deleverage the account down to zero
    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 5_000_000e8, True, "", {"from": accounts[2]}
    )
    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[2])

    liquidatorAccount = environment.notional.getVaultAccount(accounts[2], vault)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    assert balanceBefore - balanceAfter < 5_000_000e8
    assert collateralRatioAfter == -1e9
    # Shares sold is approx equal to amount deposited scaled by the exchange rate and multiplied by
    # the liquidation discount
    assert vaultAccountBefore["maturity"] == vaultAccountAfter["maturity"]
    assert vaultAccountAfter["fCash"] < 0
    assert pytest.approx(vaultAccountAfter["vaultShares"], abs=1) == 0

    assert liquidatorAccount["maturity"] == vaultAccountAfter["maturity"]
    assert (
        pytest.approx(liquidatorAccount["vaultShares"], abs=1) == vaultAccountBefore["vaultShares"]
    )

    # Accounts for lending at 0% interest
    environment.notional.setReserveCashBalance(
        2, environment.notional.getReserveBalance(2) + (balanceBefore - balanceAfter)
    )
    vaultfCashOverrides = [
        {"currencyId": 2, "maturity": maturity, "fCash": (-100_000e8 - vaultAccountAfter["fCash"])}
    ]
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)


def test_deleverage_account_with_asset_cash(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True), minAccountBorrowSize=1_000
        ),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 50_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
    )
    vault.setExchangeRate(0.97e18)

    # Put some asset cash on the vault @ 0.97e18
    vault.redeemStrategyTokensToCash(maturity, 25_000e8, "", {"from": accounts[0]})

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    balanceBefore = environment.token["DAI"].balanceOf(accounts[2])
    cTokenBalanceBefore = environment.cToken["DAI"].balanceOf(accounts[2])
    (
        _,
        _,
        maxLiquidateDebt,
        vaultSharesToLiquidator,
    ) = environment.notional.getVaultAccountCollateralRatio(accounts[1], vault)

    environment.notional.deleverageAccount(
        accounts[1],
        vault.address,
        accounts[2],
        maxLiquidateDebt * 1.2,
        False,
        "",
        {"from": accounts[2]},
    )

    balanceAfter = environment.token["DAI"].balanceOf(accounts[2])
    cTokenBalanceAfter = environment.cToken["DAI"].balanceOf(accounts[2])
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    assert pytest.approx(collateralRatioAfter, abs=5) == 0.4e9
    vaultSharesSold = vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"]
    # Shares sold is approx equal to amount deposited scaled by the exchange rate and multiplied by
    # the liquidation discount
    assert pytest.approx(vaultSharesSold, rel=1e-08) == (maxLiquidateDebt / 50 * 1.04 / 0.97)
    assert vaultSharesToLiquidator == vaultSharesSold
    assert vaultAccountBefore["maturity"] == vaultAccountAfter["maturity"]
    assert pytest.approx(vaultAccountAfter["fCash"], abs=5) == -(200_000e8 - maxLiquidateDebt / 50)

    # Liquidator deposit is cut down to account for max debt, but still has profit
    assert cTokenBalanceBefore - cTokenBalanceAfter == maxLiquidateDebt
    assert pytest.approx(balanceAfter - balanceBefore, rel=1e-8) == vaultSharesSold * 0.97 * 1e10

    assert (
        vaultStateBefore["totalVaultShares"] - vaultStateAfter["totalVaultShares"]
        == vaultSharesSold
    )

    # Accounts for lending at 0% interest
    environment.notional.setReserveCashBalance(
        2, environment.notional.getReserveBalance(2) + maxLiquidateDebt
    )
    vaultfCashOverrides = [
        {"currencyId": 2, "maturity": maturity, "fCash": -(maxLiquidateDebt / 50)}
    ]
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)

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

    check_system_invariants(environment, accounts, [vault])


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

    check_system_invariants(environment, accounts, [vault])


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

    check_system_invariants(environment, accounts, [vault])


def test_cannot_deleverage_account_after_maturity(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True))
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.85e18)
    maturity = environment.notional.getCurrentVaultMaturity(vault)

    chain.mine(1, timestamp=maturity)

    with brownie.reverts():
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
    assert vaultAccountBefore["fCash"] == vaultAccountAfter["fCash"]
    # 25_000e18 in asset cash terms
    assert vaultAccountAfter["escrowedAssetCash"] == 25_000e8 * 50

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
    )

    # Set up the liquidator such that they have matured vault shares
    environment.notional.enterVault(
        accounts[2], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[2]}
    )
    maturity = environment.notional.getCurrentVaultMaturity(vault)

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False, {"from": accounts[0]})

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
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
        get_vault_config(
            currencyId=2, flags=set_flags(0, ENABLED=True, TRANSFER_SHARES_ON_DELEVERAGE=True)
        ),
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.95e18)

    (collateralRatioBefore, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 25_000e18, True, "", {"from": accounts[2]}
    )

    liquidatorAccount = environment.notional.getVaultAccount(accounts[2], vault)
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
    assert vaultAccountBefore["fCash"] == vaultAccountAfter["fCash"]
    # 25_000e18 in asset cash terms
    assert vaultAccountAfter["escrowedAssetCash"] == 25_000e8 * 50
    assert vaultStateAfter["totalfCashRequiringSettlement"] == 0

    assert liquidatorAccount["maturity"] == vaultAccountAfter["maturity"]
    assert liquidatorAccount["vaultShares"] == vaultSharesSold

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_with_escrowed_asset_cash_insufficient_collateral(
    environment, vault, escrowed_account
):
    with brownie.reverts("Insufficient Collateral"):
        # Cannot immediately re-enter with escrowed asset cash
        environment.notional.enterVault(
            escrowed_account, vault.address, 0, True, 0, 0, "", {"from": escrowed_account}
        )


def test_enter_vault_with_escrowed_asset_cash_no_collateral(
    environment, vault, escrowed_account, accounts
):
    # Can re-enter when exchange rate realigns
    vault.setExchangeRate(1e18)
    environment.notional.enterVault(
        escrowed_account, vault.address, 0, True, 0, 0, "", {"from": escrowed_account}
    )

    vaultStateAfter = environment.notional.getCurrentVaultState(vault)
    vaultAccountAfter = environment.notional.getVaultAccount(escrowed_account, vault)
    (collateralRatioAfter, minRatio) = environment.notional.getVaultAccountCollateralRatio(
        escrowed_account, vault
    )

    assert collateralRatioAfter > minRatio
    assert vaultAccountAfter["escrowedAssetCash"] == 0
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateAfter["totalfCash"] == -100_000e8
    assert vaultStateAfter["totalfCashRequiringSettlement"] == -100_000e8

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_with_escrowed_asset_cash(environment, vault, escrowed_account, accounts):
    vaultAccountBefore = environment.notional.getVaultAccount(escrowed_account, vault)
    vaultStateBefore = environment.notional.getCurrentVaultState(vault)

    # Re-enter vault using escrowed asset cash
    environment.notional.enterVault(
        escrowed_account, vault.address, 10_000e18, True, 0, 0, "", {"from": escrowed_account}
    )

    vaultAccountAfter = environment.notional.getVaultAccount(escrowed_account, vault)
    vaultStateAfter = environment.notional.getCurrentVaultState(vault)
    (collateralRatioAfter, minRatio) = environment.notional.getVaultAccountCollateralRatio(
        escrowed_account, vault
    )

    assert collateralRatioAfter > minRatio
    assert vaultAccountBefore["maturity"] == vaultAccountAfter["maturity"]
    assert vaultAccountAfter["escrowedAssetCash"] == 0
    vaultSharesGained = vaultAccountAfter["vaultShares"] - vaultAccountBefore["vaultShares"]

    # Asset cash is used to re-enter the vault
    assert pytest.approx(vaultSharesGained, rel=1e-9) == (
        (vaultAccountBefore["escrowedAssetCash"] / 50 + 10_000e8) / 0.95
    )
    assert (
        vaultStateAfter["totalVaultShares"] - vaultStateBefore["totalVaultShares"]
        == vaultSharesGained
    )

    # fCash requiring settlement is re-instanted
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateAfter["totalfCash"] == -100_000e8
    assert vaultStateAfter["totalfCashRequiringSettlement"] == -100_000e8

    check_system_invariants(environment, accounts, [vault])


def test_exit_vault_with_escrowed_asset_cash_insufficient_collateral(
    environment, vault, escrowed_account
):
    with brownie.reverts("Insufficient Collateral"):
        # Attempting to lend a small amount to exit against a large amount of escrowed asset cash
        # will put the account under water
        environment.notional.exitVault(
            escrowed_account, vault.address, 0, 100e8, 0, True, "", {"from": escrowed_account}
        )


def test_exit_vault_with_escrowed_asset_cash(environment, vault, escrowed_account, accounts):
    vaultAccountBefore = environment.notional.getVaultAccount(escrowed_account, vault)
    balanceBefore = environment.cToken["DAI"].balanceOf(escrowed_account)

    (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 50_000e8, environment.notional.getCurrentVaultMaturity(vault), 0, chain.time()
    )

    # This should clear the escrowed asset cash balance
    environment.notional.exitVault(
        escrowed_account, vault.address, 0, 50_000e8, 0, False, "", {"from": escrowed_account}
    )

    balanceAfter = environment.cToken["DAI"].balanceOf(escrowed_account)
    vaultAccountAfter = environment.notional.getVaultAccount(escrowed_account, vault)
    vaultStateAfter = environment.notional.getCurrentVaultState(vault)

    # Escrowed asset cash should be net off against the cost to lend
    assert (
        pytest.approx(balanceBefore - balanceAfter, rel=1e-8)
        == amountAsset - vaultAccountBefore["escrowedAssetCash"]
    )
    assert vaultAccountBefore["vaultShares"] == vaultAccountAfter["vaultShares"]
    assert vaultAccountBefore["maturity"] == vaultAccountAfter["maturity"]
    assert vaultAccountAfter["fCash"] == -50_000e8
    assert vaultAccountAfter["escrowedAssetCash"] == 0

    # fCash requiring settlement is re-instanted
    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateAfter["totalfCash"] == -50_000e8
    assert vaultStateAfter["totalfCashRequiringSettlement"] == -50_000e8

    check_system_invariants(environment, accounts, [vault])


def test_roll_vault_with_escrowed_asset_cash(environment, vault, escrowed_account, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1),
            minAccountBorrowSize=100,
            feeRate5BPS=0,
        ),
    )

    vaultAccountBefore = environment.notional.getVaultAccount(escrowed_account, vault)
    maturity = environment.notional.getCurrentVaultMaturity(vault)

    (lendAmountUnderlying, amountLendAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )

    (
        borrowAmountUnderlying,
        amountBorrowAsset,
        _,
        _,
    ) = environment.notional.getPrincipalFromfCashBorrow(
        2, 50_000e8, maturity + SECONDS_IN_QUARTER, 0, chain.time()
    )
    vault.setSettlement(True)

    environment.notional.rollVaultPosition(
        escrowed_account,
        vault.address,
        50_000e8,
        50_000e8,
        (0, 0, "", ""),
        {"from": escrowed_account},
    )

    vaultAccountAfter = environment.notional.getVaultAccount(escrowed_account, vault)
    vaultStateAfter = environment.notional.getCurrentVaultState(vault)

    assert vaultAccountAfter["maturity"] == maturity + SECONDS_IN_QUARTER
    assert vaultAccountAfter["fCash"] == -50_000e8
    assert vaultAccountAfter["escrowedAssetCash"] == 0

    assert vaultStateAfter["accountsRequiringSettlement"] == 0
    assert vaultStateAfter["totalVaultShares"] == 0
    assert vaultStateAfter["totalStrategyTokens"] == 0
    assert vaultStateAfter["totalfCash"] == 0
    assert vaultStateAfter["totalfCashRequiringSettlement"] == 0

    rollBorrowLendCostInternal = (
        lendAmountUnderlying - borrowAmountUnderlying
    ) / 1e10 - vaultAccountBefore["escrowedAssetCash"] / 50
    netSharesRedeemed = vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"]
    # This is approx equal because there is no vault fee assessed
    assert pytest.approx(rollBorrowLendCostInternal, rel=1e-6) == netSharesRedeemed * 0.95

    check_system_invariants(environment, accounts, [vault])

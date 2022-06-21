import brownie
import pytest
from brownie.network.state import Chain
from fixtures import *
from tests.helpers import initialize_environment
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_only_vault_exit(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ONLY_VAULT_EXIT=1), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

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

    with brownie.reverts("Unauthorized"):
        # User account cannot directly exit vault
        environment.notional.exitVault(
            accounts[1], vault.address, 50_000e8, 10_000e8, 0, False, "", {"from": accounts[1]}
        )

    # Execution from vault is allowed
    environment.notional.exitVault(
        accounts[1], vault.address, 50_000e8, 100_000e8, 0, False, "", {"from": vault.address}
    )

    check_system_invariants(environment, accounts, [vault])


def test_exit_vault_min_borrow(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

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

    with brownie.reverts("Min Borrow"):
        # User account cannot directly exit vault
        environment.notional.exitVault(
            accounts[1], vault.address, 50_000e8, 10_000e8, 0, False, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_exit_vault_transfer_from_account(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

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

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[1])

    (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )

    # If vault share value < exit cost then we need to transfer from the account
    environment.notional.exitVault(
        accounts[1], vault.address, 50_000e8, 100_000e8, 0, False, "", {"from": accounts[1]}
    )

    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-8) == amountAsset - 50_000e8 * 50
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == 0
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 50_000e8

    assert vaultState["totalfCash"] == 0
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    check_system_invariants(environment, accounts, [vault])


def test_exit_vault_transfer_to_account(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        200_000e18,
        maturity,
        True,
        100_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[1])

    (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )

    # If vault share value > exit cost then we transfer to the account
    environment.notional.exitVault(
        accounts[1], vault.address, 150_000e8, 100_000e8, 0, False, "", {"from": accounts[1]}
    )

    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert pytest.approx(balanceAfter - balanceBefore, rel=1e-8) == 150_000e8 * 50 - amountAsset
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == 0
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 150_000e8

    assert vaultState["totalfCash"] == 0
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    check_system_invariants(environment, accounts, [vault])


def test_exit_vault_insufficient_collateral(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
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

    # Cannot exit a vault below min collateral ratio
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.exitVault(
            accounts[1], vault.address, 10_000e8, 0, 0, False, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_exit_vault_lending_fails(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
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

    # Reduce liquidity in DAI
    environment.notional.nTokenRedeem(accounts[0], 2, 49000000e8, True, True, {"from": accounts[0]})
    (amountAsset, _, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )
    assert amountAsset == 0

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[1])

    # NOTE: this adds 5_000_000e8 cDAI into the contract but there is no offsetting fCash position
    # recorded, similarly, the fCash erased is not recorded anywhere either
    environment.notional.exitVault(
        accounts[1], vault.address, 10_000e8, 100_000e8, 0, False, "", {"from": accounts[1]}
    )

    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert balanceBefore - balanceAfter == 90_000e8 * 50
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == 0
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 10_000e8

    assert vaultState["totalfCash"] == 0
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    vaultfCashOverrides = [{"currencyId": 2, "maturity": maturity, "fCash": -100_000e8}]
    environment.notional.setReserveCashBalance(
        2, environment.notional.getReserveBalance(2) + 5_000_000e8
    )
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)


def test_exit_vault_during_settlement(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
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

    environment.notional.redeemStrategyTokensToCash(maturity, 120_000e8, "", {"from": vault})

    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )
    environment.notional.exitVault(
        accounts[1], vault.address, 100_000e8, 100_000e8, 0, False, "", {"from": accounts[1]}
    )

    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)

    assert vaultAccountAfter["fCash"] == 0
    assert vaultAccountBefore["vaultShares"] - 100_000e8 == vaultAccountAfter["vaultShares"]
    # Vault account keeps its current maturity since it still has vault shares
    assert vaultAccountAfter["maturity"] == maturity

    assert vaultStateAfter["totalfCash"] == 0
    assert vaultStateAfter["totalVaultShares"] == vaultStateBefore["totalVaultShares"] - 100_000e8
    tokensRedeemed = (
        vaultStateBefore["totalStrategyTokens"] - vaultStateAfter["totalStrategyTokens"]
    )

    # Asset cash change nets off with the debt repayment and the amount transferred to the account
    assert pytest.approx(vaultStateAfter["totalAssetCash"], rel=1e-8) == (
        vaultStateBefore["totalAssetCash"]
        - amountAsset
        - (balanceAfter - balanceBefore - tokensRedeemed * 50)
    )

    # Check that we can still settle this vault even if fCash == 0
    chain.mine(1, timestamp=maturity)
    environment.notional.settleVault(vault, maturity, {"from": accounts[1]})
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    assert vaultStateAfter["isSettled"]

    check_system_invariants(environment, accounts, [vault])


def test_exit_vault_after_settlement(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(2)[0][1]

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

    environment.notional.redeemStrategyTokensToCash(maturity, 100_000e8, "", {"from": vault})

    chain.mine(1, timestamp=maturity)
    environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    environment.notional.exitVault(
        accounts[1],
        vault.address,
        vaultAccountBefore["vaultShares"],
        0,
        0,
        False,
        "",
        {"from": accounts[1]},
    )

    balanceAfter = environment.cToken["DAI"].balanceOf(accounts[1])
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)

    assert balanceAfter - balanceBefore == vaultStateBefore["totalStrategyTokens"] * 50
    assert vaultStateAfter["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"]
    assert vaultStateAfter["totalVaultShares"] == vaultStateAfter["totalVaultShares"]
    assert vaultAccountAfter["vaultShares"] == 0
    assert vaultAccountAfter["fCash"] == 0
    assert vaultAccountAfter["maturity"] == 0

    check_system_invariants(environment, accounts, [vault])

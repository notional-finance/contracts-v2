import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from fixtures import *
from tests.helpers import initialize_environment
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_cannot_exit_within_min_blocks(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    with brownie.reverts("Min Entry Blocks"):
        environment.notional.exitVault(
            accounts[1],
            vault.address,
            accounts[1],
            50_000e8,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )


def test_cannot_exit_vault_above_max_collateral(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True),
            maxBorrowMarketIndex=2,
            maxDeleverageCollateralRatioBPS=2500,
            maxRequiredAccountCollateralRatio=3000,
        ),
        500_000e8,
    )
    maturity = environment.notional.getActiveMarkets(2)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 50_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
    )

    chain.mine(5)
    with brownie.reverts("Above Max Collateral"):
        # Approx 250_000 vault shares w/ 200_000 borrow, reducing borrow
        # to 100_000 will revert (2.25x leverage < 3.3x required)
        environment.notional.exitVault(
            accounts[1], vault.address, accounts[1], 0, 100_000e8, 0, "", {"from": accounts[1]}
        )

    # Can reduce a smaller size
    environment.notional.exitVault(
        accounts[1], vault.address, accounts[1], 0, 10_000e8, 0, "", {"from": accounts[1]}
    )

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.exitVault(
            accounts[1],
            vault.address,
            accounts[1],
            vaultAccountBefore["vaultShares"],
            10_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    # Can reduce to sell all vault shares to zero for a full exit
    environment.notional.exitVault(
        accounts[1],
        vault.address,
        accounts[1],
        vaultAccountBefore["vaultShares"],
        190_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault).dict()
    assert vaultAccountAfter["maturity"] == 0
    assert vaultAccountAfter["vaultShares"] == 0
    assert vaultAccountAfter["fCash"] == 0

    check_system_invariants(environment, accounts, [vault])


def test_only_vault_exit(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ONLY_VAULT_EXIT=1), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 150_000e18, maturity, 150_000e8, 0, "", {"from": accounts[1]}
    )

    with brownie.reverts("Unauthorized"):
        # User account cannot directly exit vault
        environment.notional.exitVault(
            accounts[1],
            vault.address,
            accounts[1],
            50_000e8,
            10_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    chain.mine(5)
    # Execution from vault is allowed
    environment.notional.exitVault(
        accounts[1], vault.address, accounts[1], 50_000e8, 50_000e8, 0, "", {"from": vault.address}
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
        accounts[1], vault.address, 100_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    chain.mine(5)
    with brownie.reverts("Min Borrow"):
        # User account cannot directly exit vault
        environment.notional.exitVault(
            accounts[1],
            vault.address,
            accounts[1],
            50_000e8,
            10_000e8,
            0,
            "",
            {"from": accounts[1]},
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
        accounts[1], vault.address, 100_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
    )

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.token["DAI"].balanceOf(accounts[1])

    (amountUnderlying, _, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )

    # If vault share value < exit cost then we need to transfer from the account
    chain.mine(5)
    environment.notional.exitVault(
        accounts[1], vault.address, accounts[1], 50_000e8, 100_000e8, 0, "", {"from": accounts[1]}
    )

    balanceAfter = environment.token["DAI"].balanceOf(accounts[1])
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-8) == amountUnderlying - 50_000e18
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == -100_000e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 50_000e8

    assert vaultState["totalfCash"] == -100_000e8
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    check_system_invariants(environment, accounts, [vault])


def test_exit_vault_transfer_from_account_sell_zero_shares(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
    )

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.token["DAI"].balanceOf(accounts[1])

    (amountUnderlying, _, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )

    # If vault share value < exit cost then we need to transfer from the account
    chain.mine(5)
    environment.notional.exitVault(
        accounts[1], vault.address, accounts[1], 0, 100_000e8, 0, "", {"from": accounts[1]}
    )

    balanceAfter = environment.token["DAI"].balanceOf(accounts[1])
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-8) == amountUnderlying
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == -100_000e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"]

    assert vaultState["totalfCash"] == -100_000e8
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    check_system_invariants(environment, accounts, [vault])


@given(useReceiver=strategy("bool"))
def test_exit_vault_transfer_to_account(environment, vault, accounts, useReceiver):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    receiver = accounts[2] if useReceiver else accounts[1]

    environment.notional.enterVault(
        accounts[1], vault.address, 200_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
    )

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.token["DAI"].balanceOf(receiver)

    (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )

    # If vault share value > exit cost then we transfer to the account
    chain.mine(5)
    expectedProfit = environment.notional.exitVault.call(
        accounts[1], vault.address, receiver, 150_000e8, 100_000e8, 0, "", {"from": accounts[1]}
    )
    environment.notional.exitVault(
        accounts[1], vault.address, receiver, 150_000e8, 100_000e8, 0, "", {"from": accounts[1]}
    )

    balanceAfter = environment.token["DAI"].balanceOf(receiver)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert pytest.approx(balanceAfter - balanceBefore, rel=1e-8) == 150_000e18 - amountUnderlying
    assert pytest.approx(balanceAfter - balanceBefore, abs=1.5e-8) == expectedProfit
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == -100_000e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 150_000e8

    assert vaultState["totalfCash"] == -100_000e8
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
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    # Cannot exit a vault below min collateral ratio
    chain.mine(5)
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.exitVault(
            accounts[1], vault.address, accounts[1], 10_000e8, 0, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


@given(useReceiver=strategy("bool"))
def test_exit_vault_lending_fails(environment, accounts, vault, useReceiver):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    receiver = accounts[2] if useReceiver else accounts[1]

    environment.notional.enterVault(
        accounts[1], vault.address, 50_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
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
    balanceBeforeReceiver = environment.token["DAI"].balanceOf(receiver)
    balanceBefore = environment.token["DAI"].balanceOf(accounts[1])

    # NOTE: this adds 5_000_000e8 cDAI into the contract but there is no offsetting fCash position
    # recorded, similarly, the fCash erased is not recorded anywhere either
    chain.mine(5)
    environment.notional.exitVault(
        accounts[1], vault.address, receiver, 10_000e8, 100_000e8, 0, "", {"from": accounts[1]}
    )

    balanceAfter = environment.token["DAI"].balanceOf(accounts[1])
    balanceAfterReceiver = environment.token["DAI"].balanceOf(receiver)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert balanceBefore - balanceAfter == Wei(90_000e18) + Wei(1e10)
    if useReceiver:
        assert balanceBeforeReceiver == balanceAfterReceiver
    assert collateralRatioBefore < collateralRatioAfter

    assert vaultAccount["fCash"] == -100_000e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 10_000e8

    assert vaultState["totalfCash"] == -100_000e8
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    vaultfCashOverrides = [{"currencyId": 2, "maturity": maturity, "fCash": -100_000e8}]
    environment.notional.setReserveCashBalance(
        2, environment.notional.getReserveBalance(2) + 5_000_000e8
    )
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)


@given(useReceiver=strategy("bool"))
def test_exit_vault_during_settlement(environment, vault, accounts, useReceiver):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    receiver = accounts[2] if useReceiver else accounts[1]

    environment.notional.enterVault(
        accounts[1], vault.address, 50_000e18, maturity, 200_000e8, 0, "", {"from": accounts[1]}
    )

    vault.redeemStrategyTokensToCash(maturity, 120_000e8, "", {"from": accounts[0]})

    balanceBefore = environment.token["DAI"].balanceOf(receiver)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )
    chain.mine(5)
    environment.notional.exitVault(
        accounts[1], vault.address, receiver, 100_000e8, 100_000e8, 0, "", {"from": accounts[1]}
    )

    balanceAfter = environment.token["DAI"].balanceOf(receiver)
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)

    assert vaultAccountAfter["fCash"] == -100_000e8
    assert vaultAccountBefore["vaultShares"] - 100_000e8 == vaultAccountAfter["vaultShares"]
    # Vault account keeps its current maturity since it still has vault shares
    assert vaultAccountAfter["maturity"] == maturity

    assert vaultStateAfter["totalfCash"] == -100_000e8
    assert vaultStateAfter["totalVaultShares"] == vaultStateBefore["totalVaultShares"] - 100_000e8
    tokensRedeemed = (
        vaultStateBefore["totalStrategyTokens"] - vaultStateAfter["totalStrategyTokens"]
    )

    # Asset cash change nets off with the debt repayment and the amount transferred to the account
    assert pytest.approx(vaultStateAfter["totalAssetCash"], rel=1e-8) == (
        vaultStateBefore["totalAssetCash"]
        - amountAsset
        - (((balanceAfter - balanceBefore) * 50) / 1e10 - tokensRedeemed * 50)
    )

    # Settle out the remaining debt in the vault
    vault.redeemStrategyTokensToCash(maturity, 30_000e8, "", {"from": accounts[0]})

    # Check that we can still settle this vault even if fCash == 0
    chain.mine(1, timestamp=maturity)
    environment.notional.settleVault(vault, maturity, {"from": accounts[1]})
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    assert vaultStateAfter["isSettled"]

    check_system_invariants(environment, accounts, [vault])


@given(useReceiver=strategy("bool"))
def test_exit_vault_after_settlement(environment, vault, accounts, useReceiver):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    receiver = accounts[2] if useReceiver else accounts[1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.redeemStrategyTokensToCash(maturity, 100_000e8, "", {"from": accounts[0]})

    chain.mine(1, timestamp=maturity)
    environment.notional.settleVault(vault, maturity, {"from": accounts[1]})

    balanceBefore = environment.token["DAI"].balanceOf(receiver)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    chain.mine(5)
    environment.notional.exitVault(
        accounts[1],
        vault.address,
        receiver,
        vaultAccountBefore["vaultShares"],
        0,
        0,
        "",
        {"from": accounts[1]},
    )

    balanceAfter = environment.token["DAI"].balanceOf(receiver)
    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)

    assert (balanceAfter - balanceBefore) / 1e10 == vaultStateBefore["totalStrategyTokens"]
    assert vaultStateAfter["totalStrategyTokens"] == vaultStateAfter["totalStrategyTokens"]
    assert vaultStateAfter["totalVaultShares"] == vaultStateAfter["totalVaultShares"]
    assert vaultAccountAfter["vaultShares"] == 0
    assert vaultAccountAfter["fCash"] == 0
    assert vaultAccountAfter["maturity"] == 0

    check_system_invariants(environment, accounts, [vault])


# def test_cannot_exit_vault_insolvent()

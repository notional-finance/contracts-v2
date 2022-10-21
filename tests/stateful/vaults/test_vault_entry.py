import brownie
import pytest
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_only_vault_entry(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ONLY_VAULT_ENTRY=1), currencyId=2),
        100_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts("Unauthorized"):
        # User account cannot directly enter vault
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    # Execution from vault is allowed
    environment.notional.enterVault(
        accounts[1], vault.address, 100_000e18, maturity, 100_000e8, 0, "", {"from": vault.address}
    )

    check_system_invariants(environment, accounts, [vault])


def test_no_system_level_accounts(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts():
        # No Zero Address
        environment.notional.enterVault(
            HexString(0, "bytes20"),
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )
        # No Notional Address
        environment.notional.enterVault(
            environment.notional.address,
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )
        # No nToken Address
        environment.notional.enterVault(
            environment.nToken["DAI"].address,
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )
        environment.notional.enterVault(
            environment.nToken["ETH"].address,
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )
        environment.notional.enterVault(
            vault.address,
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": vault.address},
        )


def test_enter_vault_past_maturity(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)), 100_000e8
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    with brownie.reverts("Cannot Enter"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity - SECONDS_IN_QUARTER,
            100_001e8,
            0,
            "",
            {"from": accounts[1]},
        )

    with brownie.reverts("Cannot Enter"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity - SECONDS_IN_QUARTER,
            0,
            0,
            "",
            {"from": accounts[1]},
        )


def test_cannot_enter_vault_with_less_than_required(environment, vault, accounts):
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

    with brownie.reverts("Above Max Collateral"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            1_000_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )


def test_enter_vault_past_max_markets(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True), maxBorrowMarketIndex=1),
        500_000e8,
    )

    maturity = environment.notional.getActiveMarkets(1)[1][1]
    with brownie.reverts("Invalid Maturity"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    # Cannot enter invalid maturity with deposit
    with brownie.reverts("Invalid Maturity"):
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, maturity, 0, 0, "", {"from": accounts[1]}
        )


def test_enter_vault_idiosyncratic(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)), 100_000e8
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts("Invalid Maturity"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity + SECONDS_IN_QUARTER / 3,
            100_001e8,
            0,
            "",
            {"from": accounts[1]},
        )

    # cannot enter an invalid maturity with just a deposit
    with brownie.reverts("Invalid Maturity"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity + SECONDS_IN_QUARTER / 3,
            0,
            0,
            "",
            {"from": accounts[1]},
        )


def test_enter_vault_over_maximum_capacity(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)), 100_000e8
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts("Max Capacity"):
        # User account borrowing over max vault size
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            100_001e8,
            0,
            "",
            {"from": accounts[1]},
        )

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_under_minimum_size(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts("Min Borrow"):
        # User account borrowing under minimum size
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, maturity, 99_000e8, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_borrowing_failure(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts("Trade failed, slippage"):
        # Fails on borrow slippage
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            100_000e8,
            0.01e9,
            "",
            {"from": accounts[1]},
        )

    with brownie.reverts("Borrow failed"):
        # Fails on liquidity
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            maturity,
            10_000_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_insufficient_deposit(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts("Insufficient Collateral"):
        environment.notional.enterVault(
            accounts[1], vault.address, 0, maturity, 100_000e8, 0, "", {"from": accounts[1]}
        )

    with brownie.reverts("Insufficient Collateral"):
        environment.notional.enterVault(
            accounts[1], vault.address, 10_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_with_dai(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    txn = environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )
    assert txn.events["VaultEnterMaturity"]
    assert txn.events["VaultEnterMaturity"]["underlyingTokensDeposited"] == 25_000e18
    assert txn.events["VaultEnterMaturity"]["cashTransferToVault"] > 100_000e8 * 49
    assert txn.events["VaultEnterMaturity"]["cashTransferToVault"] < 100_000e8 * 50

    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatio, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert 0.22e9 < collateralRatio and collateralRatio < 0.25e9
    assert vaultAccount["fCash"] == -100_000e8
    assert vaultAccount["maturity"] == maturity

    assert vaultState["totalfCash"] == -100_000e8
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    totalValue = vault.convertStrategyToUnderlying(
        accounts[1], vaultState["totalStrategyTokens"], maturity
    )
    assert 122_000e18 < totalValue and totalValue < 125_000e18

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_fails_if_has_asset_cash(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.redeemStrategyTokensToCash(maturity, 5_000e8, "", {"from": accounts[0]})

    with brownie.reverts():
        # An attempt to enter again will fail if the vault is holding asset cash
        environment.notional.enterVault(
            accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_with_matured_position(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    (collateralRatioBefore, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    # Settle the vault
    vault.redeemStrategyTokensToCash(maturity, 100_000e8, "", {"from": accounts[0]})
    chain.mine(1, timestamp=maturity)
    environment.notional.settleVault(vault, maturity, {"from": accounts[1]})
    environment.notional.initializeMarkets(2, False, {"from": accounts[1]})
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    # Cannot establish a new vault position without borrowing even after settlement
    with brownie.reverts("Above Max Collateral"):
        environment.notional.enterVault(
            accounts[1], vault.address, 10_000e18, maturity, 0, 0, "", {"from": accounts[1]}
        )

    environment.notional.enterVault(
        accounts[1], vault.address, 0, maturity, 105_000e8, 0, "", {"from": accounts[1]}
    )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    vaultStateNew = environment.notional.getVaultState(vault, vaultAccountAfter["maturity"])
    (collateralRatioAfter, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )

    assert collateralRatioAfter < collateralRatioBefore
    assert vaultStateNew["totalVaultShares"] == vaultAccountAfter["vaultShares"]
    assert vaultStateNew["totalStrategyTokens"] == vaultAccountAfter["vaultShares"]
    assert vaultAccountBefore["vaultShares"] < vaultAccountAfter["vaultShares"]
    assert vaultAccountAfter["fCash"] == -105_000e8
    assert vaultAccountAfter["maturity"] == maturity

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_return_values(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    expectedStrategyTokens = environment.notional.enterVault.call(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )
    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    assert pytest.approx(expectedStrategyTokens, abs=1e5) == vaultAccount["vaultShares"]

    # Settle the vault
    vault.redeemStrategyTokensToCash(maturity, 100_000e8, "", {"from": accounts[0]})
    chain.mine(1, timestamp=maturity)
    environment.notional.settleVault(vault, maturity, {"from": accounts[1]})
    environment.notional.initializeMarkets(2, False, {"from": accounts[1]})
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    expectedStrategyTokens = environment.notional.enterVault.call(
        accounts[1], vault.address, 0, maturity, 105_000e8, 0, "", {"from": accounts[1]}
    )
    environment.notional.enterVault(
        accounts[1], vault.address, 0, maturity, 105_000e8, 0, "", {"from": accounts[1]}
    )
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    assert expectedStrategyTokens == vaultAccount["vaultShares"]

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_with_matured_position_unable_to_settle(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.redeemStrategyTokensToCash(maturity, 100_000e8, "", {"from": accounts[0]})
    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False, {"from": accounts[1]})

    # At this point the vault has not settled so we will revert
    with brownie.reverts("Not Settled"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            25_000e18,
            maturity + SECONDS_IN_QUARTER,
            100_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    # Run this for the invariants to succeed
    environment.notional.settleVault(vault, maturity, {"from": accounts[1]})
    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_with_usdc(environment, accounts, SimpleStrategyVault):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", environment.notional.address, 3, {"from": accounts[0]}
    )
    vault.setExchangeRate(1e12)

    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=3, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e6, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatio, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert 0.22e9 < collateralRatio and collateralRatio < 0.25e9
    assert vaultAccount["fCash"] == -100_000e8
    assert vaultAccount["maturity"] == maturity

    assert vaultState["totalfCash"] == -100_000e8
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    totalValue = vault.convertStrategyToUnderlying(
        accounts[1], vaultState["totalStrategyTokens"], maturity
    )
    assert 122_000e6 < totalValue and totalValue < 125_000e6

    check_system_invariants(environment, accounts, [vault])


def test_enter_vault_with_eth(environment, accounts, SimpleStrategyVault):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", environment.notional.address, 1, {"from": accounts[0]}
    )
    vault.setExchangeRate(1e18)

    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=1, flags=set_flags(0, ENABLED=True), minAccountBorrowSize=100),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25e18,
        maturity,
        100e8,
        0,
        "",
        {"from": accounts[1], "value": 25e18},
    )

    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    (collateralRatio, _, _, _) = environment.notional.getVaultAccountCollateralRatio(
        accounts[1], vault
    )
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert 0.22e9 < collateralRatio and collateralRatio < 0.25e9
    assert vaultAccount["fCash"] == -100e8
    assert vaultAccount["maturity"] == maturity

    assert vaultState["totalfCash"] == -100e8
    assert vaultState["totalAssetCash"] == 0
    assert vaultState["totalStrategyTokens"] == vaultAccount["vaultShares"]
    assert vaultState["totalStrategyTokens"] == vaultState["totalVaultShares"]

    totalValue = vault.convertStrategyToUnderlying(
        accounts[1], vaultState["totalStrategyTokens"], maturity
    )
    assert 122e18 < totalValue and totalValue < 125e18

    check_system_invariants(environment, accounts, [vault])

import brownie
import pytest
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from brownie.test import given, strategy
from fixtures import *
from tests.constants import PRIME_CASH_VAULT_MATURITY, SECONDS_IN_QUARTER
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
    with brownie.reverts():
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

    with brownie.reverts():
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


@given(isPrime=strategy("bool"))
def test_cannot_enter_vault_with_less_than_required(environment, vault, accounts, isPrime):
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
    maturity = (
        PRIME_CASH_VAULT_MATURITY if isPrime else environment.notional.getActiveMarkets(2)[0][1]
    )

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
    with brownie.reverts(dev_revert_msg="dev: invalid maturity"):
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
    with brownie.reverts(dev_revert_msg="dev: invalid maturity"):
        environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, maturity, 0, 0, "", {"from": accounts[1]}
        )


def test_enter_vault_idiosyncratic(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)), 100_000e8
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts(dev_revert_msg="dev: invalid maturity"):
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
    with brownie.reverts(dev_revert_msg="dev: invalid maturity"):
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


@given(isPrime=strategy("bool"))
def test_enter_vault_over_maximum_capacity(environment, vault, accounts, isPrime):
    environment.notional.updateVault(
        vault.address, get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)), 100_000e8
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY if isPrime else environment.notional.getActiveMarkets(2)[0][1]
    )

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


@given(isPrime=strategy("bool"))
def test_enter_vault_under_minimum_size(environment, vault, accounts, isPrime):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY if isPrime else environment.notional.getActiveMarkets(2)[0][1]
    )

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

    with brownie.reverts(""):
        # TODO: fails on insufficient prime cash to withdraw
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            100_000e18,
            PRIME_CASH_VAULT_MATURITY,
            10_000_000e8,
            0,
            "",
            {"from": accounts[1]},
        )

    check_system_invariants(environment, accounts, [vault])


@given(isPrime=strategy("bool"))
def test_enter_vault_insufficient_deposit(environment, vault, accounts, isPrime):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY if isPrime else environment.notional.getActiveMarkets(2)[0][1]
    )

    with brownie.reverts("Insufficient Collateral"):
        environment.notional.enterVault(
            accounts[1], vault.address, 0, maturity, 100_000e8, 0, "", {"from": accounts[1]}
        )

    with brownie.reverts("Insufficient Collateral"):
        environment.notional.enterVault(
            accounts[1], vault.address, 10_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


@given(currencyId=strategy("uint", min_value=1, max_value=3), isPrime=strategy("bool"))
def test_enter_vault(environment, SimpleStrategyVault, accounts, currencyId, isPrime):
    decimals = environment.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", environment.notional.address, currencyId, {"from": accounts[0]}
    )
    vault.setExchangeRate(1e18)
    # Set a multiple because ETH liquidity is lower in the test environment
    multiple = 1 if currencyId == 1 else 1_000

    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=currencyId,
            flags=set_flags(0, ENABLED=True),
            minAccountBorrowSize=100 * multiple,
        ),
        100_000_000e8,
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY
        if isPrime
        else environment.notional.getActiveMarkets(currencyId)[0][1]
    )

    txn = environment.notional.enterVault(
        accounts[1],
        vault.address,
        25 * multiple * decimals,
        maturity,
        100 * multiple * 1e8,
        0,
        "",
        {"from": accounts[1], "value": 25 * multiple * decimals if currencyId == 1 else 0},
    )

    # assert txn.events["VaultEnterMaturity"]
    # assert txn.events["VaultEnterMaturity"]["underlyingTokensDeposited"] == 25 * multiple * decimals
    # assert txn.events["VaultEnterMaturity"]["cashTransferToVault"] > 97 * multiple * 1e8
    # if isPrime:
    #     assert "VaultFeeAccrued" not in txn.events
    #     assert environment.approxInternal(
    #         environment.symbol[currencyId],
    #         txn.events["VaultEnterMaturity"]["cashTransferToVault"],
    #         100 * multiple * 1e8,
    #     )
    # else:
    #     assert "VaultFeeAccrued" in txn.events
    #     assert (
    #         txn.events["VaultEnterMaturity"]["cashTransferToVault"]
    #         < 100 * multiple * 1e8 * environment.primeCashScalars[environment.symbol[currencyId]]
    #     )

    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    (health, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert 0.21e9 < health["collateralRatio"] and health["collateralRatio"] < 0.26e9
    assert pytest.approx(vaultAccount["accountDebtUnderlying"], abs=1) == -100 * multiple * 1e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["lastUpdateBlockTime"] == txn.timestamp

    assert pytest.approx(vaultState["totalDebtUnderlying"], abs=1) == -100 * multiple * 1e8

    totalValue = vault.convertStrategyToUnderlying(
        accounts[1], vaultState["totalVaultShares"], maturity
    )

    if isPrime:
        assert pytest.approx(totalValue, rel=1e-12, abs=100) == 125 * multiple * decimals
    else:
        assert 121 * multiple * decimals < totalValue and totalValue < 125_000 * multiple * decimals

    check_system_invariants(environment, accounts, [vault])


@given(currencyId=strategy("uint", min_value=1, max_value=3), isPrime=strategy("bool"))
def test_can_increase_vault_position(
    environment, accounts, SimpleStrategyVault, currencyId, isPrime
):
    decimals = environment.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", environment.notional.address, currencyId, {"from": accounts[0]}
    )
    vault.setExchangeRate(1e18)
    # Set a multiple because ETH liquidity is lower in the test environment
    multiple = 1 if currencyId == 1 else 1_000

    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=currencyId,
            flags=set_flags(0, ENABLED=True),
            minAccountBorrowSize=100 * multiple,
        ),
        100_000_000e8,
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY
        if isPrime
        else environment.notional.getActiveMarkets(currencyId)[0][1]
    )

    # Initial enter of vault
    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25 * multiple * decimals,
        maturity,
        100 * multiple * 1e8,
        0,
        "",
        {"from": accounts[1], "value": 25 * multiple * decimals if currencyId == 1 else 0},
    )

    # Re-enter vault position, with less borrow
    txn = environment.notional.enterVault(
        accounts[1],
        vault.address,
        2.5 * multiple * decimals,
        maturity,
        10 * multiple * 1e8,
        0,
        "",
        {"from": accounts[1], "value": 2.5 * multiple * decimals if currencyId == 1 else 0},
    )

    # TODO: assert events
    #assert "VaultFeeAccrued" in txn.events

    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    (health, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert 0.21e9 < health["collateralRatio"] and health["collateralRatio"] < 0.26e9
    assert pytest.approx(vaultAccount["accountDebtUnderlying"], abs=100) == -110 * multiple * 1e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["lastUpdateBlockTime"] == txn.timestamp

    assert pytest.approx(vaultState["totalDebtUnderlying"], abs=100) == -110 * multiple * 1e8
    assert vaultState["totalVaultShares"] == vaultAccount["vaultShares"]

    check_system_invariants(environment, accounts, [vault])


@given(currencyId=strategy("uint", min_value=1, max_value=3), isPrime=strategy("bool"))
def test_can_deposit_to_reduce_collateral_ratio(
    environment, accounts, SimpleStrategyVault, currencyId, isPrime
):
    decimals = environment.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", environment.notional.address, currencyId, {"from": accounts[0]}
    )
    vault.setExchangeRate(1e18)
    # Set a multiple because ETH liquidity is lower in the test environment
    multiple = 1 if currencyId == 1 else 1_000

    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=currencyId,
            flags=set_flags(0, ENABLED=True),
            minAccountBorrowSize=100 * multiple,
        ),
        100_000_000e8,
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY
        if isPrime
        else environment.notional.getActiveMarkets(currencyId)[0][1]
    )

    # Initial enter of vault
    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25 * multiple * decimals,
        maturity,
        101 * multiple * 1e8,
        0,
        "",
        {"from": accounts[1], "value": 25 * multiple * decimals if currencyId == 1 else 0},
    )

    (healthBefore, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)

    # Deposit collateral, no borrow
    txn = environment.notional.enterVault(
        accounts[1],
        vault.address,
        2 * multiple * decimals,
        maturity,
        0,
        0,
        "",
        {"from": accounts[1], "value": 2 * multiple * decimals if currencyId == 1 else 0},
    )
    # TODO: assert events
    #assert "VaultFeeAccrued" in txn.events

    # if isPrime:
    #     assert "VaultFeeAccrued" in txn.events
    # else:
    #     assert "VaultFeeAccrued" not in txn.events

    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert healthBefore["collateralRatio"] < healthAfter["collateralRatio"]
    assert pytest.approx(vaultAccount["accountDebtUnderlying"], abs=100) == -101 * multiple * 1e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["lastUpdateBlockTime"] == txn.timestamp

    assert pytest.approx(vaultState["totalDebtUnderlying"], abs=10) == -101 * multiple * 1e8
    assert vaultState["totalVaultShares"] == vaultAccount["vaultShares"]

    check_system_invariants(environment, accounts, [vault])

def test_cannot_enter_vault_with_matured_position(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(2)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False)

    # Cannot enter vault with matured position
    with brownie.reverts(dev_revert_msg="dev: cannot enter with matured position"):
        environment.notional.enterVault(
            accounts[1],
            vault.address,
            10_000e18,
            maturity + SECONDS_IN_QUARTER,
            0,
            0,
            "",
            {"from": accounts[1]},
        )

    check_system_invariants(environment, accounts, [vault])

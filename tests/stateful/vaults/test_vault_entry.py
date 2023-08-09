import brownie
import pytest
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from brownie.test import given, strategy
from fixtures import *
from tests.constants import PRIME_CASH_VAULT_MATURITY, SECONDS_IN_QUARTER
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

def calculateDebtAmount(environment, maturity, currencyId, underlyingAmount):
    if maturity == PRIME_CASH_VAULT_MATURITY:
        symbol = environment.symbol[currencyId]
        decimals = 18 if symbol == 'ETH' else environment.token[symbol].decimals()
        return pytest.approx(
            environment.notional.convertUnderlyingToPrimeCash(currencyId, underlyingAmount * (10 ** decimals) / 1e8),
            abs=500,
            rel=1e-5
        )
    else:
        return underlyingAmount

def test_only_vault_entry(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ONLY_VAULT_ENTRY=1), currencyId=2),
        100_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    with brownie.reverts(dev_revert_msg="dev: unauthorized"):
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
    with EventChecker(environment, 'Vault Entry', vaults=[vault],
        vault=vault,
        account=accounts[1],
        maturity=maturity,
        marginDeposit=environment.approxPrimeCash('DAI', 100_000e18),
        debtAmount=100_000e8
    ) as e:
        txn = environment.notional.enterVault(
            accounts[1], vault.address, 100_000e18, maturity, 100_000e8, 0, "", {"from": vault.address}
        )
        e['txn'] = txn

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

    with brownie.reverts(dev_revert_msg="dev: borrow failed"):
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
            minAccountBorrowSize=100 * multiple * 1e8,
        ),
        100_000_000e8,
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY
        if isPrime
        else environment.notional.getActiveMarkets(currencyId)[0][1]
    )

    with EventChecker(environment, 'Vault Entry',vaults=[vault],
        vault=vault,
        account=accounts[1],
        maturity=maturity,
        debtAmount=calculateDebtAmount(environment, maturity, currencyId, 100 * multiple * 1e8)
    ) as e:
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
        e['txn'] = txn

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
            minAccountBorrowSize=100 * multiple * 1e8,
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
    with EventChecker(environment, 'Vault Entry',vaults=[vault],
        vault=vault,
        account=accounts[1],
        maturity=maturity,
        # TODO: this is incorrect because it is net off against fees before depositing
        marginDeposit=environment.approxPrimeCash(environment.symbol[currencyId], 2.5 * multiple * decimals, rel=1e-3),
        debtAmount=calculateDebtAmount(environment, maturity, currencyId, 10 * multiple * 1e8)
    ) as e:
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
        e['txn'] = txn

    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    (health, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert 0.21e9 < health["collateralRatio"] and health["collateralRatio"] < 0.26e9
    if isPrime:
        assert pytest.approx(vaultAccount["accountDebtUnderlying"], rel=1e-6) == -110 * multiple * 1e8
    else:
        assert pytest.approx(vaultAccount["accountDebtUnderlying"], abs=100) == -110 * multiple * 1e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["lastUpdateBlockTime"] == txn.timestamp

    assert pytest.approx(vaultState["totalDebtUnderlying"], abs=100) == vaultAccount['accountDebtUnderlying']
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
            minAccountBorrowSize=100 * multiple * 1e8,
        ),
        100_000_000e8,
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY
        if isPrime
        else environment.notional.getActiveMarkets(currencyId)[0][1]
    )

    # Initial entry of vault
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

    chain.mine(1, timedelta=86400)
    # Deposit collateral, no borrow
    with EventChecker(environment, 'Vault Entry', vaults=[vault],
        vault=vault,
        account=accounts[1],
        debtAmount=lambda x: x > 0 if isPrime else x == 0,
        marginDeposit=environment.approxPrimeCash(environment.symbol[currencyId], 2 * multiple * decimals, rel=1e-5)
    ) as e:
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
        e['txn'] = txn

    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault)
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert healthBefore["collateralRatio"] < healthAfter["collateralRatio"]
    if isPrime:
        assert pytest.approx(vaultAccount["accountDebtUnderlying"], rel=1e-4) == -101 * multiple * 1e8
    else:
        assert pytest.approx(vaultAccount["accountDebtUnderlying"], abs=100) == -101 * multiple * 1e8

    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["lastUpdateBlockTime"] == txn.timestamp

    assert pytest.approx(vaultState["totalDebtUnderlying"], abs=10) == vaultAccount['accountDebtUnderlying']
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

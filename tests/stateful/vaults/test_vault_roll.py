import logging
import math
import random

import brownie
import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from fixtures import *
from tests.constants import PRIME_CASH_VAULT_MATURITY, SECONDS_IN_QUARTER
from tests.helpers import get_lend_action
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()
LOGGER = logging.getLogger(__name__)

"""
Roll Test Plan

Authorization:
    - Only vault roll
    - Allow roll (test_roll_vault_disabled)
    - Is enabled
    - Not same maturity
    - Must borrow

Lend to Exit:
    - Lending Fails

Enter Vault:
    - Borrow Fails (test_roll_vault_borrow_failure)
    - Max Capacity (test_roll_vault_over_maximum_capacity)
    - Invalid maturity (test_roll_vault_past_max_market)
    - Collateral Ratio (test_roll_vault_below_max_collateral_ratio)
    - Collateral Ratio (test_roll_vault_insufficient_collateral)


Potential Roll Pairs:
    - With Deposit, at max capacity
    - Shorter fCash => Longer fCash
    - Longer fCash => Shorter fCash
    - Prime Cash => fCash
    - fCash => Prime Cash
    - Matured fCash => fCash
"""


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.fixture(autouse=False)
def roll_account(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(2)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    return accounts[1]


def test_roll_vault_only_vault_roll(environment, vault, roll_account):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0), currencyId=2), 100_000_000e8
    )
    maturity = environment.notional.getActiveMarkets(2)[1][1]

    with brownie.reverts():
        environment.notional.rollVaultPosition(
            roll_account, vault, 100_000e8, maturity, 0, 0, 0, "", {"from": roll_account}
        )


def test_vault_disabled(environment, vault, roll_account, accounts):
    environment.notional.setVaultPauseStatus(vault, False, {"from": accounts[0]})
    maturity = environment.notional.getActiveMarkets(2)[1][1]

    with brownie.reverts():
        environment.notional.rollVaultPosition(
            roll_account, vault, 100_000e8, maturity, 0, 0, 0, "", {"from": roll_account}
        )


def test_no_borrow(environment, vault, roll_account):
    maturity = environment.notional.getActiveMarkets(2)[1][1]

    with brownie.reverts():
        # Borrow amount is set to zero
        environment.notional.rollVaultPosition(
            roll_account, vault, 0, maturity, 0, 0, 0, "", {"from": roll_account}
        )


def test_same_maturity(environment, vault, roll_account):
    maturity = environment.notional.getActiveMarkets(2)[0][1]

    with brownie.reverts():
        # Maturity is the same
        environment.notional.rollVaultPosition(
            roll_account, vault, 105_000e8, maturity, 0, 0, 0, "", {"from": roll_account}
        )

def test_cannot_roll_into_past_maturity(environment, vault, roll_account):
    maturity = environment.notional.getActiveMarkets(2)[0][1] - SECONDS_IN_QUARTER

    with brownie.reverts(dev_revert_msg="dev: cannot roll to matured"):
        environment.notional.rollVaultPosition(
            roll_account,
            vault,
            105_000e8,
            maturity,
            0,
            0,
            0,
            "",
            {"from": roll_account},
        )

def test_cannot_roll_same_maturity_matured(environment, vault, roll_account):
    chain.mine(1, timedelta=SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(2, False)

    with brownie.reverts():
        # Maturity is the same
        environment.notional.rollVaultPosition(
            roll_account,
            vault,
            105_000e8,
            PRIME_CASH_VAULT_MATURITY,
            0,
            0,
            0,
            "",
            {"from": roll_account},
        )


def test_roll_vault_disabled(environment, vault, roll_account):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(2)[1][1]

    with brownie.reverts():
        environment.notional.rollVaultPosition(
            roll_account, vault, 100_000e8, maturity, 0, 0, 0, "", {"from": roll_account}
        )


def test_roll_vault_borrow_failure(environment, vault, roll_account, accounts):
    maturity = environment.notional.getActiveMarkets(2)[1][1]
    environment.notional.nTokenRedeem(
        accounts[0],
        2,
        990_000e8 * environment.primeCashScalars["DAI"],
        True,
        True,
        {"from": accounts[0]},
    )

    with brownie.reverts("Borrow failed"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 100_000e8, maturity, 0, 0, 0, "", {"from": roll_account}
        )


def test_roll_vault_insufficient_collateral(environment, vault, roll_account):
    maturity = environment.notional.getActiveMarkets(2)[1][1]

    with brownie.reverts("Insufficient Collateral"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 150_000e8, maturity, 0, 0, 0, "", {"from": roll_account}
        )

def test_roll_vault_over_maximum_capacity(environment, vault, roll_account, accounts):
    maturity2 = environment.notional.getActiveMarkets(2)[1][1]
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1), currencyId=2),
        105_000e8,
    )

    with brownie.reverts("Max Capacity"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 110_000e8, maturity2, 0, 0, 0, "", {"from": roll_account}
        )

    # This should succeed because 100k fCash is repaid and then re-borrowed
    environment.notional.rollVaultPosition(
        roll_account, vault, 105_000e8, maturity2, 3000e18, 0, 0, "", {"from": roll_account}
    )

    check_system_invariants(environment, accounts, [vault])


def test_roll_vault_past_max_market(environment, vault, roll_account, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1),
            currencyId=2,
            feeRate5BPS=0,
            maxBorrowMarketIndex=1,
        ),
        100_000_000e8,
    )

    maturity2 = environment.notional.getActiveMarkets(2)[1][1]
    with brownie.reverts(dev_revert_msg="dev: invalid maturity"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 102_000e8, maturity2, 0, 0, 0, "", {"from": roll_account}
        )


def test_roll_vault_below_max_collateral_ratio(environment, vault, roll_account, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1),
            currencyId=2,
            feeRate5BPS=0,
            maxDeleverageCollateralRatioBPS=2500,
            maxRequiredAccountCollateralRatio=3000,
            minAccountBorrowSize=10_000,
        ),
        100_000_000e8,
    )
    maturity2 = environment.notional.getActiveMarkets(2)[1][1]

    with brownie.reverts("Above Max Collateral"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 50_000e8, maturity2, 60_000e18, 0, 0, "", {"from": roll_account}
        )

@given(
    currencyId=strategy("uint", min_value=1, max_value=3),
    initialMaturity=strategy("uint", min_value=0, max_value=2),
    hasMatured=strategy("bool"),
    enablefCashDiscount=strategy("bool"),
    depositAmountShare=strategy("uint", min_value=0, max_value=10),
)
def test_roll_vault_success(
    environment,
    currencyId,
    initialMaturity,
    hasMatured,
    SimpleStrategyVault,
    accounts,
    depositAmountShare,
    enablefCashDiscount,
):
    initialMaturity = 1
    hasMatured = False
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
            flags=set_flags(
                0, ENABLED=True, ALLOW_ROLL_POSITION=True, ENABLE_FCASH_DISCOUNT=enablefCashDiscount
            ),
            feeRate5BPS=0,
            minAccountBorrowSize=50 * multiple,
        ),
        100_000_000e8,
    )

    markets = environment.notional.getActiveMarkets(currencyId)
    if initialMaturity == 0:
        maturity = PRIME_CASH_VAULT_MATURITY
    else:
        maturity = markets[initialMaturity - 1][1]

    # Enter the vault at the initial maturity
    initialBorrowed = 100 * multiple * 1e8
    environment.notional.enterVault(
        accounts[1],
        vault.address,
        30 * multiple * decimals,
        maturity,
        initialBorrowed,
        0,
        "",
        {"from": accounts[1], "value": 30 * multiple * decimals if currencyId == 1 else 0},
    )

    if hasMatured:
        # If prime, then this will just accrue debt
        chain.mine(1, timedelta=SECONDS_IN_QUARTER)
        environment.notional.initializeMarkets(currencyId, False)
    else:
        chain.mine(1, timedelta=65)

    # Choose the new destination maturity
    markets = environment.notional.getActiveMarkets(currencyId)
    if maturity == PRIME_CASH_VAULT_MATURITY or maturity < chain.time():
        # Roll out of prime cash into fCash
        newMaturity = markets[0][1]
    # Either roll into the other fCash maturity or prime cash
    elif random.randint(0, 1):
        newMaturity = PRIME_CASH_VAULT_MATURITY
    else:
        # Roll to the new 6 month
        newMaturity = markets[1][1]

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    if maturity == PRIME_CASH_VAULT_MATURITY or maturity < chain.time():
        costToRepay = vaultAccountBefore["accountDebtUnderlying"]
    else:
        (costToRepay, _, _, _) = environment.notional.getDepositFromfCashLend(
            currencyId, initialBorrowed, maturity, 0, chain.time()
        )
        costToRepay = -costToRepay * 1e8 / decimals

    newBorrowedfCash = initialBorrowed * 1.05
    if newMaturity != PRIME_CASH_VAULT_MATURITY:
        (newBorrowedCash, _, _, _) = environment.notional.getPrincipalFromfCashBorrow(
            currencyId, newBorrowedfCash, newMaturity, 0, chain.time()
        )
        newBorrowedCash = newBorrowedCash * 1e8 / decimals
    else:
        newBorrowedCash = newBorrowedfCash

    depositAmount = math.floor(newBorrowedfCash * decimals * depositAmountShare / (100 * 1e8))
    with EventChecker(environment, 'Vault Roll', vaults=[vault],
        vault=vault,
        account=accounts[1],
        newMaturity=newMaturity,
        debtAmount=lambda x: newBorrowedfCash == x if newMaturity != PRIME_CASH_VAULT_MATURITY else True
    ) as e:
        txn = environment.notional.rollVaultPosition(
            accounts[1],
            vault,
            newBorrowedfCash,
            newMaturity,
            depositAmount,
            0,
            0,
            "",
            {"from": accounts[1], "value": depositAmount if currencyId == 1 else 0},
        )
        e['txn'] = txn

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)

    assert vaultAccountAfter["lastUpdateBlockTime"] == txn.timestamp
    assert vaultAccountAfter["maturity"] == newMaturity
    assert pytest.approx(vaultAccountAfter["accountDebtUnderlying"], abs=100) == -newBorrowedfCash

    # Add / subtract deposit amount here..
    rollBorrowLendCostInternal = (
        newBorrowedCash + costToRepay + math.floor(depositAmount * 1e8 / decimals)
    )
    netSharesMinted = vaultAccountAfter["vaultShares"] - vaultAccountBefore["vaultShares"]
    assert netSharesMinted > 0
    # This is approx equal because there is no vault fee assessed
    assert pytest.approx(rollBorrowLendCostInternal, rel=1e-5) == netSharesMinted

    check_system_invariants(environment, accounts, [vault])

def test_roll_vault_lending_fails(environment, accounts, vault, roll_account):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1),
            currencyId=2,
            feeRate5BPS=0,
            minCollateralRatioBPS=1900,
        ),
        100_000_000e8,
    )

    # Lend the first market down to zero
    action = get_lend_action(
        2,
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 580_000e8, "minSlippage": 0},
            # Lower the interest rate a little on the second market
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 400_000e8, "minSlippage": 0},
        ],
        True,
    )
    environment.notional.batchLend(accounts[0], [action], {"from": accounts[0]})
    maturity1 = environment.notional.getActiveMarkets(2)[0][1]
    maturity2 = environment.notional.getActiveMarkets(2)[1][1]

    (amountUnderlying, _, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity1, 0, chain.time()
    )
    # Shows that lending will fail
    assert amountUnderlying == 0

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (
        borrowAmountUnderlying,
        _,
        _,
        _,
    ) = environment.notional.getPrincipalFromfCashBorrow(2, 103_000e8, maturity2, 0, chain.time())

    with EventChecker(environment, 'Vault Roll', vaults=[vault],
        vault=vault,
        account=accounts[1],
        newMaturity=maturity2,
        debtAmount=103_000e8,
        lendAtZero=True
    ) as e:
        txn = environment.notional.rollVaultPosition(
            roll_account, vault, 103_000e8, maturity2, 1_000e18, 0, 0, "", {"from": roll_account}
        )
        e['txn'] = txn

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    vaultState1After = environment.notional.getVaultState(vault, maturity1)
    vaultStateNew = environment.notional.getVaultState(vault, vaultAccountAfter["maturity"])

    assert vaultState1After["totalDebtUnderlying"] == 0
    assert vaultState1After["totalVaultShares"] == 0

    assert vaultStateNew["totalDebtUnderlying"] == -103_000e8
    assert vaultStateNew["totalVaultShares"] == vaultAccountAfter["vaultShares"]

    assert vaultAccountAfter["maturity"] == maturity2

    lendAmountUnderlying = 100_000e18
    rollBorrowLendCostInternal = (borrowAmountUnderlying - lendAmountUnderlying) / 1e10
    netSharesMinted = vaultAccountAfter["vaultShares"] - vaultAccountBefore["vaultShares"]
    assert netSharesMinted > 0
    # This is approx equal because there is no vault fee assessed
    assert pytest.approx(rollBorrowLendCostInternal + 1_000e8, rel=1e-5) == netSharesMinted

    # Increase the reserve balance to account for the cash used to offset the fCash
    (primeRate, _, _, _) = environment.notional.getPrimeFactors(2, chain.time() + 1)
    environment.notional.setReserveCashBalance(
        2,
        environment.notional.getReserveBalance(2)
        + math.floor(100_000e8 * 1e36 / primeRate["supplyFactor"]),
    )
    vaultfCashOverrides = [{"currencyId": 2, "maturity": maturity1, "fCash": -100_000e8}]
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)


@given(
    currencyId=strategy("uint", min_value=1, max_value=3),
    initialMaturity=strategy("uint", min_value=0, max_value=1),
)
def test_roll_vault_collateral_ratio(
    environment, accounts, currencyId, initialMaturity, SimpleStrategyVault
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
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True, ENABLE_FCASH_DISCOUNT=True),
            feeRate5BPS=0,
            minAccountBorrowSize=50 * multiple,
        ),
        100_000_000e8,
    )

    markets = environment.notional.getActiveMarkets(currencyId)
    maturity = markets[initialMaturity][1]
    newMaturity = markets[1 - initialMaturity][1]

    # Enter the vault at the initial maturity
    initialBorrowed = 100 * multiple * 1e8
    environment.notional.enterVault(
        accounts[1],
        vault.address,
        30 * multiple * decimals,
        maturity,
        initialBorrowed,
        0,
        "",
        {"from": accounts[1], "value": 30 * multiple * decimals if currencyId == 1 else 0},
    )

    (costToRepay, _, _, _) = environment.notional.getDepositFromfCashLend(
        currencyId, initialBorrowed, maturity, 0, chain.time()
    )
    costToRepay = costToRepay * 1e8 / decimals

    newBorrowedCash = costToRepay * decimals / 1e8
    (newBorrowedfCash, _, _) = environment.notional.getfCashBorrowFromPrincipal(
        currencyId, newBorrowedCash, newMaturity, 0, chain.time(), True
    )

    # Deposit 1%
    depositAmount = math.floor(newBorrowedCash * 0.001)
    healthBefore = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)[0]
    environment.notional.rollVaultPosition(
        accounts[1],
        vault,
        newBorrowedfCash,
        newMaturity,
        depositAmount,
        0,
        0,
        "",
        {"from": accounts[1], "value": depositAmount if currencyId == 1 else 0},
    )

    healthAfter = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)[0]

    # When rolling to prime cash vault maturity, collateral ratio will change
    # TODO: figure out this ratio, it's not correct here
    assert pytest.approx(healthBefore["collateralRatio"], abs=100) == healthAfter["collateralRatio"]

    check_system_invariants(environment, accounts, [vault])

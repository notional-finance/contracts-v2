import logging
import math

import brownie
import hypothesis
import pytest
from brownie import MockERC20, SimpleStrategyVault
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from fixtures import *
from scripts.EventProcessor import processTxn
from tests.constants import PRIME_CASH_VAULT_MATURITY, SECONDS_IN_QUARTER
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()
LOGGER = logging.getLogger(__name__)


"""
Vault Exit Testing Plan

Pre Exit Checks:
  - Vault Authorization (test_only_vault_exit)
  - Can exit if paused
  - Min Entry Time (test_cannot_exit_within_min_blocks)
  - Settle Vault Account

Lend to Exit:
  - Cannot lend to positive position
  - Lending to prime cash will assess fees
  - Lend may fail, deposit to account cash balance

Transfer Tokens:
  - Return prime cash to receiver/account
  - Return post repayment profits to receiver/account
  - Transfer repayment requirement from account

Set Vault Account:
  - Check minimum borrow (test_exit_vault_min_borrow)
  - Clear maturity on full exit

Check Collateral Ratio:
  - Max Collateral Ratio (test_cannot_exit_vault_above_max_collateral)
  - Min Collateral Ratio (test_exit_vault_insufficient_collateral)
"""


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

# def check_exit_events(environment, txn, vault, debtToRepay, vaultSharesToRedeem):
#     decoded = decode_events(environment, txn, vaults=[vault])
#     grouped = group_events(decoded)
    
#     # assert len(grouped['Deposit']) == 1
#     # deposit = grouped['Deposit'][0]
#     # assert deposit['groupType'] == 'Deposit and Transfer Prime Cash'
#     # assert deposit['receiver'] == vault
#     # assert deposit['primeCashDeposit'] == deposit['primeCashTransfer']

#     # If Borrowing fCash
#     netRepay = 0
#     if len(grouped['Buy fCash [nToken]']) > 0:
#         assert len(grouped['Buy fCash [nToken]']) == 1
#         lend = grouped['Buy fCash [nToken]'][0]
#         assert lend['account'] == vault

#         assert len(grouped['Vault Fees']) == 0
#         netRepay = lend['netAccountPrimeCash']

#     if debtToRepay > 0:
#         assert len(grouped['Vault Exit']) == 1
#         exit = grouped['Vault Exit'][0]
#         assert exit['vault'] == vault

#     if vaultSharesToRedeem > 0:
#         assert len(grouped['Vault Redeem']) == 1 or len(grouped['Deposit']) == 1
#         if len(grouped['Vault Redeem']) == 1:
#             redeem = grouped['Vault Redeem'][0]
#             assert redeem['vault'] == vault
#         else:
#             deposit = grouped['Deposit'][0]
#             assert deposit['receiver'] == vault

#     # TODO: this is off by a little bit
#     # assert entry['primeCash'] == deposit['primeCashTransfer'] - netBorrowed

#     return (decoded, grouped)


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

    with brownie.reverts():
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

    chain.mine(1, timedelta=60)
    with brownie.reverts("Above Max Collateral"):
        # Approx 250_000 vault shares w/ 200_000 borrow, reducing borrow
        # to 100_000 will revert (2.25x leverage < 3.3x required)
        environment.notional.exitVault(
            accounts[1], vault.address, accounts[1], 0, 100_000e8, 0, "", {"from": accounts[1]}
        )

    # Can reduce a smaller size
    environment.notional.exitVault(
        accounts[1], vault.address, accounts[1], 0, 5_000e8, 0, "", {"from": accounts[1]}
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
        195_000e8,
        0,
        "",
        {"from": accounts[1]},
    )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault).dict()
    assert vaultAccountAfter["maturity"] == 0
    assert vaultAccountAfter["vaultShares"] == 0
    assert vaultAccountAfter["accountDebtUnderlying"] == 0

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

    with brownie.reverts(dev_revert_msg="dev: unauthorized"):
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

    chain.mine(1, timedelta=60)
    with EventChecker(environment, 'Vault Exit', vaults=[vault],
        vault=vault,
        account=accounts[1],
        maturity=maturity,
        debtRepaid=50_000e8,
        vaultRedeemed=50_000e8
    ) as e:
        # Execution from vault is allowed
        txn = environment.notional.exitVault(
            accounts[1], vault.address, accounts[1], 50_000e8, 50_000e8, 0, "", {"from": vault.address}
        )
        e['txn'] = txn

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

    chain.mine(1, timedelta=60)
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
    chain.mine(1, timedelta=60)
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.exitVault(
            accounts[1], vault.address, accounts[1], 10_000e8, 0, 0, "", {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts, [vault])


def get_vault_account(environment, accounts, currencyId, isPrime, enablefCashDiscount):
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
            minAccountBorrowSize=50 * multiple,
        ),
        100_000_000e8,
    )
    maturity = (
        PRIME_CASH_VAULT_MATURITY
        if isPrime
        else environment.notional.getActiveMarkets(currencyId)[0][1]
    )

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

    environment.notional.enterVault(
        accounts[2],
        vault.address,
        25 * multiple * decimals,
        maturity,
        100 * multiple * 1e8,
        0,
        "",
        {"from": accounts[2], "value": 25 * multiple * decimals if currencyId == 1 else 0},
    )

    if currencyId != 1:
        token = MockERC20.at(
            environment.notional.getCurrency(currencyId)["underlyingToken"]["tokenAddress"]
        )
    else:
        token = None

    return (vault, maturity, decimals, token)


"""
# Exit Types
    - Full Exit
        - Vault Shares == 0, Account Debt == 0
        - No FC check required
        - Check Receiver
    - Partial Exit, Repayment
        - Vault Share Value < Debt Repaid
    - Partial Exit, Profits
        - Vault Share Value > Debt Repaid
        - Check Receiver

# Edge Conditions:
    - Vault Has Cash
    - Account Has Cash

# Edge conditions:
    - fCash lending fails (test_exit_vault_lending_fails)

# accountHasCash=strategy("bool") => result of lending failure
# isInsolvent=strategy("bool") => change vault share value?
#   - must be full exit to avoid check
# vaultHasCash=strategy("bool")
"""


def setup_exit_conditions(environment, accounts, currencyId, isPrime, hasMatured):
    (vault, maturity, decimals, token) = get_vault_account(
        environment, accounts, currencyId, isPrime, False
    )

    if hasMatured:
        # If prime, then this will just accrue debt
        chain.mine(1, timedelta=SECONDS_IN_QUARTER)
        environment.notional.initializeMarkets(currencyId, False)
    else:
        # Allow exit
        chain.mine(1, timedelta=60)

    return (vault, maturity, decimals, token)

@given(
    currencyId=strategy("uint", min_value=1, max_value=3),
    isPrime=strategy("bool"),
    hasMatured=strategy("bool"),
)
def test_full_exit(environment, accounts, currencyId, isPrime, hasMatured):
    (vault, maturity, decimals, token) = setup_exit_conditions(
        environment, accounts, currencyId, isPrime, hasMatured
    )

    if currencyId == 1:
        balanceBefore = accounts[1].balance()
    else:
        balanceBefore = token.balanceOf(accounts[1])

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    healthFactors = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)[0]
    totalShareValue = healthFactors["vaultShareValueUnderlying"] * decimals / 1e8

    if isPrime or hasMatured:
        costToRepay = -vaultAccountBefore["accountDebtUnderlying"] * decimals / 1e8
    else:
        (costToRepay, _, _, _) = environment.notional.getDepositFromfCashLend(
            currencyId, -vaultAccountBefore["accountDebtUnderlying"], maturity, 0, chain.time()
        )

    # Full repayment for prime vaults
    debtToRepay = (
        2 ** 256 - 1 if isPrime or hasMatured else -vaultAccountBefore["accountDebtUnderlying"]
    )
    with EventChecker(environment, 'Vault Exit', vaults=[vault],
        vault=vault,
        account=accounts[1],
        maturity=maturity,
        vaultRedeemed=vaultAccountBefore['vaultShares']
    ) as e:
        txn = environment.notional.exitVault(
            accounts[1],
            vault.address,
            accounts[1],
            vaultAccountBefore["vaultShares"],
            debtToRepay,
            0,
            "",
            {"from": accounts[1]},
        )
        e['txn'] = txn

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    assert vaultAccountAfter["maturity"] == 0
    assert vaultAccountAfter["vaultShares"] == 0
    assert vaultAccountAfter["accountDebtUnderlying"] == 0

    # if isPrime or hasMatured:
    #     assert "VaultFeeAccrued" in txn.events
    #     totalFees = (
    #         txn.events["VaultFeeAccrued"]["reserveFee"] + txn.events["VaultFeeAccrued"]["nTokenFee"]
    #     )
    #     totalFees = environment.notional.convertCashBalanceToExternal(currencyId, totalFees, True)
    # else:
    #     totalFees = 0

    # if currencyId == 1:
    #     balanceAfter = accounts[1].balance()
    # else:
    #     balanceAfter = token.balanceOf(accounts[1])

    # assert (
    #     pytest.approx(balanceAfter - balanceBefore, rel=5e-7, abs=5_000)
    #     == totalShareValue - costToRepay - totalFees
    # )

    check_system_invariants(environment, accounts, [vault])


@hypothesis.settings(max_examples=15)
@given(
    currencyId=strategy("uint", min_value=1, max_value=3),
    isPrime=strategy("bool"),
    hasMatured=strategy("bool"),
    shareOfDebtToRedeem=strategy("uint", min_value=0, max_value=120),
)
def test_partial_exit(environment, accounts, currencyId, isPrime, hasMatured, shareOfDebtToRedeem):
    (vault, maturity, decimals, token) = setup_exit_conditions(
        environment, accounts, currencyId, isPrime, hasMatured
    )

    if currencyId == 1:
        balanceBefore = accounts[1].balance()
    else:
        balanceBefore = token.balanceOf(accounts[1])

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    # Repay 25% of the debt
    debtToRepay = -vaultAccountBefore["accountDebtUnderlying"] * 0.25
    if isPrime or hasMatured:
        costToRepay = debtToRepay * decimals / 1e8
    else:
        (costToRepay, _, _, _) = environment.notional.getDepositFromfCashLend(
            currencyId, debtToRepay, maturity, 0, chain.time()
        )

    (healthBefore, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    totalShareValue = healthBefore["vaultShareValueUnderlying"]
    valueToRedeem = costToRepay * shareOfDebtToRedeem / decimals
    valueToRedeemInternal = valueToRedeem * 1e8 / decimals
    sharesToRedeem = math.floor(
        vaultAccountBefore["vaultShares"] * valueToRedeemInternal / totalShareValue
    )
    # Need to buffer ETH by a tiny bit to account for fees and drift in time
    paymentRequired = (
        costToRepay + 5e15 - valueToRedeem if costToRepay + 5e15 > valueToRedeem else 0
    )

    chain.mine(1, timedelta=3600)
    with EventChecker(environment, 'Vault Settle' if hasMatured and not isPrime else 'Vault Exit',vaults=[vault],
        vault=vault,
        account=accounts[1],
        # debtRepaid=debtToRepay,
        # vaultRedeemed=sharesToRedeem,
        feesPaid=lambda x: x > 0
    ) as e:
        txn = environment.notional.exitVault(
            accounts[1],
            vault.address,
            accounts[1],
            sharesToRedeem,
            debtToRepay,
            0,
            "",
            {
                "from": accounts[1],
                "value": paymentRequired * 1.1 if currencyId == 1 and paymentRequired > 0 else 0,
            },
        )
        e['txn'] = txn

    # All these assertions hold for all exits
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    assert vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"] == sharesToRedeem
    assert (
        pytest.approx(
            vaultAccountAfter["accountDebtUnderlying"]
            - vaultAccountBefore["accountDebtUnderlying"],
            rel=1e-4,
        )
        == debtToRepay
    )

    if currencyId == 1:
        balanceAfter = accounts[1].balance()
    else:
        balanceAfter = token.balanceOf(accounts[1])

    # assert (
    #     pytest.approx(balanceAfter - balanceBefore, rel=5e-7, abs=5_000)
    #     == valueToRedeem - costToRepay - totalFees
    # )

    check_system_invariants(environment, accounts, [vault])


@given(useReceiver=strategy("bool"))
def test_exit_vault_transfer_to_receiver(environment, vault, accounts, useReceiver):
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

    (healthBefore, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBefore = environment.token["DAI"].balanceOf(receiver)

    # If vault share value > exit cost then we transfer to the account
    chain.mine(1, timedelta=65)

    with EventChecker(environment, 'Vault Exit',vaults=[vault],
        vault=vault,
        account=accounts[1],
        # receiver=receiver,
        maturity=maturity,
        debtRepaid=100_000e8,
        vaultRedeemed=150_000e8,
    ) as e:
        expectedProfit = environment.notional.exitVault.call(
            accounts[1], vault.address, receiver, 150_000e8, 100_000e8, 0, "", {"from": accounts[1]}
        )
        (amountUnderlying, amountAsset, _, _) = environment.notional.getDepositFromfCashLend(
            2, 100_000e8, maturity, 0, chain.time()
        )
        txn = environment.notional.exitVault(
            accounts[1], vault.address, receiver, 150_000e8, 100_000e8, 0, "", {"from": accounts[1]}
        )
        e['txn'] = txn

    balanceAfter = environment.token["DAI"].balanceOf(receiver)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert pytest.approx(balanceAfter - balanceBefore, rel=1e-8) == 150_000e18 - amountUnderlying
    assert pytest.approx(balanceAfter - balanceBefore, rel=1e-7) == expectedProfit
    assert healthBefore["collateralRatio"] < healthAfter["collateralRatio"]

    assert vaultAccount["accountDebtUnderlying"] == -100_000e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 150_000e8

    assert vaultState["totalDebtUnderlying"] == -100_000e8
    assert vaultState["totalVaultShares"] == vaultAccount["vaultShares"]

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
    redeemAmount = 990_000e8 * environment.primeCashScalars["DAI"]
    environment.notional.nTokenRedeem(
        accounts[0], 2, redeemAmount, True, True, {"from": accounts[0]}
    )
    (amountAsset, _, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )
    assert amountAsset == 0

    (healthBefore, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault).dict()
    balanceBeforeReceiver = environment.token["DAI"].balanceOf(receiver)
    balanceBefore = environment.token["DAI"].balanceOf(accounts[1])

    # NOTE: this adds 100_000 DAI into the contract but there is no offsetting fCash position
    # recorded, similarly, the fCash erased is not recorded anywhere either
    chain.mine(1, timedelta=60)

    with EventChecker(environment, 'Vault Exit', vaults=[vault],
        vault=vault,
        account=accounts[1],
        maturity=maturity,
        debtRepaid=100_000e8,
        vaultRedeemed=10_000e8,
        lendAtZero=True
    ) as e:
        txn = environment.notional.exitVault(
            accounts[1], vault.address, receiver, 10_000e8, 100_000e8, 0, "", {"from": accounts[1]}
        )
        e['txn'] = txn

    balanceAfter = environment.token["DAI"].balanceOf(accounts[1])
    balanceAfterReceiver = environment.token["DAI"].balanceOf(receiver)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], vault).dict()
    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultState = environment.notional.getVaultState(vault, maturity)

    assert balanceBefore - balanceAfter == Wei(90_000e18)
    if useReceiver:
        assert balanceBeforeReceiver == balanceAfterReceiver
    assert healthBefore["collateralRatio"] < healthAfter["collateralRatio"]

    assert vaultAccount["accountDebtUnderlying"] == -100_000e8
    assert vaultAccount["maturity"] == maturity
    assert vaultAccount["vaultShares"] == vaultAccountBefore["vaultShares"] - 10_000e8

    assert vaultState["totalDebtUnderlying"] == -100_000e8
    assert vaultState["totalVaultShares"] == vaultAccount["vaultShares"]

    check_system_invariants(environment, accounts, [vault])

    chain.mine(1, timestamp=maturity)
    (_, fCashInReserve, primeCashInReserve) = environment.notional.getTotalfCashDebtOutstanding(2, maturity)
    txn = environment.notional.initializeMarkets(2, False, {"from": accounts[0]})
    eventStore = processTxn(environment, txn)
    burnPCash = [  t for t in eventStore['transfers'] if t['assetType'] == 'pCash' and t['transferType'] == 'Burn' and t['fromSystemAccount'] == 'Settlement' ]
    burnFCash = [  t for t in eventStore['transfers'] if t['assetType'] == 'fCash' and t['transferType'] == 'Burn' and t['fromSystemAccount'] == 'Settlement' ]
    assert len(burnPCash) == 1
    assert len(burnFCash) == 1
    assert burnPCash[0]['value'] == primeCashInReserve
    assert burnFCash[0]['value'] == fCashInReserve

    (_, _, primeCashHeldInReserve) = environment.notional.getTotalfCashDebtOutstanding(2, maturity)
    assert primeCashHeldInReserve == 0
    check_system_invariants(environment, accounts, [vault])

@given(
    currencyId=strategy("uint", min_value=1, max_value=3),
    enablefCashDiscount=strategy("bool"),
)
def test_settle_vault(environment, accounts, currencyId, enablefCashDiscount):
    (vault, maturity, _, _) = get_vault_account(
        environment, accounts, currencyId, False, enablefCashDiscount
    )

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    chain.mine(1, timestamp=maturity)

    with brownie.reverts(dev_revert_msg="dev: settlement rate unset"):
        environment.notional.settleVaultAccount(accounts[1], vault)

    environment.notional.initializeMarkets(currencyId, False)

    (healthBefore, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    with EventChecker(environment, 'Vault Settle', vaults=[vault],
        vault=vault,
        account=accounts[1]
    ) as e:
        txn = environment.notional.settleVaultAccount(accounts[1], vault)
        e['txn'] = txn

    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)

    assert (
        pytest.approx(vaultAccountAfter["accountDebtUnderlying"], rel=1e-6)
        == vaultAccountBefore["accountDebtUnderlying"]
    )
    assert (
        pytest.approx(healthBefore["collateralRatio"], abs=100) == healthAfter["collateralRatio"]
    )

    assert vaultAccountAfter["maturity"] == PRIME_CASH_VAULT_MATURITY
    assert vaultAccountAfter["lastUpdateBlockTime"] == txn.timestamp

    # the second account will be settled in invariants
    check_system_invariants(environment, accounts, [vault])

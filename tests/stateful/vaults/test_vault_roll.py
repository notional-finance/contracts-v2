import brownie
import pytest
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from fixtures import *
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import get_lend_action
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.fixture(autouse=True)
def roll_account(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True, ALLOW_REENTER=1), currencyId=2),
    )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setSettlement(True)

    return accounts[1]


def test_roll_vault_disabled(environment, vault, roll_account):
    environment.notional.updateVault(
        vault.address, get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2)
    )

    with brownie.reverts("No Roll Allowed"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 20_000e8, 100_000e8, (0, 0, "", ""), {"from": roll_account}
        )


def test_roll_vault_outside_of_settlement(environment, vault, roll_account):
    vault.setSettlement(False)

    with brownie.reverts("No Roll Allowed"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 20_000e8, 100_000e8, (0, 0, "", ""), {"from": roll_account}
        )


def test_roll_vault_past_maturity(environment, vault, roll_account):
    maturity = environment.notional.getCurrentVaultMaturity(vault)
    chain.mine(1, timestamp=maturity)

    with brownie.reverts("No Roll Allowed"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 20_000e8, 100_000e8, (0, 0, "", ""), {"from": roll_account}
        )


def test_roll_vault_borrow_failure(environment, vault, roll_account, accounts):
    environment.notional.nTokenRedeem(accounts[0], 2, 49000000e8, True, True, {"from": accounts[0]})

    with brownie.reverts("Borrow failed"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 20_000e8, 100_000e8, (0, 0, "", ""), {"from": roll_account}
        )


def test_roll_vault_insufficient_collateral(environment, vault, roll_account):
    with brownie.reverts("Insufficient Collateral"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 25_000e8, 150_000e8, (0, 0, "", ""), {"from": roll_account}
        )


def test_roll_vault_over_maximum_capacity(environment, vault, roll_account, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_REENTER=1),
            currencyId=2,
            maxVaultBorrowSize=200_000e8,
        ),
    )
    vault.setSettlement(False)

    environment.notional.enterVault(
        accounts[0], vault.address, 25_000e18, True, 100_000e8, 0, "", {"from": accounts[0]}
    )
    vault.setSettlement(True)

    with brownie.reverts("Insufficient capacity"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 25_000e8, 150_000e8, (0, 0, "", ""), {"from": roll_account}
        )

    # This should succeed because 100k fCash is repaid and then re-borrowed
    environment.notional.rollVaultPosition(
        roll_account, vault, 25_000e8, 100_000e8, (0, 0, "", ""), {"from": roll_account}
    )

    check_system_invariants(environment, accounts, [vault])


def test_roll_vault_success(environment, vault, roll_account, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_REENTER=1), currencyId=2, feeRate5BPS=0
        ),
    )

    maturity = environment.notional.getCurrentVaultMaturity(vault)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    (lendAmountUnderlying, lendAmountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )
    (
        borrowAmountUnderlying,
        borrowAmountAsset,
        _,
        _,
    ) = environment.notional.getPrincipalFromfCashBorrow(
        2, 100_000e8, maturity + SECONDS_IN_QUARTER, 0, chain.time()
    )

    environment.notional.rollVaultPosition(
        roll_account, vault, 3_000e8, 100_000e8, (0, 0, "", ""), {"from": roll_account}
    )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    vaultState1After = environment.notional.getVaultState(vault, maturity)
    vaultStateNew = environment.notional.getVaultState(vault, vaultAccountAfter["maturity"])

    assert vaultState1After["totalfCash"] == 0
    assert vaultState1After["totalfCashRequiringSettlement"] == 0
    assert vaultState1After["totalVaultShares"] == 0
    assert vaultState1After["totalAssetCash"] == 0
    assert vaultState1After["totalStrategyTokens"] == 0

    assert vaultStateNew["totalfCash"] == -100_000e8
    assert vaultStateNew["totalfCashRequiringSettlement"] == -100_000e8
    assert vaultStateNew["totalAssetCash"] == 0
    assert vaultStateNew["totalVaultShares"] == vaultAccountAfter["vaultShares"]

    assert vaultAccountAfter["maturity"] == maturity + SECONDS_IN_QUARTER

    rollBorrowLendCostInternal = (lendAmountUnderlying - borrowAmountUnderlying) / 1e10
    netSharesRedeemed = vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"]
    # This is approx equal because there is no vault fee assessed
    assert pytest.approx(rollBorrowLendCostInternal, rel=1e-6) == netSharesRedeemed

    check_system_invariants(environment, accounts, [vault])


def test_roll_vault_lending_fails(environment, accounts, vault, roll_account):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_REENTER=1), currencyId=2, feeRate5BPS=0
        ),
    )

    # Lend the first market down to zero
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 180_000e8, "minSlippage": 0}],
        False,
    )
    environment.notional.batchLend(accounts[0], [action], {"from": accounts[0]})
    maturity = environment.notional.getCurrentVaultMaturity(vault)
    (amountUnderlying, _, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity, 0, chain.time()
    )
    assert amountUnderlying == 0

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    (
        borrowAmountUnderlying,
        borrowAmountAsset,
        _,
        _,
    ) = environment.notional.getPrincipalFromfCashBorrow(
        2, 100_000e8, maturity + SECONDS_IN_QUARTER, 0, chain.time()
    )

    environment.notional.rollVaultPosition(
        roll_account, vault, 3_000e8, 100_000e8, (0, 0, "", ""), {"from": roll_account}
    )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    vaultState1After = environment.notional.getVaultState(vault, maturity)
    vaultStateNew = environment.notional.getVaultState(vault, vaultAccountAfter["maturity"])

    assert vaultState1After["totalfCash"] == 0
    assert vaultState1After["totalfCashRequiringSettlement"] == 0
    assert vaultState1After["totalVaultShares"] == 0
    assert vaultState1After["totalAssetCash"] == 0
    assert vaultState1After["totalStrategyTokens"] == 0

    assert vaultStateNew["totalfCash"] == -100_000e8
    assert vaultStateNew["totalfCashRequiringSettlement"] == -100_000e8
    assert vaultStateNew["totalAssetCash"] == 0
    assert vaultStateNew["totalVaultShares"] == vaultAccountAfter["vaultShares"]

    assert vaultAccountAfter["maturity"] == maturity + SECONDS_IN_QUARTER

    lendAmountUnderlying = 100_000e18
    rollBorrowLendCostInternal = (lendAmountUnderlying - borrowAmountUnderlying) / 1e10
    netSharesRedeemed = vaultAccountBefore["vaultShares"] - vaultAccountAfter["vaultShares"]
    # This is approx equal because there is no vault fee assessed
    assert pytest.approx(rollBorrowLendCostInternal, rel=1e-6) == netSharesRedeemed

    check_system_invariants(environment, accounts, [vault])

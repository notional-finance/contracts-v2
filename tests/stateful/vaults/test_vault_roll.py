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
        get_vault_config(flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(2)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    return accounts[1]


def test_roll_vault_disabled(environment, vault, roll_account):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(flags=set_flags(0, ENABLED=True), currencyId=2),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(2)[1][1]

    with brownie.reverts("No Roll Allowed"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 100_000e8, maturity, 0, 0, 0, "", {"from": roll_account}
        )


def test_roll_vault_past_maturity(environment, vault, roll_account):
    maturity = environment.notional.getActiveMarkets(2)[0][1]
    chain.mine(1, timestamp=maturity)

    with brownie.reverts("No Roll Allowed"):
        environment.notional.rollVaultPosition(
            roll_account, vault, 100_000e8, maturity, 0, 0, 0, "", {"from": roll_account}
        )


def test_roll_vault_borrow_failure(environment, vault, roll_account, accounts):
    maturity = environment.notional.getActiveMarkets(2)[1][1]
    environment.notional.nTokenRedeem(accounts[0], 2, 49000000e8, True, True, {"from": accounts[0]})

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
        roll_account, vault, 105_000e8, maturity2, 0, 0, 0, "", {"from": roll_account}
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
    with brownie.reverts("Invalid Maturity"):
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


def test_roll_vault_success(environment, vault, roll_account, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1), currencyId=2, feeRate5BPS=0
        ),
        100_000_000e8,
    )
    maturity1 = environment.notional.getActiveMarkets(2)[0][1]
    maturity2 = environment.notional.getActiveMarkets(2)[1][1]
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    (lendAmountUnderlying, lendAmountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity1, 0, chain.time()
    )
    (
        borrowAmountUnderlying,
        borrowAmountAsset,
        _,
        _,
    ) = environment.notional.getPrincipalFromfCashBorrow(2, 102_000e8, maturity2, 0, chain.time())

    expectedStrategyTokens = environment.notional.rollVaultPosition.call(
        roll_account, vault, 102_000e8, maturity2, 0, 0, 0, "", {"from": roll_account}
    )

    txn = environment.notional.rollVaultPosition(
        roll_account, vault, 102_000e8, maturity2, 0, 0, 0, "", {"from": roll_account}
    )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    vaultState1After = environment.notional.getVaultState(vault, maturity1)
    vaultStateNew = environment.notional.getVaultState(vault, vaultAccountAfter["maturity"])

    assert vaultAccountAfter["lastEntryBlockHeight"] == txn.block_number
    assert vaultAccountAfter["lastEntryBlockHeight"] > vaultAccountBefore["lastEntryBlockHeight"]
    assert vaultState1After["totalfCash"] == 0
    assert vaultState1After["totalVaultShares"] == 0
    assert vaultState1After["totalAssetCash"] == 0
    assert vaultState1After["totalStrategyTokens"] == 0

    assert vaultStateNew["totalfCash"] == -102_000e8
    assert vaultStateNew["totalAssetCash"] == 0
    assert vaultStateNew["totalVaultShares"] == vaultAccountAfter["vaultShares"]
    assert pytest.approx(vaultAccountAfter["vaultShares"], abs=1e5) == expectedStrategyTokens

    assert vaultAccountAfter["maturity"] == maturity2

    rollBorrowLendCostInternal = (borrowAmountUnderlying - lendAmountUnderlying) / 1e10
    netSharesMinted = vaultAccountAfter["vaultShares"] - vaultAccountBefore["vaultShares"]
    assert netSharesMinted > 0
    # This is approx equal because there is no vault fee assessed
    assert pytest.approx(rollBorrowLendCostInternal, rel=1e-6) == netSharesMinted

    check_system_invariants(environment, accounts, [vault])


def test_roll_vault_lending_fails(environment, accounts, vault, roll_account):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1), currencyId=2, feeRate5BPS=0
        ),
        100_000_000e8,
    )

    # Lend the first market down to zero
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 180_000e8, "minSlippage": 0}],
        False,
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
        borrowAmountAsset,
        _,
        _,
    ) = environment.notional.getPrincipalFromfCashBorrow(2, 103_000e8, maturity2, 0, chain.time())

    environment.notional.rollVaultPosition(
        roll_account, vault, 103_000e8, maturity2, 0, 0, 0, "", {"from": roll_account}
    )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    vaultState1After = environment.notional.getVaultState(vault, maturity1)
    vaultStateNew = environment.notional.getVaultState(vault, vaultAccountAfter["maturity"])

    assert vaultState1After["totalfCash"] == 0
    assert vaultState1After["totalVaultShares"] == 0
    assert vaultState1After["totalAssetCash"] == 0
    assert vaultState1After["totalStrategyTokens"] == 0

    assert vaultStateNew["totalfCash"] == -103_000e8
    assert vaultStateNew["totalAssetCash"] == 0
    assert vaultStateNew["totalVaultShares"] == vaultAccountAfter["vaultShares"]

    assert vaultAccountAfter["maturity"] == maturity2

    lendAmountUnderlying = 100_000e18
    rollBorrowLendCostInternal = (borrowAmountUnderlying - lendAmountUnderlying) / 1e10
    netSharesMinted = vaultAccountAfter["vaultShares"] - vaultAccountBefore["vaultShares"]
    assert netSharesMinted > 0
    # This is approx equal because there is no vault fee assessed
    assert pytest.approx(rollBorrowLendCostInternal, rel=1e-6) == netSharesMinted

    # Increase the reserve balance to account for the cash used to offset the fCash
    environment.notional.setReserveCashBalance(
        2, environment.notional.getReserveBalance(2) + 5_000_000e8
    )
    vaultfCashOverrides = [{"currencyId": 2, "maturity": maturity1, "fCash": -100_000e8}]
    check_system_invariants(environment, accounts, [vault], vaultfCashOverrides)


def test_roll_vault_with_deposit_amount(environment, accounts, vault, roll_account):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=1), currencyId=2, feeRate5BPS=0
        ),
        100_000e8,
    )
    maturity1 = environment.notional.getActiveMarkets(2)[0][1]
    maturity2 = environment.notional.getActiveMarkets(2)[1][1]
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    (lendAmountUnderlying, lendAmountAsset, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100_000e8, maturity1, 0, chain.time()
    )
    (
        borrowAmountUnderlying,
        borrowAmountAsset,
        _,
        _,
    ) = environment.notional.getPrincipalFromfCashBorrow(2, 100_000e8, maturity2, 0, chain.time())

    # Since the borrow capacity is at the max here, we cannot roll the position with 102_000e8
    # fCash, instead we will deposit 2_000e8 and ensure that we can roll the position by only
    # borrow 100_000e8 fCash
    expectedStrategyTokens = environment.notional.rollVaultPosition.call(
        roll_account, vault, 100_000e8, maturity2, 2_000e18, 0, 0, "", {"from": roll_account}
    )

    txn = environment.notional.rollVaultPosition(
        roll_account, vault, 100_000e8, maturity2, 2_000e18, 0, 0, "", {"from": roll_account}
    )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    vaultState1After = environment.notional.getVaultState(vault, maturity1)
    vaultStateNew = environment.notional.getVaultState(vault, vaultAccountAfter["maturity"])

    assert vaultState1After["totalfCash"] == 0
    assert vaultState1After["totalVaultShares"] == 0
    assert vaultState1After["totalAssetCash"] == 0
    assert vaultState1After["totalStrategyTokens"] == 0

    assert vaultStateNew["totalfCash"] == -100_000e8
    assert vaultStateNew["totalAssetCash"] == 0
    assert vaultStateNew["totalVaultShares"] == vaultAccountAfter["vaultShares"]
    assert pytest.approx(vaultAccountAfter["vaultShares"], abs=1e5) == expectedStrategyTokens

    assert vaultAccountAfter["maturity"] == maturity2

    rollBorrowLendCostInternal = (borrowAmountUnderlying - lendAmountUnderlying) / 1e10
    netSharesMinted = vaultAccountAfter["vaultShares"] - vaultAccountBefore["vaultShares"]
    assert netSharesMinted > 0
    # This is approx equal because there is no vault fee assessed
    assert pytest.approx(rollBorrowLendCostInternal + 2000e8, rel=1e-6) == netSharesMinted

    assert txn.events["VaultEnterMaturity"]
    assert txn.events["VaultEnterMaturity"]["underlyingTokensDeposited"] == 0
    assert (
        pytest.approx(txn.events["VaultEnterMaturity"]["cashTransferToVault"], rel=1e-6)
        == (rollBorrowLendCostInternal + 2000e8) * 50
    )

    check_system_invariants(environment, accounts, [vault])

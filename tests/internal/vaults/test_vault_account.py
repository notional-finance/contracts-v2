import logging

import brownie
import pytest
from brownie import MockAggregator, MockCToken, MockERC20, cTokenV2Aggregator
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from fixtures import *
from tests.constants import SECONDS_IN_MONTH, SECONDS_IN_QUARTER, START_TIME_TREF


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_enforce_borrow_size(vaultConfigAccount, accounts, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config(minAccountBorrowSize=100_000))

    with brownie.reverts("Min Borrow"):
        account = get_vault_account(fCash=-100e8, vaultShares=100)
        vaultConfigAccount.setVaultAccount(account, vault.address)

    # Setting with negative fCash and no vault shares is ok (insolvency)
    account = get_vault_account(fCash=-100e8, vaultShares=0)
    vaultConfigAccount.setVaultAccount(account, vault.address)
    assert account == vaultConfigAccount.getVaultAccount(accounts[0].address, vault.address)

    # Setting with 0 fCash is ok
    account = get_vault_account()
    vaultConfigAccount.setVaultAccount(account, vault.address)
    assert account == vaultConfigAccount.getVaultAccount(accounts[0].address, vault.address)

    # Borrowing at min borrow succeeds
    account = get_vault_account(fCash=-100_000e8)
    vaultConfigAccount.setVaultAccount(account, vault.address)
    assert account == vaultConfigAccount.getVaultAccount(accounts[0].address, vault.address)

    # Borrowing above min borrow succeeds
    account = get_vault_account(fCash=-500_000e8)
    vaultConfigAccount.setVaultAccount(account, vault.address)
    assert account == vaultConfigAccount.getVaultAccount(accounts[0].address, vault.address)


def test_enforce_temp_cash_balance(vaultConfigAccount, accounts, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())

    with brownie.reverts():
        # Any temp cash balance should fail
        account = get_vault_account(tempCashBalance=100e8)
        vaultConfigAccount.setVaultAccount(account, vault.address)


@given(
    fCash=strategy("int", min_value=-100_000e8, max_value=-10_000e8),
    initialRatio=strategy("uint", min_value=0, max_value=30),
)
def test_calculate_deleverage_amount(vaultConfigAccount, accounts, vault, fCash, initialRatio):
    vaultConfigAccount.setVaultConfig(
        vault.address,
        get_vault_config(
            maxDeleverageCollateralRatioBPS=4000, minAccountBorrowSize=10_000, liquidationRate=104
        ),
    )
    vault.setExchangeRate(1e18)
    vaultShares = -fCash + initialRatio * 1000e8
    state = get_vault_state(
        totalfCash=fCash * 10, totalVaultShares=100_000e8, totalStrategyTokens=100_000e8
    )
    account = get_vault_account(fCash=fCash, vaultShares=vaultShares)
    # this is the deposit where all vault shares are purchased
    maxPossibleLiquidatorDeposit = Wei((vaultShares * 50) / 1.04)

    (collateralRatio, vaultShareValue) = vaultConfigAccount.calculateCollateralRatio(
        vault.address, account, state
    )

    maxDeposit = vaultConfigAccount.calculateDeleverageAmount(
        account, vault.address, vaultShareValue
    )

    assert maxDeposit <= maxPossibleLiquidatorDeposit

    # If maxDeposit == maxPossibleLiquidatorDeposit then all vault shares will be sold and the
    # account is insolvent
    if maxDeposit < maxPossibleLiquidatorDeposit:
        vaultSharesPurchased = Wei((maxDeposit * 104 * vaultShares) / (vaultShareValue * 100))
        accountAfter = get_vault_account(
            fCash=Wei(fCash + maxDeposit / 50), vaultShares=vaultShares - vaultSharesPurchased
        )
        (collateralRatioAfter, _) = vaultConfigAccount.calculateCollateralRatio(
            vault.address, accountAfter, state
        )

        # Assert that min borrow size is respected
        assert accountAfter[0] == 0 or -accountAfter[0] >= 10_000e8
        if accountAfter[0] > 0:
            assert pytest.approx(collateralRatioAfter, abs=2) == 0.4e9


def test_settle_fails(vaultConfigAccount, accounts, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    account = get_vault_account(maturity=maturity, fCash=-100_00e8)

    with brownie.reverts("Not Settled"):
        vaultConfigAccount.settleVaultAccount(
            vault.address, account, START_TIME_TREF + SECONDS_IN_QUARTER + 100
        )


def test_vault_with_zero_value(vaultConfigAccount, accounts, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfigAccount.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000_000e8,
            totalStrategyTokens=0,  # This represents profits
            totalAssetCash=0,
            totalfCash=0,
        ),
    )
    vaultConfigAccount.setSettledVaultState(vault.address, maturity, maturity + 100)
    account = get_vault_account(maturity=maturity, fCash=0, vaultShares=10_000e8)

    # Tests a potential divide by zero issue
    txn = vaultConfigAccount.settleVaultAccount(vault.address, account, maturity + 100)
    (accountAfter, strategyTokens) = txn.return_value
    assert strategyTokens == 0
    assert accountAfter["vaultShares"] == 0
    assert accountAfter["tempCashBalance"] == 0
    assert vaultConfigAccount.getRemainingSettledTokens(vault.address, maturity) == (0, 0)


@given(residual=strategy("uint", max_value=100_000e8))
def test_settle_asset_cash_with_residual(vaultConfigAccount, accounts, vault, residual):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfigAccount.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000_000e8,
            totalStrategyTokens=100_000e8,  # This represents profits
            totalAssetCash=50_000_000e8 + residual,
            totalfCash=-1_000_000e8,
        ),
    )
    vaultConfigAccount.setSettledVaultState(vault.address, maturity, maturity + 100)

    account = get_vault_account(maturity=maturity, fCash=-10_000e8, vaultShares=10_000e8)

    account2 = get_vault_account(
        maturity=maturity, fCash=-1_000_000e8 + 10_000e8, vaultShares=1_000_000e8 - 10_000e8
    )

    txn1 = vaultConfigAccount.settleVaultAccount(vault.address, account, maturity + 100)
    (accountAfter, strategyTokens) = txn1.return_value

    txn2 = vaultConfigAccount.settleVaultAccount(vault.address, account2, maturity + 100)
    (accountAfter2, strategyTokens2) = txn2.return_value
    assert accountAfter["fCash"] == 0
    assert accountAfter["maturity"] == 0
    assert accountAfter["vaultShares"] == 0
    assert accountAfter2["fCash"] == 0
    assert accountAfter2["maturity"] == 0
    assert accountAfter2["vaultShares"] == 0

    # Account gets their share of strategy tokens here, nothing else
    assert strategyTokens + strategyTokens2 <= 100_000e8
    assert pytest.approx(strategyTokens + strategyTokens2, abs=3) == 100_000e8
    # Account gets their share of the residuals
    assert accountAfter["tempCashBalance"] + accountAfter2["tempCashBalance"] <= residual
    assert (
        pytest.approx(accountAfter["tempCashBalance"] + accountAfter2["tempCashBalance"], abs=3)
        == residual
    )

    (remainingStrategyTokens, remainingAssetCash) = vaultConfigAccount.getRemainingSettledTokens(
        vault.address, maturity
    )
    assert pytest.approx(remainingStrategyTokens, abs=5) == 0
    assert pytest.approx(remainingAssetCash, abs=5) == 0
    assert remainingStrategyTokens >= 0
    assert remainingAssetCash >= 0


def test_settle_insolvent_account(vaultConfigAccount, accounts, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfigAccount.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000_000e8,
            totalStrategyTokens=100_000e8,  # This represents profits
            totalAssetCash=50_000_000e8,
            totalfCash=-1_000_000e8,
        ),
    )
    vaultConfigAccount.setSettledVaultState(vault.address, maturity, maturity + 100)

    account = get_vault_account(maturity=maturity, fCash=-10_000e8, vaultShares=0)
    account2 = get_vault_account(
        maturity=maturity, fCash=-1_000_000e8 + 10_000e8, vaultShares=1_000_000e8
    )

    assert vaultConfigAccount.getRemainingSettledTokens(vault.address, maturity) == (100_000e8, 0)
    vaultConfigAccount.setReserveBalance(1, 50_000_000e8)

    txn1 = vaultConfigAccount.settleVaultAccount(vault.address, account, maturity + 100)
    (accountAfter, strategyTokens) = txn1.return_value

    txn2 = vaultConfigAccount.settleVaultAccount(vault.address, account2, maturity + 100)
    (accountAfter2, strategyTokens2) = txn2.return_value

    assert accountAfter["fCash"] == 0
    assert accountAfter["maturity"] == 0
    assert accountAfter["vaultShares"] == 0
    assert accountAfter2["fCash"] == 0
    assert accountAfter2["maturity"] == 0
    assert accountAfter2["vaultShares"] == 0

    # Account gets their share of strategy tokens here, nothing else
    assert strategyTokens == 0
    assert strategyTokens2 == 100_000e8
    # Account gets their share of the residuals
    assert pytest.approx(accountAfter["tempCashBalance"], abs=100) == -500_000e8
    assert accountAfter2["tempCashBalance"] == 500_000e8

    assert vaultConfigAccount.getRemainingSettledTokens(vault.address, maturity) == (0, 0)
    assert vaultConfigAccount.getReserveBalance(1) == 50_000_000e8 - 500_000e8


def test_settle_insolvent_vault(vaultConfigAccount, accounts, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfigAccount.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000_000e8,
            totalStrategyTokens=0,
            totalAssetCash=49_500_000e8,
            totalfCash=-1_000_000e8,
        ),
    )
    vaultConfigAccount.setSettledVaultState(vault.address, maturity, maturity + 100)

    account = get_vault_account(maturity=maturity, fCash=-10_000e8, vaultShares=0)
    account2 = get_vault_account(maturity=maturity, fCash=-900_000e8, vaultShares=1_000_000e8)

    assert vaultConfigAccount.getRemainingSettledTokens(vault.address, maturity) == (0, -500_000e8)
    vaultConfigAccount.setReserveBalance(1, 50_000_000e8)

    txn1 = vaultConfigAccount.settleVaultAccount(vault.address, account, maturity + 100)
    (accountAfter, strategyTokens) = txn1.return_value

    txn2 = vaultConfigAccount.settleVaultAccount(vault.address, account2, maturity + 100)
    (accountAfter2, strategyTokens2) = txn2.return_value

    assert accountAfter["fCash"] == 0
    assert accountAfter["maturity"] == 0
    assert accountAfter["vaultShares"] == 0
    assert accountAfter2["fCash"] == 0
    assert accountAfter2["maturity"] == 0
    assert accountAfter2["vaultShares"] == 0

    # No strategy tokens remaining
    assert strategyTokens == 0
    assert strategyTokens2 == 0
    # Account gets their share of the residuals
    assert pytest.approx(accountAfter["tempCashBalance"], abs=100) == -500_000e8
    assert accountAfter2["tempCashBalance"] == 4_500_000e8

    assert vaultConfigAccount.getRemainingSettledTokens(vault.address, maturity) == (0, -500_000e8)
    assert vaultConfigAccount.getReserveBalance(1) == 50_000_000e8 - 4_500_000e8


def test_settle_with_secondary_borrow_currency(vaultConfigAccount, accounts, vault):
    vaultConfigAccount.setVaultConfig(
        vault.address, get_vault_config(secondaryBorrowCurrencies=[2, 0])
    )
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    vault.setExchangeRate(1e18)
    vaultConfigAccount.setVaultState(
        vault.address,
        get_vault_state(
            maturity=maturity,
            totalVaultShares=1_000e8,
            totalStrategyTokens=400e8,
            totalAssetCash=50_000e8,
            totalfCash=-1_000e8,
        ),
    )

    # Secondary borrow
    vaultConfigAccount.setSecondaryBorrows(vault.address, maturity, 2, 10_000e8, 1_000e8)
    daiRateOracle = MockAggregator.deploy(18, {"from": accounts[0]})
    daiRateOracle.setAnswer(0.01e18)
    vaultConfigAccount.setExchangeRate(2, [daiRateOracle, 18, False, 100, 100, 100])
    txn = vaultConfigAccount.snapshotSecondaryBorrowAtSettlement(vault.address, 2, maturity)
    assert txn.return_value == 100e8  # Total value of 100_000 dai borrowed in ETH

    vaultConfigAccount.setSecondaryBorrows(vault.address, maturity, 2, 0, 1_000e8)

    # Account 1 has fewer secondary debt shares than account 2, they both have the same
    # debt and the same vault shares
    vaultConfigAccount.setAccountDebtShares(vault.address, accounts[1], maturity, 200e8, 0)
    account1 = get_vault_account(
        maturity=maturity, fCash=-500e8, vaultShares=500e8, account=accounts[1].address
    )

    vaultConfigAccount.setAccountDebtShares(vault.address, accounts[2], maturity, 800e8, 0)
    account2 = get_vault_account(
        maturity=maturity, fCash=-500e8, vaultShares=500e8, account=accounts[2].address
    )

    vaultConfigAccount.setSettledVaultState(vault.address, maturity, maturity + 100)

    txn1 = vaultConfigAccount.settleVaultAccount(vault.address, account1, maturity + 100)
    (account1After, strategyTokens1) = txn1.return_value

    txn2 = vaultConfigAccount.settleVaultAccount(vault.address, account2, maturity + 100)
    (account2After, strategyTokens2) = txn2.return_value
    assert account1After["fCash"] == 0
    assert account1After["maturity"] == 0
    assert account1After["vaultShares"] == 0
    assert account2After["fCash"] == 0
    assert account2After["maturity"] == 0
    assert account2After["vaultShares"] == 0

    # Account gets their share of strategy tokens here, nothing else
    assert strategyTokens1 + strategyTokens2 <= 400e8
    assert pytest.approx(strategyTokens1 + strategyTokens2, abs=3) == 400e8
    assert strategyTokens2 == 170e8
    assert strategyTokens1 == 230e8

    (remainingStrategyTokens, remainingAssetCash) = vaultConfigAccount.getRemainingSettledTokens(
        vault.address, maturity
    )
    assert pytest.approx(remainingStrategyTokens, abs=5) == 0
    assert pytest.approx(remainingAssetCash, abs=5) == 0
    assert remainingStrategyTokens >= 0
    assert remainingAssetCash >= 0


def get_collateral_ratio(vaultConfigAccount, vault, **kwargs):
    vault.setExchangeRate(kwargs.get("exchangeRate", 1.2e18))

    account = get_vault_account(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        fCash=kwargs.get("fCash", -100_000e8),
        tempCashBalance=kwargs.get("tempCashBalance", 100e8),
        vaultShares=kwargs.get("accountVaultShares", 100_000e8),
    )

    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalAssetCash=kwargs.get("totalAssetCash", 100_000e8),
        totalVaultShares=kwargs.get("totalVaultShares", 100_000e8),
        totalStrategyTokens=kwargs.get("totalStrategyTokens", 100_000e8),
    )

    (collateralRatio, _) = vaultConfigAccount.calculateCollateralRatio(
        vault.address, account, state
    )
    return collateralRatio


def test_collateral_ratio_decreases_with_debt(vaultConfigAccount, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())

    fCash = 0
    decrement = -10_000e8
    lastCollateral = 2 ** 255
    for i in range(0, 20):
        ratio = get_collateral_ratio(vaultConfigAccount, vault, fCash=fCash)
        fCash += decrement
        assert ratio < lastCollateral
        lastCollateral = ratio


def test_collateral_ratio_increases_with_exchange_rate(vaultConfigAccount, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())

    exchangeRate = 1.2e28
    increment = 0.01e28
    lastCollateral = 0
    for i in range(0, 20):
        ratio = get_collateral_ratio(vaultConfigAccount, vault, exchangeRate=exchangeRate)
        exchangeRate += increment
        assert ratio > lastCollateral
        lastCollateral = ratio


def test_collateral_ratio_increases_with_vault_shares(vaultConfigAccount, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())

    vaultShares = 1000e8
    increment = 1000e8
    lastCollateral = 0
    for i in range(0, 20):
        ratio = get_collateral_ratio(
            vaultConfigAccount,
            vault,
            fCash=-100e8,
            accountVaultShares=vaultShares,
            totalAssetCash=0,
        )
        vaultShares += increment
        assert ratio > lastCollateral
        lastCollateral = ratio


def test_collateral_ratio_increases_with_vault_asset_cash(vaultConfigAccount, vault):
    vaultConfigAccount.setVaultConfig(vault.address, get_vault_config())

    assetCashHeld = 0
    increment = 10_000e8
    lastCollateral = 0
    for i in range(0, 20):
        ratio = get_collateral_ratio(vaultConfigAccount, vault, totalAssetCash=assetCashHeld)
        assetCashHeld += increment
        assert ratio > lastCollateral
        lastCollateral = ratio


@given(
    accountDebtSharesOne=strategy("uint", max_value=200_000e8),
    accountDebtSharesTwo=strategy("uint", max_value=200_000e8),
)
def test_collateral_ratio_with_secondary_debt_shares(
    vaultConfigAccount,
    vault,
    accounts,
    cToken,
    underlying,
    accountDebtSharesOne,
    accountDebtSharesTwo,
):
    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    aggregator = cTokenV2Aggregator.deploy(cToken.address, {"from": accounts[0]})
    vaultConfigAccount.setToken(
        2,
        aggregator.address,
        18,
        (cToken.address, False, TokenType["cToken"], 8, 0),
        (underlying.address, False, TokenType["UnderlyingToken"], 18, 0),
        accounts[8].address,
        {"from": accounts[0]},
    )

    vaultConfigAccount.setVaultConfig(
        vault.address, get_vault_config(currencyId=2, secondaryBorrowCurrencies=[3, 4])
    )
    vaultConfigAccount.setSecondaryBorrows(vault.address, maturity, 3, 100_000e8, 200_000e8)

    vaultConfigAccount.setSecondaryBorrows(vault.address, maturity, 4, 1000e8, 200_000e8)

    daiRateOracle = MockAggregator.deploy(18, {"from": accounts[0]})
    daiRateOracle.setAnswer(0.01e18)
    vaultConfigAccount.setExchangeRate(2, [daiRateOracle, 18, False, 100, 100, 100])

    usdcRateOracle = MockAggregator.deploy(18, {"from": accounts[0]})
    usdcRateOracle.setAnswer(0.005e18)
    vaultConfigAccount.setExchangeRate(3, [usdcRateOracle, 18, False, 100, 100, 100])

    wbtcRateOracle = MockAggregator.deploy(18, {"from": accounts[0]})
    wbtcRateOracle.setAnswer(1e18)
    vaultConfigAccount.setExchangeRate(4, [wbtcRateOracle, 18, False, 100, 100, 100])

    ratio = get_collateral_ratio(vaultConfigAccount, vault, fCash=-100_000e8)
    vaultConfigAccount.setAccountDebtShares(
        vault.address, accounts[0], maturity, accountDebtSharesOne, accountDebtSharesTwo
    )

    # Borrowing 50_000e8 USDC at $0.50, equivalent to borrowing another 25_000e8 DAI
    fCashOffsetOne = accountDebtSharesOne * 100_000e8 / 200_000e8 * 0.5
    fCashOffsetTwo = accountDebtSharesTwo * 1000e8 / 200_000e8 * 100
    ratio2 = get_collateral_ratio(
        vaultConfigAccount, vault, fCash=-100_000e8 + fCashOffsetOne + fCashOffsetTwo
    )
    assert pytest.approx(ratio, abs=1) == ratio2

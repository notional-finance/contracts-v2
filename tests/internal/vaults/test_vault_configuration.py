import random

import brownie
import pytest
from brownie import MockERC20, SimpleStrategyVault
from brownie.convert.datatypes import Wei
from brownie.network import Chain
from brownie.test import given, strategy
from fixtures import *
from tests.constants import (
    BASIS_POINT,
    PRIME_CASH_VAULT_MATURITY,
    RATE_PRECISION,
    SECONDS_IN_QUARTER,
    START_TIME_TREF,
)

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_set_vault_config(vaultConfigTokenTransfer, accounts):
    with brownie.reverts():
        # Fails on liquidation ratio less than 100
        conf = get_vault_config()
        conf[5] = 99
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on reserve fee share over 100
        conf = get_vault_config()
        conf[6] = 102
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on min ratio above max deleverage ratio
        conf = get_vault_config()
        conf[8] = 1000
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on liquidation rate above min collateral ratio
        conf = get_vault_config()
        conf[5] = 120
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on required account collateral ratio below min collateral ratio
        conf = get_vault_config()
        conf[10] = 1000
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on required account collateral ratio uniset
        conf = get_vault_config()
        conf[10] = 0
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    conf = get_vault_config()
    vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    config = vaultConfigTokenTransfer.getVaultConfigView(accounts[0]).dict()
    assert config["vault"] == accounts[0].address
    assert config["flags"] == conf[0]
    assert config["borrowCurrencyId"] == conf[1]
    assert pytest.approx(config["minAccountBorrowSize"], rel=2e8) == conf[2] * 1e8
    assert config["minCollateralRatio"] == conf[3] * BASIS_POINT
    assert config["feeRate"] == conf[4] * 5 * BASIS_POINT
    assert config["liquidationRate"] == conf[5] * RATE_PRECISION / 100
    assert config["reserveFeeShare"] == conf[6]
    assert config["maxBorrowMarketIndex"] == conf[7]
    assert config["maxDeleverageCollateralRatio"] == conf[8] * BASIS_POINT


def test_cannot_change_borrow_currencies(vaultConfigTokenTransfer, accounts):
    conf = get_vault_config(secondaryBorrowCurrencies=[3, 0])
    vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        conf = get_vault_config(secondaryBorrowCurrencies=[3, 0])
        conf[1] = 2
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        conf = get_vault_config(secondaryBorrowCurrencies=[3, 0])
        conf[9] = [4, 0]
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    # Can add an additional secondary borrow
    conf = get_vault_config(secondaryBorrowCurrencies=[3, 0])
    conf[9] = [3, 2]
    vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Cannot change it once set
        conf = get_vault_config(secondaryBorrowCurrencies=[3, 0])
        conf[9] = [3, 5]
        vaultConfigTokenTransfer.setVaultConfig(accounts[0], conf)


def test_pause_and_enable_vault(vaultConfigTokenTransfer, accounts):
    vaultConfigTokenTransfer.setVaultConfig(accounts[0], get_vault_config())

    # Asserts are inside the method
    vaultConfigTokenTransfer.setVaultEnabledStatus(accounts[0], True)
    vaultConfigTokenTransfer.setVaultEnabledStatus(accounts[0], False)

    vaultConfigTokenTransfer.setVaultDeleverageStatus(accounts[0], True)
    vaultConfigTokenTransfer.setVaultDeleverageStatus(accounts[0], False)


def test_fcash_vault_fee_increases_with_debt(vaultConfigTokenTransfer, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigTokenTransfer.address, 1, {"from": accounts[0]}
    )
    vaultConfigTokenTransfer.setVaultConfig(vault.address, get_vault_config(currencyId=1))
    vaultConfigTokenTransfer.setVaultConfig(
        vault.address,
        get_vault_config(
            maxNTokenFeeRate5BPS=255,
            minCollateralRatioBPS=11000,
            maxDeleverageCollateralRatioBPS=12000,
        ),
    )

    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    txn = vaultConfigTokenTransfer.assessVaultFees(
        vault.address, get_vault_account(maturity=maturity), 0, maturity, START_TIME_TREF
    )
    (_, initTotalReserve, initNToken) = txn.return_value
    assert initTotalReserve == 0
    assert initNToken == 0

    cash = 0
    increment = 100e8
    lastTotalReserve = 0
    lastNTokenCashBalance = 0
    for i in range(0, 20):
        cash += increment
        txn = vaultConfigTokenTransfer.assessVaultFees(
            vault.address, get_vault_account(maturity=maturity), cash, maturity, START_TIME_TREF
        )

        (vaultAccount, totalReserve, nTokenCashBalance) = txn.return_value
        assert totalReserve > lastTotalReserve
        assert nTokenCashBalance > lastNTokenCashBalance
        assert (totalReserve - lastTotalReserve) + (
            nTokenCashBalance - lastNTokenCashBalance
        ) == -vaultAccount.dict()["tempCashBalance"]

        lastTotalReserve = totalReserve
        lastNTokenCashBalance = nTokenCashBalance


def test_fcash_vault_fee_increases_with_time_to_maturity(vaultConfigTokenTransfer, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigTokenTransfer.address, 1, {"from": accounts[0]}
    )
    vaultConfigTokenTransfer.setVaultConfig(vault.address, get_vault_config(currencyId=1))
    vaultConfigTokenTransfer.setVaultConfig(
        vault.address,
        get_vault_config(
            maxNTokenFeeRate5BPS=255,
            minCollateralRatioBPS=11000,
            maxDeleverageCollateralRatioBPS=12000,
        ),
    )

    maturity = START_TIME_TREF + SECONDS_IN_QUARTER
    txn = vaultConfigTokenTransfer.assessVaultFees(
        vault.address, get_vault_account(maturity=maturity), 0, maturity, START_TIME_TREF
    )
    (_, initTotalReserve, initNToken) = txn.return_value
    assert initTotalReserve == 0
    assert initNToken == 0

    timeToMaturity = 0
    increment = Wei(SECONDS_IN_QUARTER / 20)
    lastTotalReserve = 0
    lastNTokenCashBalance = 0
    for i in range(0, 20):
        timeToMaturity += increment
        txn = vaultConfigTokenTransfer.assessVaultFees(
            vault.address,
            get_vault_account(maturity=maturity),
            100_000e8,
            maturity,
            maturity - timeToMaturity,
        )

        (vaultAccount, totalReserve, nTokenCashBalance) = txn.return_value
        assert totalReserve > lastTotalReserve
        assert nTokenCashBalance > lastNTokenCashBalance
        assert (totalReserve - lastTotalReserve) + (
            nTokenCashBalance - lastNTokenCashBalance
        ) == -vaultAccount.dict()["tempCashBalance"]

        lastTotalReserve = totalReserve
        lastNTokenCashBalance = nTokenCashBalance


def test_pcash_vault_fee_increases_over_time(vaultConfigTokenTransfer, accounts):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigTokenTransfer.address, 1, {"from": accounts[0]}
    )
    vaultConfigTokenTransfer.setVaultConfig(vault.address, get_vault_config(currencyId=1))
    vaultConfigTokenTransfer.setVaultConfig(
        vault.address,
        get_vault_config(
            maxNTokenFeeRate5BPS=255,
            minCollateralRatioBPS=11000,
            maxDeleverageCollateralRatioBPS=12000,
        ),
    )

    txn = vaultConfigTokenTransfer.assessVaultFees(
        vault.address,
        get_vault_account(maturity=0, lastUpdateBlockTime=0),
        100_000e8,
        PRIME_CASH_VAULT_MATURITY,
        START_TIME_TREF,
    )
    # No fee assessed on initial entry
    (_, initTotalReserve, initNToken) = txn.return_value
    assert initTotalReserve == 0
    assert initNToken == 0

    blockTime = START_TIME_TREF
    increment = Wei(SECONDS_IN_QUARTER / 20)
    lastTotalReserve = 0
    lastNTokenCashBalance = 0
    for i in range(0, 20):
        blockTime += increment
        txn = vaultConfigTokenTransfer.assessVaultFees(
            vault.address,
            get_vault_account(
                maturity=PRIME_CASH_VAULT_MATURITY, lastUpdateBlockTime=START_TIME_TREF
            ),
            100_000e8,
            PRIME_CASH_VAULT_MATURITY,
            blockTime,
        )

        (vaultAccount, totalReserve, nTokenCashBalance) = txn.return_value
        assert totalReserve > lastTotalReserve
        assert nTokenCashBalance > lastNTokenCashBalance
        assert (totalReserve - lastTotalReserve) + (
            nTokenCashBalance - lastNTokenCashBalance
        ) == -vaultAccount.dict()["tempCashBalance"]

        lastTotalReserve = totalReserve
        lastNTokenCashBalance = nTokenCashBalance


def get_underlying_token(vaultConfigTokenTransfer, currencyId):
    token = vaultConfigTokenTransfer.getToken(currencyId)
    return MockERC20.at(token["tokenAddress"])


def test_reverts_on_token_with_transfer_fee(vaultConfigTokenTransfer, accounts, MockERC20):
    token = MockERC20.deploy("FEE", "FEE", 6, 0.01e18, {"from": accounts[0]})
    vaultConfigTokenTransfer.setToken(5, (token, True, TokenType["UnderlyingToken"], 18, 0))
    vault = SimpleStrategyVault.deploy(
        "TEST", vaultConfigTokenTransfer.address, 5, {"from": accounts[0]}
    )
    with brownie.reverts():
        vaultConfigTokenTransfer.setVaultConfig(vault.address, get_vault_config(currencyId=5))


def get_redeem_vault(currencyId, vaultConfigTokenTransfer, accounts):
    vault = SimpleStrategyVault.deploy(
        "TEST", vaultConfigTokenTransfer.address, currencyId, {"from": accounts[0]}
    )
    vaultConfigTokenTransfer.setVaultConfig(vault.address, get_vault_config(currencyId=currencyId))

    token = None
    # Put some tokens on the vault
    if currencyId == 1:
        accounts[0].transfer(vault.address, 100e18)
        balanceBefore = accounts[1].balance()
        decimals = 18
    else:
        token = get_underlying_token(vaultConfigTokenTransfer, currencyId)
        decimals = token.decimals()
        token.transfer(vault.address, 100 * (10 ** decimals), {"from": accounts[0]})
        balanceBefore = token.balanceOf(accounts[1])

    vault.setExchangeRate(2e18)

    return (vault, token, decimals, balanceBefore)

@given(currencyId=strategy("uint", min_value=1, max_value=4))
def test_redeem_sufficient_to_repay_debt(vaultConfigTokenTransfer, currencyId, accounts):
    (vault, token, decimals, balanceBefore) = get_redeem_vault(
        currencyId, vaultConfigTokenTransfer, accounts
    )

    (pr, factorsBefore) = vaultConfigTokenTransfer.buildPrimeRateView(currencyId, chain.time())
    
    # NOTE: because underlying to repay is converted to pCash here, the adjustment applied
    # may or no may not round to exactly to underlying to repay outside of a single txn context
    underlyingToRepay = -5e8
    pCashToRepay = vaultConfigTokenTransfer.convertFromUnderlying(pr, underlyingToRepay)
    vaultAccount = get_vault_account(
        maturity=1234, tempCashBalance=pCashToRepay, account=accounts[1].address
    )

    if currencyId == 1:
        mockBalanceBefore = vaultConfigTokenTransfer.balance()
    else:
        mockBalanceBefore = token.balanceOf(vaultConfigTokenTransfer)

    txn = vaultConfigTokenTransfer.redeemWithDebtRepayment(
        vaultAccount, vault.address, accounts[1], 5e8, "", {"from": accounts[1]}
    )

    (pr, factorsAfter) = vaultConfigTokenTransfer.buildPrimeRateView(currencyId, txn.timestamp)
    if decimals < 8:
        adjustment = 100
    elif decimals == 8:
        adjustment = 1
    else:
        adjustment = 1

    underlyingToRepayAdj = underlyingToRepay - adjustment
    pCashToRepayAdj = vaultConfigTokenTransfer.convertFromUnderlying(pr, underlyingToRepayAdj)
    assert (
        pytest.approx(factorsAfter["totalPrimeSupply"], abs=5000)
        == factorsBefore["totalPrimeSupply"] + -pCashToRepayAdj
    )
    assert (
        pytest.approx(factorsAfter["lastTotalUnderlyingValue"], adjustment)
        == factorsBefore["lastTotalUnderlyingValue"] + -underlyingToRepay
    )

    if currencyId == 1:
        balanceAfter = accounts[1].balance()
        assert balanceAfter - balanceBefore == 10e18 / 2 - 1e10
        assert vault.balance() == 90e18
        mockBalanceAfter = vaultConfigTokenTransfer.balance()
        assert mockBalanceAfter - mockBalanceBefore == Wei(10e18) / 2 + Wei(1e10)
    else:
        balanceAfter = token.balanceOf(accounts[1])
        if decimals < 8:
            adjustment = 1
        elif decimals == 8:
            adjustment = 1
        else:
            adjustment = 1e10
        assert (
            pytest.approx(balanceAfter - balanceBefore, abs=adjustment) == 10 * (10 ** decimals) / 2
        )
        assert token.balanceOf(vault.address) == 90 * (10 ** decimals)
        mockBalanceAfter = token.balanceOf(vaultConfigTokenTransfer)
        assert (
            pytest.approx(mockBalanceAfter - mockBalanceBefore, abs=adjustment)
            == 10 * (10 ** decimals) / 2
        )


@given(currencyId=strategy("uint", min_value=2, max_value=4))
def test_redeem_insufficient_to_repay_debt(vaultConfigTokenTransfer, accounts, currencyId):
    (vault, token, decimals, balanceBefore) = get_redeem_vault(
        currencyId, vaultConfigTokenTransfer, accounts
    )
    (pr, factorsBefore) = vaultConfigTokenTransfer.buildPrimeRateView(currencyId, chain.time())
    underlyingToRepay = -15e8
    pCashToRepay = vaultConfigTokenTransfer.convertFromUnderlying(pr, underlyingToRepay)

    vaultAccount = get_vault_account(
        maturity=1234, tempCashBalance=pCashToRepay, account=accounts[1].address
    )
    with brownie.reverts():
        # account[1] has insufficient balance to repay debt
        vaultConfigTokenTransfer.redeemWithDebtRepayment(
            vaultAccount,
            vault.address,
            accounts[1],
            5e8,
            "",
            {"from": accounts[1], "value": 1e18 if currencyId == 1 else 0},
        )

    if currencyId == 1:
        accounts[0].transfer(vaultConfigTokenTransfer, 5.1e18)
        mockBalanceBefore = vaultConfigTokenTransfer.balance()
    else:
        token.approve(vaultConfigTokenTransfer.address, 2 ** 255, {"from": accounts[1]})
        token.transfer(accounts[1], 100 * (10 ** decimals), {"from": accounts[0]})
        balanceBefore = token.balanceOf(accounts[1])
        mockBalanceBefore = token.balanceOf(vaultConfigTokenTransfer)

    txn = vaultConfigTokenTransfer.redeemWithDebtRepayment(
        vaultAccount, vault.address, accounts[1], 5e8, "", {"from": accounts[1], "value": 5.1e18}
    )

    (pr, factorsAfter) = vaultConfigTokenTransfer.buildPrimeRateView(currencyId, txn.timestamp)
    if decimals < 8:
        adjustment = 100
    elif decimals == 8:
        adjustment = 1
    else:
        adjustment = 1

    underlyingToRepayAdj = underlyingToRepay - adjustment
    pCashToRepayAdj = vaultConfigTokenTransfer.convertFromUnderlying(pr, underlyingToRepayAdj)
    assert (
        pytest.approx(factorsAfter["totalPrimeSupply"], abs=5000)
        == factorsBefore["totalPrimeSupply"] + -pCashToRepayAdj
    )
    assert (
        pytest.approx(factorsAfter["lastTotalUnderlyingValue"], adjustment)
        == factorsBefore["lastTotalUnderlyingValue"] + -underlyingToRepay
    )

    if currencyId == 1:
        mockBalanceAfter = vaultConfigTokenTransfer.balance()
        balanceAfter = accounts[1].balance()
        assert balanceBefore - balanceAfter == 10e18 / 2 + 1e10
        assert vault.balance() == 90e18
        assert mockBalanceAfter - mockBalanceBefore == 10e18 / 2 - 1e10
    else:
        balanceAfter = token.balanceOf(accounts[1])
        if decimals < 8:
            adjustment = 1
        elif decimals == 8:
            adjustment = 1
        else:
            adjustment = 1e10
        assert (
            pytest.approx(balanceBefore - balanceAfter, abs=adjustment * 3)
            == 10 * (10 ** decimals) / 2
        )
        assert token.balanceOf(vault.address) == 90 * (10 ** decimals)
        mockBalanceAfter = token.balanceOf(vaultConfigTokenTransfer)
        assert (
            pytest.approx(mockBalanceAfter - mockBalanceBefore, abs=adjustment)
            == -underlyingToRepayAdj * (10 ** decimals) / 1e8
        )


@given(currencyId=strategy("uint", min_value=1, max_value=4))
def test_deposit_for_roll_vault(
    vaultConfigTokenTransfer, currencyId, accounts
):
    vaultAccount = get_vault_account()
    (vault, token, decimals, _) = get_redeem_vault(currencyId, vaultConfigTokenTransfer, accounts)
    depositAmount = 100e8
    depositAmountExternal = 100 * 10 ** decimals

    if currencyId != 1:
        token.approve(vaultConfigTokenTransfer.address, 2 ** 255, {"from": accounts[0]})

    txn = vaultConfigTokenTransfer.depositForRollPosition(
        vault.address,
        vaultAccount,
        depositAmountExternal,
        {"from": accounts[0], "value": depositAmountExternal if currencyId == 1 else 0},
    )
    tempCashBalance = txn.return_value
    (pr, _) = vaultConfigTokenTransfer.buildPrimeRateView(currencyId, txn.timestamp)

    assert tempCashBalance == vaultConfigTokenTransfer.convertFromUnderlying(pr, depositAmount)

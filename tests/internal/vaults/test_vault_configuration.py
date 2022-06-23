import brownie
import pytest
from brownie import MockERC20
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from fixtures import *
from tests.constants import (
    BASIS_POINT,
    RATE_PRECISION,
    SECONDS_IN_QUARTER,
    SECONDS_IN_YEAR,
    START_TIME_TREF,
)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_set_vault_config(vaultConfig, accounts):
    with brownie.reverts():
        # Fails on liquidation ratio less than 100
        conf = get_vault_config()
        conf[5] = 99
        vaultConfig.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on reserve fee share over 100
        conf = get_vault_config()
        conf[6] = 102
        vaultConfig.setVaultConfig(accounts[0], conf)

    with brownie.reverts():
        # Fails on min ratio above max deleverage ratio
        conf = get_vault_config()
        conf[8] = 1000
        vaultConfig.setVaultConfig(accounts[0], conf)

    conf = get_vault_config()
    vaultConfig.setVaultConfig(accounts[0], conf)

    config = vaultConfig.getVaultConfigView(accounts[0]).dict()
    assert config["vault"] == accounts[0].address
    assert config["flags"] == conf[0]
    assert config["borrowCurrencyId"] == conf[1]
    assert config["minAccountBorrowSize"] == conf[2] * 1e8
    assert config["minCollateralRatio"] == conf[3] * BASIS_POINT
    assert config["feeRate"] == conf[4] * 5 * BASIS_POINT
    assert config["liquidationRate"] == conf[5] * RATE_PRECISION / 100
    assert config["reserveFeeShare"] == conf[6]
    assert config["maxBorrowMarketIndex"] == conf[7]
    assert config["maxDeleverageCollateralRatio"] == conf[8] * BASIS_POINT


def test_pause_and_enable_vault(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    # Asserts are inside the method
    vaultConfig.setVaultEnabledStatus(accounts[0], True)
    vaultConfig.setVaultEnabledStatus(accounts[0], False)


def test_vault_fee_increases_with_debt(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            maxNTokenFeeRate5BPS=255,
            minCollateralRatioBPS=11000,
            maxDeleverageCollateralRatioBPS=12000,
        ),
    )

    txn = vaultConfig.assessVaultFees(vault.address, get_vault_account(), 0, SECONDS_IN_QUARTER)
    (_, initTotalReserve, initNToken) = txn.return_value
    assert initTotalReserve == 0
    assert initNToken == 0

    fCash = 0
    decrement = 100e8
    lastTotalReserve = 0
    lastNTokenCashBalance = 0
    for i in range(0, 20):
        fCash -= decrement
        txn = vaultConfig.assessVaultFees(
            vault.address, get_vault_account(), fCash, SECONDS_IN_QUARTER
        )

        (vaultAccount, totalReserve, nTokenCashBalance) = txn.return_value
        assert totalReserve > lastTotalReserve
        assert nTokenCashBalance > lastNTokenCashBalance
        assert (totalReserve - lastTotalReserve) + (
            nTokenCashBalance - lastNTokenCashBalance
        ) == -vaultAccount.dict()["tempCashBalance"]

        lastTotalReserve = totalReserve
        lastNTokenCashBalance = nTokenCashBalance


def test_vault_fee_increases_with_time_to_maturity(vaultConfig, vault, accounts):
    vaultConfig.setVaultConfig(
        vault.address,
        get_vault_config(
            maxNTokenFeeRate5BPS=255,
            minCollateralRatioBPS=11000,
            maxDeleverageCollateralRatioBPS=12000,
        ),
    )

    txn = vaultConfig.assessVaultFees(vault.address, get_vault_account(), 0, SECONDS_IN_QUARTER)
    (_, initTotalReserve, initNToken) = txn.return_value
    assert initTotalReserve == 0
    assert initNToken == 0

    timeToMaturity = 0
    increment = Wei(SECONDS_IN_QUARTER / 20)
    lastTotalReserve = 0
    lastNTokenCashBalance = 0
    for i in range(0, 20):
        timeToMaturity += increment
        txn = vaultConfig.assessVaultFees(
            vault.address, get_vault_account(), -100_000e8, timeToMaturity
        )

        (vaultAccount, totalReserve, nTokenCashBalance) = txn.return_value
        assert totalReserve > lastTotalReserve
        assert nTokenCashBalance > lastNTokenCashBalance
        assert (totalReserve - lastTotalReserve) + (
            nTokenCashBalance - lastNTokenCashBalance
        ) == -vaultAccount.dict()["tempCashBalance"]

        lastTotalReserve = totalReserve
        lastNTokenCashBalance = nTokenCashBalance


def test_update_used_borrow_capacity_increases_with_borrowing(vaultConfig, vault):
    vaultConfig.setMaxBorrowCapacity(vault.address, 1, 100_000e8)

    runningTotal = 0
    for i in range(0, 5):
        fCash = 22_000e8
        runningTotal += fCash

        if runningTotal > 100_000e8:
            with brownie.reverts("Max Capacity"):
                vaultConfig.updateUsedBorrowCapacity(vault.address, 1, -fCash)
        else:
            assert (
                runningTotal
                == vaultConfig.updateUsedBorrowCapacity(vault.address, 1, -fCash).return_value
            )


def test_update_used_borrow_capacity_decreases_with_lending(vaultConfig, vault):
    vaultConfig.setMaxBorrowCapacity(vault.address, 1, 100_000e8)
    vaultConfig.updateUsedBorrowCapacity(vault.address, 1, -100_000e8)

    assert 90_000e8 == vaultConfig.updateUsedBorrowCapacity(vault.address, 1, 10_000e8).return_value

    vaultConfig.setMaxBorrowCapacity(vault.address, 1, 50_000e8)

    # Still allowed to decrease borrow capacity above max
    assert 80_000e8 == vaultConfig.updateUsedBorrowCapacity(vault.address, 1, 10_000e8).return_value

    with brownie.reverts("Max Capacity"):
        vaultConfig.updateUsedBorrowCapacity(vault.address, 1, -1)


def test_transfer_eth_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=1))
    balanceBefore = vault.balance()
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 10e18, {"value": 10e18, "from": accounts[0]}
    ).return_value
    balanceAfter = vault.balance()
    assert cTokenVaultConfig.balance() == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 10e18


def test_transfer_transfer_fee_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=3))
    token = MockERC20.at(cTokenVaultConfig.getUnderlyingToken(3))
    token.approve(cTokenVaultConfig.address, 2 ** 255, {"from": accounts[0]})
    balanceBefore = token.balanceOf(vault)
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 100e8, {"from": accounts[0]}
    ).return_value
    balanceAfter = token.balanceOf(vault)

    assert token.balanceOf(cTokenVaultConfig) == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 99e8


def test_transfer_dai_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=2))
    token = MockERC20.at(cTokenVaultConfig.getUnderlyingToken(2))
    token.approve(cTokenVaultConfig.address, 2 ** 255, {"from": accounts[0]})

    balanceBefore = token.balanceOf(vault)
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 100e18, {"from": accounts[0]}
    ).return_value
    balanceAfter = token.balanceOf(vault)

    assert token.balanceOf(cTokenVaultConfig) == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 100e18


def test_transfer_usdc_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=4))
    token = MockERC20.at(cTokenVaultConfig.getUnderlyingToken(4))
    token.approve(cTokenVaultConfig.address, 2 ** 255, {"from": accounts[0]})

    balanceBefore = token.balanceOf(vault)
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 100e6, {"from": accounts[0]}
    ).return_value
    balanceAfter = token.balanceOf(vault)

    assert token.balanceOf(cTokenVaultConfig) == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 100e6


def test_transfer_non_mintable_to_vault_direct(cTokenVaultConfig, vault, accounts):
    cTokenVaultConfig.setVaultConfig(vault.address, get_vault_config(currencyId=5))
    token = MockERC20.at(cTokenVaultConfig.getAssetToken(5))
    token.approve(cTokenVaultConfig.address, 2 ** 255, {"from": accounts[0]})

    balanceBefore = token.balanceOf(vault)
    transferAmount = cTokenVaultConfig.transferUnderlyingToVaultDirect(
        vault.address, accounts[0], 100e18, {"from": accounts[0]}
    ).return_value
    balanceAfter = token.balanceOf(vault)

    assert token.balanceOf(cTokenVaultConfig) == 0
    assert balanceAfter - balanceBefore == transferAmount
    assert transferAmount == 100e18


def test_redeem_no_debt_to_repay():
    pass


def test_redeem_sufficient_to_repay_debt():
    pass


def test_redeem_insufficient_to_repay_debt():
    pass


def test_redeem_insufficient_eth_to_repay_debt():
    pass


def test_redeem_insufficient_non_mintable_to_repay_debt():
    pass


def test_resolve_shortfall_with_reserve_sufficient():
    pass


def test_resolve_shortfall_with_reserve_insolvent():
    pass


# def test_deposit_and_redeem_ctoken(vaultConfig, vault, accounts, cToken, underlying):
#     vaultConfig.setVaultConfig(vault.address, get_vault_config())
#     vault.setExchangeRate(Wei(5e18))

#     cToken.transfer(vaultConfig.address, 100_000e8, {"from": accounts[0]})
#     balanceBefore = cToken.balanceOf(vaultConfig.address)
#     txn = vaultConfig.deposit(
#         vault.address, accounts[0], 100e8, START_TIME_TREF, "", {"from": accounts[0]}
#     )
#     balanceAfter = cToken.balanceOf(vaultConfig.address)

#     assert balanceBefore - balanceAfter == 100e8
#     assert cToken.balanceOf(vault.address) == 0
#     assert underlying.balanceOf(vault.address) == 2e18

#     txn = vaultConfig.redeem(
#         vault.address, accounts[0], 0.2e8, START_TIME_TREF, "", {"from": accounts[0]}
#     )
#     balanceAfterRedeem = cToken.balanceOf(vaultConfig.address)

#     assert cToken.balanceOf(vault.address) == 0
#     assert underlying.balanceOf(vault.address) == 1e18
#     assert balanceAfterRedeem - balanceAfter == txn.return_value


# # This would be useful for completeness but doesnt test any additional
# # behaviors
# # def test_deposit_and_redeem_atoken(vaultConfig, vault, accounts):
# #     pass

# @given(
#     currencyId=strategy("uint16", min_value=1, max_value=3),
#     tempCashBalance=strategy("uint88", min_value=100_000e8, max_value=100_000_000e8),
#     useUnderlying=strategy("bool"),
# )
# def test_transfer_cash_underlying_positive(
#     cTokenVaultConfig, accounts, currencyId, useUnderlying, tempCashBalance
# ):
#     account = get_vault_account(tempCashBalance=Wei(tempCashBalance))
#     (assetToken, underlyingToken, _, _) = cTokenVaultConfig.getCurrencyAndRates(currencyId)
#     cToken = MockCToken.at(assetToken["tokenAddress"])
#     cToken.transfer(cTokenVaultConfig.address, 125_000_000e8, {"from": accounts[0]})

#     if useUnderlying:
#         token = MockERC20.at(underlyingToken["tokenAddress"])
#         balanceBefore = token.balanceOf(accounts[0])
#         expectedBalanceChange = Wei((tempCashBalance * cToken.exchangeRateStored()) / 1e18)
#     else:
#         token = MockCToken.at(assetToken["tokenAddress"])
#         balanceBefore = token.balanceOf(accounts[0])
#         expectedBalanceChange = tempCashBalance

#     accountAfter = cTokenVaultConfig.transferTempCashBalance(
#         account, currencyId, useUnderlying
#     ).return_value
#     balanceAfter = token.balanceOf(accounts[0])

#     if useUnderlying and currencyId == 1:
#         assert pytest.approx(balanceAfter - balanceBefore, abs=1e11) == expectedBalanceChange
#     elif useUnderlying:
#         assert pytest.approx(balanceAfter - balanceBefore, abs=2) == expectedBalanceChange
#     else:
#         assert balanceAfter - balanceBefore == expectedBalanceChange

#     underlyingToken = MockERC20.at(underlyingToken["tokenAddress"])
#     assert underlyingToken.balanceOf(cTokenVaultConfig) == 0
#     assert accountAfter["tempCashBalance"] == 0


# @given(
#     currencyId=strategy("uint16", min_value=1, max_value=3),
#     tempCashBalance=strategy("uint88", min_value=100_000e8, max_value=100_000_000e8),
#     useUnderlying=strategy("bool"),
# )
# def test_transfer_cash_underlying_negative(
#     cTokenVaultConfig, accounts, currencyId, useUnderlying, tempCashBalance
# ):
#     account = get_vault_account(tempCashBalance=-Wei(tempCashBalance))
#     (assetToken, underlyingToken, _, _) = cTokenVaultConfig.getCurrencyAndRates(currencyId)

#     if useUnderlying:
#         token = MockERC20.at(underlyingToken["tokenAddress"])
#         token.approve(cTokenVaultConfig, 2 ** 255, {"from": accounts[0]})
#         balanceBefore = token.balanceOf(accounts[0])
#         cToken = MockCToken.at(assetToken["tokenAddress"])
#         expectedBalanceChange = Wei((tempCashBalance * cToken.exchangeRateStored()) / 1e18)
#     else:
#         token = MockCToken.at(assetToken["tokenAddress"])
#         token.approve(cTokenVaultConfig, 2 ** 255, {"from": accounts[0]})
#         balanceBefore = token.balanceOf(accounts[0])
#         expectedBalanceChange = tempCashBalance

#     accountAfter = cTokenVaultConfig.transferTempCashBalance(
#         account, currencyId, useUnderlying
#     ).return_value
#     balanceAfter = token.balanceOf(accounts[0])

#     if useUnderlying and currencyId == 1:
#         assert pytest.approx(balanceBefore - balanceAfter, abs=1e11) == expectedBalanceChange
#     elif useUnderlying:
#         assert pytest.approx(balanceBefore - balanceAfter, abs=2) == expectedBalanceChange
#     else:
#         assert balanceBefore - balanceAfter == expectedBalanceChange

#     underlyingToken = MockERC20.at(underlyingToken["tokenAddress"])
#     assert underlyingToken.balanceOf(cTokenVaultConfig) == 0
#     assert accountAfter["tempCashBalance"] == 0


# @given(
#     currencyId=strategy("uint16", min_value=1, max_value=3),
#     depositAmount=strategy("uint88", min_value=100_000, max_value=100_000_000),
#     useUnderlying=strategy("bool"),
# )
# def test_deposit_into_account(
#     cTokenVaultConfig, accounts, currencyId, useUnderlying, depositAmount
# ):
#     account = get_vault_account()
#     (assetToken, underlyingToken, _, _) = cTokenVaultConfig.getCurrencyAndRates(currencyId)

#     if useUnderlying:
#         token = MockERC20.at(underlyingToken["tokenAddress"])
#         token.approve(cTokenVaultConfig, 2 ** 255, {"from": accounts[0]})
#         balanceBefore = token.balanceOf(accounts[0])
#         cToken = MockCToken.at(assetToken["tokenAddress"])
#         depositAmount = depositAmount * (10 ** token.decimals())
#         expectedTempCash = Wei((depositAmount * 1e18) / cToken.exchangeRateStored())
#     else:
#         token = MockCToken.at(assetToken["tokenAddress"])
#         token.approve(cTokenVaultConfig, 2 ** 255, {"from": accounts[0]})
#         balanceBefore = token.balanceOf(accounts[0])
#         depositAmount = depositAmount * (10 ** token.decimals())
#         expectedTempCash = depositAmount

#     accountAfter = cTokenVaultConfig.depositIntoAccount(
#         account, accounts[0], currencyId, depositAmount, useUnderlying
#     ).return_value
#     balanceAfter = token.balanceOf(accounts[0])
#     assert balanceBefore - balanceAfter == depositAmount

#     underlyingToken = MockERC20.at(underlyingToken["tokenAddress"])
#     assert underlyingToken.balanceOf(cTokenVaultConfig) == 0
#     assert pytest.approx(accountAfter["tempCashBalance"], abs=100) == expectedTempCash


# # def test_deposit_aave_token_larger_decimals(vaultState):
# #     pass

# # def test_deposit_aave_token_smaller_decimals(vaultState):
# #     pass


# # def test_transfer_cash_aave_token_larger_decimals(vaultState):
# #     pass

# # def test_transfer_cash_aave_token_smaller_decimals(vaultState):
# #     pass

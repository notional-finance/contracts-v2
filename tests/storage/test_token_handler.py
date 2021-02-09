from itertools import product

import brownie
import pytest


@pytest.fixture(scope="module", autouse=True)
def tokenHandler(MockTokenHandler, accounts):
    return MockTokenHandler.deploy({"from": accounts[0]})


@pytest.mark.parametrize("decimals,fee", list(product([6, 8, 18], [0, 0.01e18])))
def test_token_handler(tokenHandler, MockERC20, accounts, decimals, fee):
    erc20 = MockERC20.deploy("test", "TEST", decimals, fee, {"from": accounts[0]})
    tokenHandler.setMaxCurrencyId(1)
    tokenHandler.setCurrencyMapping(1, (erc20.address, fee != 0, decimals, 0, 0))

    amount = 10 ** decimals
    feePaid = amount * fee / 1e18
    erc20.approve(tokenHandler.address, 1000e18, {"from": accounts[0]})

    # This is a deposit
    internalAmount = amount * 1e9 / amount
    txn = tokenHandler.transfer(1, accounts[0].address, internalAmount)

    # Fees are paid by the sender
    assert erc20.balanceOf(tokenHandler.address) == amount - feePaid
    assert txn.return_value == (amount - feePaid) * 1e9 / 10 ** decimals

    # This is a withdraw
    withdrawAmt = amount / 2
    withdrawFeePaid = withdrawAmt * fee / 1e18
    balanceBefore = erc20.balanceOf(tokenHandler.address)
    internalWithdrawAmount = withdrawAmt * 1e9 / amount
    txn = tokenHandler.transfer(1, accounts[0].address, -internalWithdrawAmount)

    assert erc20.balanceOf(tokenHandler.address) == balanceBefore - withdrawAmt
    assert txn.return_value == (withdrawAmt - withdrawFeePaid) * 1e9 / 10 ** decimals


@pytest.mark.parametrize("decimals,fee", list(product([6, 8, 18], [0, 0.01e18])))
def test_transfer_failures(tokenHandler, MockERC20, accounts, decimals, fee):
    erc20 = MockERC20.deploy("test", "TEST", decimals, fee, {"from": accounts[0]})
    tokenHandler.setMaxCurrencyId(1)
    tokenHandler.setCurrencyMapping(1, (erc20.address, fee != 0, decimals, 0, 0))

    amount = 10 ** decimals
    with brownie.reverts():
        # Reverts when account has no balance
        tokenHandler.transfer(1, accounts[1], amount)

    with brownie.reverts():
        # Reverts when contract has no balance
        tokenHandler.transfer(1, accounts[0], -amount)

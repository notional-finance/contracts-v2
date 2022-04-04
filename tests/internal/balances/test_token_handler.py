from itertools import product

import brownie
import pytest
from brownie.convert.datatypes import HexString, Wei
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment, TokenType


@pytest.mark.balances
class TestTokenHandler:
    @pytest.fixture(scope="module", autouse=True)
    def tokenHandler(self, MockTokenHandler, accounts):
        return MockTokenHandler.deploy({"from": accounts[0]})

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_cannot_set_eth_twice(self, tokenHandler, accounts, MockERC20):
        zeroAddress = HexString(0, "bytes20")
        tokenHandler.setCurrencyMapping(1, True, (zeroAddress, False, TokenType["Ether"], 18, 0))
        erc20 = MockERC20.deploy("Ether", "Ether", 18, 0, {"from": accounts[0]})

        with brownie.reverts("dev: ether can only be set once"):
            tokenHandler.setCurrencyMapping(
                2, True, (erc20.address, False, TokenType["Ether"], 18, 0)
            )

        with brownie.reverts("TH: address is zero"):
            tokenHandler.setCurrencyMapping(
                2, True, (zeroAddress, False, TokenType["UnderlyingToken"], 18, 0)
            )

    def test_cannot_override_token(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})
        erc20_ = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})
        tokenHandler.setCurrencyMapping(
            2, True, (erc20.address, False, TokenType["UnderlyingToken"], 18, 0)
        )

        with brownie.reverts("TH: token cannot be reset"):
            tokenHandler.setCurrencyMapping(
                2, True, (erc20_.address, False, TokenType["UnderlyingToken"], 18, 0)
            )

    def test_cannot_set_asset_to_underlying(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})

        with brownie.reverts("dev: underlying token inconsistent"):
            tokenHandler.setCurrencyMapping(
                2, True, (erc20.address, False, TokenType["cToken"], 18, 0)
            )

    def test_cannot_set_underlying_to_asset(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})

        with brownie.reverts("dev: underlying token inconsistent"):
            tokenHandler.setCurrencyMapping(
                2, False, (erc20.address, False, TokenType["UnderlyingToken"], 18, 0)
            )

    def test_cannot_set_max_collateral_on_underlying(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})

        with brownie.reverts("dev: underlying cannot have max collateral balance"):
            tokenHandler.setCurrencyMapping(
                2, True, (erc20.address, False, TokenType["UnderlyingToken"], 18, 100_000e8)
            )

    def test_set_max_collateral_balance(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})
        tokenHandler.setCurrencyMapping(
            2, False, (erc20.address, False, TokenType["NonMintable"], 18, 100_000e8)
        )

        token1 = tokenHandler.getToken(2, False)
        assert token1[4] == 100_000e8

        tokenHandler.setMaxCollateralBalance(2, 250_000e8)
        token2 = tokenHandler.getToken(2, False)
        # Assert no other values are overwritten
        assert token1[0] == token2[0]
        assert token1[1] == token2[1]
        assert token1[2] == token2[2]
        assert token1[3] == token2[3]
        assert token2[4] == 250_000e8

    def test_deposit_respects_max_collateral_balance(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})
        tokenHandler.setCurrencyMapping(
            2, False, (erc20.address, False, TokenType["NonMintable"], 18, 100_000e8)
        )

        # This will succeed (transfer is denominated in external precision)
        erc20.approve(tokenHandler.address, 2 ** 255, {"from": accounts[0]})
        tokenHandler.transfer(2, accounts[0], False, Wei(100_000e18))
        assert erc20.balanceOf(tokenHandler) == Wei(100_000e18)

        with brownie.reverts("dev: over max collateral balance"):
            tokenHandler.transfer(2, accounts[0], False, 1e18)

    def test_can_withdraw_even_over_max_collateral(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})
        tokenHandler.setCurrencyMapping(
            2, False, (erc20.address, False, TokenType["NonMintable"], 18, 100_000e8)
        )

        # This will succeed (transfer is denominated in external precision)
        erc20.approve(tokenHandler.address, 2 ** 255, {"from": accounts[0]})
        tokenHandler.transfer(2, accounts[0], False, Wei(60_000e18))

        # Reduce collateral balance
        tokenHandler.setMaxCollateralBalance(2, 50_000e8)

        # Assert that you still cannot deposit
        with brownie.reverts("dev: over max collateral balance"):
            tokenHandler.transfer(2, accounts[0], False, 1e18)

        # Assert that you can withdraw, even over the collateral balance
        tokenHandler.transfer(2, accounts[0], False, -50_000e18)

        # Assert that you can now deposit again
        tokenHandler.transfer(2, accounts[0], False, 10_000e18)

    def test_token_returns_false(self, tokenHandler, MockERC20, accounts):
        decimals = 18
        fee = 0
        erc20 = MockERC20.deploy("test", "TEST", decimals, fee, {"from": accounts[0]})
        tokenHandler.setMaxCurrencyId(1)
        tokenHandler.setCurrencyMapping(
            1, True, (erc20.address, fee, TokenType["UnderlyingToken"], decimals, 0)
        )

        erc20.approve(tokenHandler.address, 1000e18, {"from": accounts[0]})
        # Deposit a bit for the withdraw
        tokenHandler.transfer(1, accounts[0].address, True, 100)

        erc20.setTransferReturnValue(False)
        with brownie.reverts():
            tokenHandler.transfer(1, accounts[0].address, True, 100)
            tokenHandler.transfer(1, accounts[0].address, True, -100)

    @pytest.mark.only
    def test_non_compliant_token_approval(
        self, tokenHandler, MockERC20, MockNonCompliantERC20, accounts
    ):
        decimals = 18
        fee = 0
        underlying = MockNonCompliantERC20.deploy(
            "test", "TEST", decimals, fee, {"from": accounts[0]}
        )
        cToken = MockERC20.deploy("cToken", "cTEST", 8, fee, {"from": accounts[0]})

        tokenHandler.setMaxCurrencyId(1)
        tokenHandler.setCurrencyMapping(
            1, True, (underlying.address, False, TokenType["UnderlyingToken"], decimals, 0)
        )
        tokenHandler.setCurrencyMapping(
            1, False, (cToken.address, False, TokenType["cToken"], 8, 0)
        )

        assert underlying.allowance(tokenHandler.address, cToken.address) == Wei(2 ** 256) - 1

    def test_non_compliant_token(self, tokenHandler, MockNonCompliantERC20, accounts):
        decimals = 18
        fee = 0
        erc20 = MockNonCompliantERC20.deploy("test", "TEST", decimals, fee, {"from": accounts[0]})
        tokenHandler.setMaxCurrencyId(1)
        tokenHandler.setCurrencyMapping(
            1, True, (erc20.address, fee, TokenType["UnderlyingToken"], decimals, 0)
        )

        amount = 10 ** decimals
        feePaid = amount * fee / 1e18
        erc20.approve(tokenHandler.address, 1000e18, {"from": accounts[0]})

        # This is a deposit
        txn = tokenHandler.transfer(1, accounts[0].address, True, amount)

        # Fees are paid by the sender
        assert erc20.balanceOf(tokenHandler.address) == amount - feePaid
        assert txn.return_value == (amount - feePaid)

        # This is a withdraw
        withdrawAmt = amount / 2
        balanceBefore = erc20.balanceOf(tokenHandler.address)
        txn = tokenHandler.transfer(1, accounts[0].address, True, -withdrawAmt)

        assert erc20.balanceOf(tokenHandler.address) == balanceBefore - withdrawAmt
        assert txn.return_value == -int(withdrawAmt)

    @pytest.mark.parametrize("decimals,fee", list(product([6, 8, 18], [0, 0.01e18])))
    def test_token_transfers(self, tokenHandler, MockERC20, accounts, decimals, fee):
        erc20 = MockERC20.deploy("test", "TEST", decimals, fee, {"from": accounts[0]})
        tokenHandler.setMaxCurrencyId(1)
        tokenHandler.setCurrencyMapping(
            1, False, (erc20.address, fee != 0, TokenType["NonMintable"], decimals, 0)
        )

        amount = 10 ** decimals
        feePaid = amount * fee / 1e18
        erc20.approve(tokenHandler.address, 1000e18, {"from": accounts[0]})

        # This is a deposit
        txn = tokenHandler.transfer(1, accounts[0].address, False, amount)

        # Fees are paid by the sender
        assert erc20.balanceOf(tokenHandler.address) == amount - feePaid
        assert txn.return_value == (amount - feePaid)

        # This is a withdraw
        withdrawAmt = amount / 2
        balanceBefore = erc20.balanceOf(tokenHandler.address)
        txn = tokenHandler.transfer(1, accounts[0].address, False, -withdrawAmt)

        assert erc20.balanceOf(tokenHandler.address) == balanceBefore - withdrawAmt
        assert txn.return_value == -int(withdrawAmt)

    @pytest.mark.parametrize("decimals,fee", list(product([6, 8, 18], [0, 0.01e18])))
    def test_transfer_failures(self, tokenHandler, MockERC20, accounts, decimals, fee):
        erc20 = MockERC20.deploy("test", "TEST", decimals, fee, {"from": accounts[0]})
        tokenHandler.setMaxCurrencyId(1)
        tokenHandler.setCurrencyMapping(
            1, True, (erc20.address, fee != 0, TokenType["UnderlyingToken"], decimals, 0)
        )

        amount = 10 ** decimals
        with brownie.reverts():
            # Reverts when account has no balance
            tokenHandler.transfer(1, accounts[1], True, amount)

        with brownie.reverts():
            # Reverts when contract has no balance
            tokenHandler.transfer(1, accounts[0], True, -amount)

    def test_ctoken_mint_redeem(self, tokenHandler, accounts):
        env = TestEnvironment(accounts[0])
        env.enableCurrency("DAI", CurrencyDefaults)

        tokenHandler.setCurrencyMapping(
            2, True, (env.token["DAI"].address, False, TokenType["UnderlyingToken"], 18, 0)
        )
        tokenHandler.setCurrencyMapping(
            2, False, (env.cToken["DAI"].address, False, TokenType["cToken"], 8, 0)
        )

        # Test minting of cDai, first transfer some balance to the tokenHandler
        depositedDai = 1000e18
        cDaiBalanceBefore = env.cToken["DAI"].balanceOf(tokenHandler.address)
        env.token["DAI"].transfer(tokenHandler.address, depositedDai)
        txn = tokenHandler.mint(2, 1000e18)
        mintedcTokens = txn.return_value
        cDaiBalanceAfter = env.cToken["DAI"].balanceOf(tokenHandler.address)
        assert cDaiBalanceAfter - cDaiBalanceBefore == mintedcTokens

        txn = tokenHandler.redeem(2, mintedcTokens)
        redeemedDai = txn.return_value
        assert -redeemedDai >= depositedDai
        assert env.cToken["DAI"].balanceOf(tokenHandler.address) == 0

    def test_ceth_mint_redeem(self, tokenHandler, accounts):
        env = TestEnvironment(accounts[0])

        tokenHandler.setCurrencyMapping(
            1, False, (env.cToken["ETH"].address, False, TokenType["cETH"], 8, 0)
        )

        sentETH = 100e18
        cETHBalanceBefore = env.cToken["ETH"].balanceOf(tokenHandler.address)
        txn = tokenHandler.mint(1, sentETH, {"value": sentETH})
        mintedcTokens = txn.return_value
        cETHBalanceAfter = env.cToken["ETH"].balanceOf(tokenHandler.address)
        assert cETHBalanceAfter - cETHBalanceBefore == mintedcTokens

        txn = tokenHandler.redeem(1, mintedcTokens)
        redeemedETH = txn.return_value
        assert -redeemedETH >= sentETH
        assert env.cToken["ETH"].balanceOf(tokenHandler.address) == 0

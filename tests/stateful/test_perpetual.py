import math
import random

import brownie
from brownie.test import strategy
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment
from tests.stateful.invariants import check_system_invariants


class PerpetualTokenStateMachine:

    amountToDeposit = strategy("uint88", min_value=1e9, max_value=100000e9)
    provider = strategy("address")

    def __init__(cls, accounts, envConfig):
        cls.deployer = accounts[0]
        cls.currencySymbol = "DAI"
        cls.env = TestEnvironment(cls.deployer)
        cls.env.enableCurrency(cls.currencySymbol, envConfig)
        cls.accounts = accounts

        # Transfer initial cToken balances to providers
        token = cls.env.token[cls.currencySymbol]
        cToken = cls.env.cToken[cls.currencySymbol]

        for p in accounts:
            decimals = token.decimals()
            if p != accounts[0]:
                # Transfer 10 million to the provider if it is not the deployer
                token.transfer(p.address, 10000000 * (10 ** decimals))
            token.approve(cToken.address, 2 ** 255, {"from": p})

            # Deposit into cTokens, TODO: need to have a way to auto wrap these
            # MintAmount is denominted in underlying
            cToken.mint(10000000 * (10 ** decimals), {"from": p})
            cToken.approve(cls.env.proxy.address, 2 ** 255, {"from": p})

    def setup(self):
        # This is called after the snapshot is reverted to the state at the end of __init__
        # Keep an internal counter of the amount deposited
        self.deposits = {x: 0 for x in self.accounts}

        # TODO: set the time of the environment to one of three different states:
        # - pre initialization
        # - post initialization
        # - post market settlement, pre initialization

    def rule_mint_tokens(self, provider, amountToDeposit):
        # Get the balances before we deposit
        (cashBalance, perpTokenBalance, capitalDeposited) = self.env.router[
            "Views"
        ].getAccountBalance(self.env.currencyId[self.currencySymbol], provider.address)
        tokenBalance = self.env.cToken[self.currencySymbol].balanceOf(provider.address)

        if cashBalance + tokenBalance < amountToDeposit:
            # Should revert with a transfer error
            with brownie.reverts():
                self.router["MintPerpetual"].perpetualTokenMint(
                    self.env.currencyId[self.currencySymbol],
                    amountToDeposit,
                    True,  # Use cash balance here
                    {"from": provider},
                )

        # Ensure that the tokens to mint matches what we actually mint
        tokensToMint = self.env.router["MintPerpetual"].calculatePerpetualTokensToMint(
            self.env.currencyId[self.currencySymbol], amountToDeposit, {"from": provider}
        )

        useCashBalance = random.randint(0, 1)
        self.env.router["MintPerpetual"].perpetualTokenMint(
            self.env.currencyId[self.currencySymbol],
            amountToDeposit,
            useCashBalance,  # If true, this will trigger an FC check
            {"from": provider},
        )

        (cashBalanceAfter, perpTokenBalanceAfter, capitalDepositedAfter) = self.env.router[
            "Views"
        ].getAccountBalance(self.env.currencyId[self.currencySymbol], provider.address)
        tokenBalanceAfter = self.env.cToken[self.currencySymbol].balanceOf(provider.address)

        # Asserts that account has had its debits done properly
        assert perpTokenBalanceAfter - perpTokenBalance == tokensToMint
        assert capitalDepositedAfter - capitalDeposited == amountToDeposit

        # cTokens are 8 decimals
        tokenBalanceDiffInInternal = math.trunc((tokenBalance - tokenBalanceAfter) * 1e9 / 1e8)
        if useCashBalance:
            assert (cashBalanceAfter - cashBalance) + tokenBalanceDiffInInternal == amountToDeposit
        else:
            assert tokenBalanceDiffInInternal == amountToDeposit

        # TODO: what assertions do we need to make about the perpetual token account?
        # - check leverage thresholds
        # - check PV increase
        # - check deposit shares

    # def rule_mint_tokens_for():
    # this is essentially the same test as above
    #     pass

    # def rule_redeem_tokens():
    #     pass

    # def rule_transfer_tokens():
    # check that transfer is ok and check that capital deposited has changed
    #     pass

    def invariant(self):
        check_system_invariants(self.env, self.accounts)


def test_perpetual(state_machine, accounts):
    daiConfig = {**CurrencyDefaults, "maxMarketIndex": 2}

    state_machine(PerpetualTokenStateMachine, accounts, daiConfig)

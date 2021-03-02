from scripts.deployment import TestEnvironment
from tests.stateful.invariants import check_system_invariants


class BaseStateMachine:
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
        # TODO: set the state of the environment to one of three different states:
        # - pre initialization
        # - post initialization
        # - post market settlement, pre initialization
        pass

    def invariant(self):
        check_system_invariants(self.env, self.accounts)

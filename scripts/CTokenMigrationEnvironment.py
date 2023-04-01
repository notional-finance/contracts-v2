from brownie import accounts, interface, Contract, ncToken, nProxy, MigrateCTokens

class cTokenMigrationEnvironment:
    def __init__(self, deployer) -> None:
        self.deployer = deployer
        self.whales = {}
        self.whales["ETH"] = accounts.at("0x1b3cb81e51011b549d78bf720b0d924ac763a7c2", force=True)
        self.whales["DAI"] = accounts.at("0x604981db0C06Ea1b37495265EDa4619c8Eb95A3D", force=True)
        self.whales["USDC"] = accounts.at("0x0a59649758aa4d66e25f08dd01271e891fe52199", force=True)
        self.whales["WBTC"] = accounts.at("0x6dab3bcbfb336b29d06b9c793aef7eaa57888922", force=True)
        self.notional = interface.NotionalProxy("0x1344A36A1B56144C3Bc62E7757377D288fDE0369")

    def deployNCTokens(self):
        self.ncETH = self.deployNCToken(
            "0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5",
            True
        )
        self.ncDAI = self.deployNCToken(
            "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643",
            False
        )
        self.ncUSDC = self.deployNCToken(
            "0x39AA39c021dfbaE8faC545936693aC917d5E7563",
            False
        )
        self.ncWBTC = self.deployNCToken(
            "0xccF4429DB6322D5C611ee964527D42E5d685DD6a",
            False
        )
        self.ncTokens = {}
        self.ncTokens[1] = self.ncETH
        self.ncTokens[2] = self.ncDAI
        self.ncTokens[3] = self.ncUSDC
        self.ncTokens[4] = self.ncWBTC

    def migrate(self, currencyId):
        patch = MigrateCTokens.deploy(
            self.notional.getImplementation(),
            self.notional.getImplementation(),
            self.notional,
            currencyId,
            self.ncTokens[currencyId],
            {"from": self.deployer}
        )
        self.notional.transferOwnership(patch, False, {"from": self.notional.owner()})
        patch.atomicPatchAndUpgrade({"from": self.notional.owner()})

    def deployNCToken(self, cToken, isETH):
        impl = ncToken.deploy(self.notional.address, cToken, isETH, {"from": self.deployer})
        proxy = nProxy.deploy(impl, bytes(), {"from": self.notional.owner()})
        return Contract.from_abi("ncToken", proxy.address, ncToken.abi)


def main():
    deployer = accounts.at("0xE6FB62c2218fd9e3c948f0549A2959B509a293C8", force=True)
    env = cTokenMigrationEnvironment(deployer)
    env.deployNCTokens()
    env.migrate(1)
    env.migrate(2)
    env.migrate(3)
    env.migrate(4)

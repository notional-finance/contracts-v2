from brownie import accounts, interface, Contract, ncToken, nProxy, MigrateCTokens

class cTokenMigrationEnvironment:
    def __init__(self, deployer) -> None:
        self.deployer = deployer
        self.notional = interface.NotionalProxy("0x1344A36A1B56144C3Bc62E7757377D288fDE0369")
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
        self.patchFixETH = MigrateCTokens.deploy(
            self.notional.getImplementation(),
            self.notional.getImplementation(),
            self.notional,
            1,
            self.ncETH,
            {"from": self.deployer}
        )
        self.patchFixDAI = MigrateCTokens.deploy(
            self.notional.getImplementation(),
            self.notional.getImplementation(),
            self.notional,
            2,
            self.ncDAI,
            {"from": self.deployer}
        )
        self.patchFixUSDC = MigrateCTokens.deploy(
            self.notional.getImplementation(),
            self.notional.getImplementation(),
            self.notional,
            3,
            self.ncUSDC,
            {"from": self.deployer}
        )
        self.patchFixWBTC = MigrateCTokens.deploy(
            self.notional.getImplementation(),
            self.notional.getImplementation(),
            self.notional,
            4,
            self.ncWBTC,
            {"from": self.deployer}
        )
        self.migrate()

    def migrate(self):
        self.notional.transferOwnership(self.patchFixETH, False, {"from": self.notional.owner()})
        self.patchFixETH.atomicPatchAndUpgrade({"from": self.notional.owner()})
        self.notional.transferOwnership(self.patchFixDAI, False, {"from": self.notional.owner()})
        self.patchFixDAI.atomicPatchAndUpgrade({"from": self.notional.owner()})
        self.notional.transferOwnership(self.patchFixUSDC, False, {"from": self.notional.owner()})
        self.patchFixUSDC.atomicPatchAndUpgrade({"from": self.notional.owner()})
        self.notional.transferOwnership(self.patchFixWBTC, False, {"from": self.notional.owner()})
        self.patchFixWBTC.atomicPatchAndUpgrade({"from": self.notional.owner()})

    def deployNCToken(self, cToken, isETH):
        impl = ncToken.deploy(self.notional.address, cToken, isETH, {"from": self.deployer})
        proxy = nProxy.deploy(impl, bytes(), {"from": self.notional.owner()})
        return Contract.from_abi("ncToken", proxy.address, ncToken.abi)


def main():
    deployer = accounts.at("0xE6FB62c2218fd9e3c948f0549A2959B509a293C8", force=True)
    env = cTokenMigrationEnvironment(deployer)
    ethWhale = accounts.at("0x1b3cb81e51011b549d78bf720b0d924ac763a7c2", force=True)
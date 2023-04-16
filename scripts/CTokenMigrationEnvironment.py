from brownie import accounts, interface, Contract, nwToken, nProxy, MigrateCTokens
from brownie.network import Chain
chain = Chain()

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
        # self.ncETH = self.deployNCToken(
        #     "0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5",
        #     True
        # )
            
        # self.deployNCToken(
        #     "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643",
        #     False
        # )

        # self.ncUSDC = self.ncUSDC = self.deployNCToken(
        #     "0x39AA39c021dfbaE8faC545936693aC917d5E7563",
        #     False
        # )
        # self.ncWBTC = self.deployNCToken(
        #     "0xccF4429DB6322D5C611ee964527D42E5d685DD6a",
        #     False
        # )
        self.ncTokens = {}
        self.ncTokens[1] = Contract.from_abi('nwETH', "0xaaC5145f5286a3C6a06256fdfBf5b499aA965C9C", nwToken.abi)
        self.ncTokens[2] = Contract.from_abi('nwDAI', "0xDBBB034A50C436359fb6D87D3D669647E0FA24D5", nwToken.abi)
        self.ncTokens[3] = Contract.from_abi('nwUSDC', "0xc91864Be1b097c9c85565cDB013Ba2307FFB492a", nwToken.abi)
        self.ncTokens[4] = Contract.from_abi('nwWBTC', "0x0F12B85A331aCb515e1626F707aadE62E9960187", nwToken.abi)

    def migrateAll(self, migrateFromPaused=True):
        chain.snapshot()
        # patch = MigrateCTokens.deploy(
        #     "0xC2c594f0bb455637a93345A17f841DAC750ccF54", # Current Implementation
        #     "0x5030D70175e27e46216Ee48972bC8E2db12bBA6D", # Paused Router
        #     self.notional,
        #     self.ncTokens[1],
        #     self.ncTokens[2],
        #     self.ncTokens[3],
        #     self.ncTokens[4],
        #     {"from": self.deployer}
        # )
        patch = MigrateCTokens.at("0x02551ded3F5B25f60Ea67f258D907eD051E042b2")
        self.notional.transferOwnership(patch, False, {"from": self.notional.owner()})
        patch.atomicPatchAndUpgrade({"from": self.notional.owner()})

        if migrateFromPaused:
            self.notional.upgradeTo("0x0158fC072Ff5DDE8F7b9E2D00e8782093db888Db", {"from": self.notional.owner()})

    def deployNCToken(self, cToken, isETH):
        impl = nwToken.deploy(self.notional.address, cToken, isETH, {"from": self.deployer})
        proxy = nProxy.deploy(impl, bytes(), {"from": self.deployer})
        return Contract.from_abi("nwToken", proxy.address, nwToken.abi)


def main():
    deployer = accounts.at("0xE6FB62c2218fd9e3c948f0549A2959B509a293C8", force=True)
    env = cTokenMigrationEnvironment(deployer)
    env.deployNCTokens()
    env.migrate(1)
    env.migrate(2)
    env.migrate(3)
    env.migrate(4)

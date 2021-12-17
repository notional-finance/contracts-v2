import json
from brownie import (
    TreasuryAction,
    Router,
    Views,
    FreeCollateralExternal,
    SettleAssetsExternal,
    TradingAction,
    nTokenMintAction
)
from brownie import Contract, accounts, interface

EnvironmentConfig = {
    "cDAI": '0x5d3a536e4d6dbd6114cc1ead35777bab948e3643',
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "cETH": "0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5",
    "COMP": "0xc00e94cb662c3520282e6f5717214004a7f26888",
    "Notional": "0x1344a36a1b56144c3bc62e7757377d288fde0369",
    "Comptroller": "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b"
}

class TestAccounts:
    def __init__(self) -> None:
        self.COMPWhale = accounts.at('0x7587cAefc8096f5F40ACB83A09Df031a018C66ec', force=True)

class TreasuryEnvironment:
    def __init__(self, config) -> None:
        self.config = config
        self.comptroller = "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b"
        self.notional = "0x1344a36a1b56144c3bc62e7757377d288fde0369"
        self.deployer = accounts.at("0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef", force=True)
        # Libraries
        self.settleAssetsExternal = SettleAssetsExternal.deploy({"from": self.deployer})
        self.freeCollateralExternal = FreeCollateralExternal.deploy({"from": self.deployer})
        self.tradingAction = TradingAction.deploy({"from": self.deployer})
        self.nTokenMintAction = nTokenMintAction.deploy({"from": self.deployer})
        treasury = TreasuryAction.deploy(
            config["Comptroller"], 
            config["WETH"], 
            { "from": self.deployer}
        )
        views = Views.deploy(
            { "from": self.deployer }
        )
        self.router = Router.at(config["Notional"])
        self.router = Router.deploy(
            self.router.GOVERNANCE(),
            views.address,
            self.router.INITIALIZE_MARKET(),
            self.router.NTOKEN_ACTIONS(),
            self.router.NTOKEN_REDEEM(),
            self.router.BATCH_ACTION(),
            self.router.ACCOUNT_ACTION(),
            self.router.ERC1155(),
            self.router.LIQUIDATE_CURRENCY(),
            self.router.LIQUIDATE_FCASH(),
            self.router.cETH(),
            treasury.address,
            { "from": self.deployer}
        )
        self.proxy = interface.NotionalProxy(config["Notional"])
        self.proxy.upgradeTo(self.router.address, {"from": self.proxy.owner()})
        self.treasury = interface.NotionalTreasury(self.proxy.address)
        self.COMPToken = self.loadERC20Token("COMP")
        self.DAIToken = self.loadERC20Token("DAI")
        self.cDAIToken = self.loadERC20Token("cDAI")
        self.WETHToken = self.loadERC20Token("WETH")
        self.cETHToken = self.loadERC20Token("cETH")

    def loadERC20Token(self, token):
        with open("./abi/ERC20.json", "r") as f:
            abi = json.load(f)
        return Contract.from_abi(token, EnvironmentConfig[token], abi)

def create_environment():
    return TreasuryEnvironment(EnvironmentConfig)

def main():
    env = create_environment()
    testAccounts = TestAccounts()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})

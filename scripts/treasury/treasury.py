import json
from brownie import (
    TreasuryAction,
    Router
)
from brownie import Contract, accounts, interface

EnvironmentConfig = {
    "cDAI": '0x5d3a536e4d6dbd6114cc1ead35777bab948e3643',
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "COMP": "0xc00e94cb662c3520282e6f5717214004a7f26888",
    "Notional": "0x1344a36a1b56144c3bc62e7757377d288fde0369",
    "Comptroller": "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b"
}

class TreasuryEnvironment:
    def __init__(self, config) -> None:
        self.config = config
        self.comptroller = "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b"
        self.notional = "0x1344a36a1b56144c3bc62e7757377d288fde0369"
        self.deployer = accounts.at("0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef", force=True)
        treasury = TreasuryAction.deploy(
            config["COMP"], 
            config["Comptroller"], 
            config["WETH"], 
            { "from": self.deployer}
        )
        oldRouter = Router.at(config["Notional"])
        self.router = Router.deploy(
            oldRouter.GOVERNANCE(),
            oldRouter.VIEWS(),
            oldRouter.INITIALIZE_MARKET(),
            oldRouter.NTOKEN_ACTIONS(),
            oldRouter.NTOKEN_REDEEM(),
            oldRouter.BATCH_ACTION(),
            oldRouter.ACCOUNT_ACTION(),
            oldRouter.ERC1155(),
            oldRouter.LIQUIDATE_CURRENCY(),
            oldRouter.LIQUIDATE_FCASH(),
            oldRouter.cETH(),
            treasury.address,
            { "from": self.deployer}
        )
        self.proxy = interface.NotionalProxy(config["Notional"])
        self.proxy.upgradeTo(self.router.address, {"from": self.proxy.owner()})
        self.treasury = interface.NotionalTreasury(self.proxy.address)
        self.COMPToken = self.loadERC20Token("COMP")
        self.DAIToken = self.loadERC20Token("DAI")
        self.cDAIToken = self.loadERC20Token("cDAI")

    def loadERC20Token(self, token):
        with open("./abi/ERC20.json", "r") as f:
            abi = json.load(f)
        return Contract.from_abi(token, EnvironmentConfig[token], abi)

def create_environment():
    return TreasuryEnvironment(EnvironmentConfig)

def main():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(2, 0.0001e8, {"from": env.proxy.owner()})
    print(env.DAIToken.balanceOf(env.deployer))
    print(env.proxy.getReserveBalance(2))
    print(env.cDAIToken.balanceOf(env.proxy.address))
    env.treasury.transferReserveToTreasury([2], {"from": env.deployer})
    print(env.DAIToken.balanceOf(env.deployer))
    print(env.proxy.getReserveBalance(2))
    print(env.cDAIToken.balanceOf(env.proxy.address))

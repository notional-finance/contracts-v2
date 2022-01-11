from brownie import (
    TreasuryAction,
    Router
)
from brownie import accounts, interface

EnvironmentConfig = {
    "cDAI": '0x5d3a536e4d6dbd6114cc1ead35777bab948e3643',
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
        treasury = TreasuryAction.deploy(config["COMP"], config["Comptroller"], config["WETH"], { "from": self.deployer})
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

def create_environment():
    return TreasuryEnvironment(EnvironmentConfig)

def main():
    env = create_environment()
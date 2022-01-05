from brownie import (
    TreasuryAction,
    Router
)
from brownie import accounts, interface

EnvironmentConfig = {
    "cDAI": '0x5d3a536e4d6dbd6114cc1ead35777bab948e3643',
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
}

def main():
    comp = "0xc00e94cb662c3520282e6f5717214004a7f26888"
    comptroller = "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b"
    notional = "0x1344a36a1b56144c3bc62e7757377d288fde0369"
    deployer = accounts.at("0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef", force=True)
    treasury = TreasuryAction.deploy(comp, comptroller, EnvironmentConfig["WETH"], { "from": deployer})
    router = Router.at(notional)
    router = Router.deploy(
        router.GOVERNANCE(),
        router.VIEWS(),
        router.INITIALIZE_MARKET(),
        router.NTOKEN_ACTIONS(),
        router.NTOKEN_REDEEM(),
        router.BATCH_ACTION(),
        router.ACCOUNT_ACTION(),
        router.ERC1155(),
        router.LIQUIDATE_CURRENCY(),
        router.LIQUIDATE_FCASH(),
        router.cETH(),
        treasury.address,
        { "from": deployer}
    )
    proxy = interface.NotionalProxy(notional)
    proxy.upgradeTo(router.address, {"from": proxy.owner()})
    interface.NotionalTreasury(proxy.address).setTreasuryManager(deployer, {"from": proxy.owner()})
    interface.NotionalTreasury(proxy.address).setReserveBuffer(EnvironmentConfig["cDAI"], 0.0001e5, {"from": proxy.owner()})
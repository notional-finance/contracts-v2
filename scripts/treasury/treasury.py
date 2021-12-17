from brownie import (
    TreasuryAction,
    Router,
    RouterV2
)
from brownie import accounts, interface

def main():
    comp = "0xc00e94cb662c3520282e6f5717214004a7f26888"
    comptroller = "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b"
    notional = "0x1344a36a1b56144c3bc62e7757377d288fde0369"
    deployer = accounts.at("0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef", force=True)
    treasury = TreasuryAction.deploy(comp, comptroller, { "from": deployer})
    router = Router.at(notional)
    routerV2 = RouterV2.deploy(
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
    proxy.upgradeTo(routerV2.address, {"from": proxy.owner()})
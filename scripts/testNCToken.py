from brownie import accounts, interface, Contract, ncToken, nProxy

def main():
    deployer = accounts.at("0xE6FB62c2218fd9e3c948f0549A2959B509a293C8", force=True)
    notional = interface.NotionalProxy("0x1344A36A1B56144C3Bc62E7757377D288fDE0369")
    impl = ncToken.deploy(
        notional.address,
        "0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5",
        True,
        200675507759352861947578598,
        {"from": deployer}
    )
    initData = impl.initialize.encode_input()
    proxy = nProxy.deploy(impl, initData, {"from": notional.owner()})
    ncETH = Contract.from_abi("ncETH", proxy.address, ncToken.abi)
    ethWhale = accounts.at("0x1b3cb81e51011b549d78bf720b0d924ac763a7c2", force=True)
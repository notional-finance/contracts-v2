from brownie import accounts, network, interface
from brownie import MockAggregator

def main():
    underlying = "0xFf795577d9AC8bD7D90Ee22b6C1703490b6512FD"
    asset = "0xED36a75A9ca4f72ad0fD8f3FB56b2c9aA8ceA28d"
    oracle = "0x0Ff50743233eFb1a87726eBbB32f938D4822153f"
    lender = "0xe0fba4fc209b4948668006b2be61711b7f465bae"
    liquidator = "0x1859991dB0c8C973135C9ba53b92e5B7cF23b977"
    underlyingToken = interface.ERC20(underlying)
    assetToken = interface.ERC20(asset)
    notional = interface.NotionalProxy("0x0EAE7BAdEF8f95De91fDDb74a89A786cF891Eb0e")
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    #notional.listCurrency.encode_input((), (), )

    
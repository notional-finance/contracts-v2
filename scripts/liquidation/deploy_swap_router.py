from brownie import MockUniV3SwapRouter, accounts, network
from scripts.liquidation import LiquidationConfig

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    config = LiquidationConfig[network.show_active()]
    exchange = MockUniV3SwapRouter.deploy(config["WETH"], deployer.address, { "from": deployer })

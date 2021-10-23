import json
import os

from brownie import MockUniV3SwapRouter, accounts, network

EnvironmentConfig = {
    "kovan": {
        "WETH": "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
        "UniswapRouter": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
        "UniswapWETHDAI": "0x4ba1d028e053A53842Ce31b0357C5864B40Ef909",
        "MockUniswapRouter": "0xcBb07045B5365D5Cb0b98dC5980950d9f1c84dc7"
    },
}

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    config = EnvironmentConfig[network.show_active()]
    exchange = MockUniV3SwapRouter.deploy(config["WETH"], deployer.address, { "from": deployer })

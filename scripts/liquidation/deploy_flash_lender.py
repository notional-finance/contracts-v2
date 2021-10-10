import json
import os

from brownie import MockAaveFlashLender, WETH9, accounts, network

EnvironmentConfig = {
    "kovan": {
        "WETH": "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
        "UniswapRouter": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
        "UniswapWETHDAI": "0x4ba1d028e053A53842Ce31b0357C5864B40Ef909",
    },
}

def main():
    # Deployer = 0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef for kovan
    deployer = accounts.add("0x43a6634021d4b1ff7fd350843eebaa7cf547aefbf9503c33af0ec27c83f76827")
    config = EnvironmentConfig[network.show_active()]
    lender = MockAaveFlashLender.deploy(config["WETH"], deployer.address, { "from": deployer })
    weth = WETH9(config["WETH"])
    weth.deposit({"from": deployer, "value": 5000e18})
    weth.transfer(lender.address, 100e18, {"from": accounts[0]})
    env.token["DAI"].transfer(env.flashLender.address, 100000e18, {"from": accounts[0]})
    env.token["USDT"].transfer(env.flashLender.address, 100000e6, {"from": accounts[0]})    

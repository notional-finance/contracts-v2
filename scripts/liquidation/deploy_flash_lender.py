import json
import os

from brownie import MockAaveFlashLender, accounts, network, interface

EnvironmentConfig = {
    "kovan": {
        "WETH": "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
        "DAI": "0x181d62ff8c0aeed5bc2bf77a88c07235c4cc6905",
        "USDC": "0xf503d5cd87d10ce8172f9e77f76ade8109037b4c",
        "WBTC": "0x45a8451ceaae5976b4ae5f14a7ad789fae8e9971"
    },
}

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    config = EnvironmentConfig[network.show_active()]
    lender = MockAaveFlashLender.deploy(config["WETH"], deployer.address, { "from": deployer })
    
    # Funding lender with WETH
    weth = interface.WETH9(config["WETH"])
    weth.deposit({"from": deployer, "value": 5e18})
    weth.transfer(lender.address, 5e18, {"from": deployer})
    
    # Funding lender with DAI
    daiToken = interface.IERC20(config["DAI"])
    daiToken.transfer(lender.address, 100e18, {"from": deployer})
    
    # Funding lender with USDC
    usdcToken = interface.IERC20(config["USDC"])
    usdcToken.transfer(lender.address, 100e6, {"from": deployer})

    # Funding lender with WBTC
    wbtcToken = interface.IERC20(config["WBTC"])
    wbtcToken.transfer(lender.address, 1e8, {"from": deployer})

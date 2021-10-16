import json
import os

from brownie import NotionalV2UniV3FlashLiquidator, accounts, network

EnvironmentConfig = {
    "kovan": {
        "NotionalV2": "0x0EAE7BAdEF8f95De91fDDb74a89A786cF891Eb0e",
        "AaveFlashLender": "0xFcdAe2109D5Fa3Fbe82E4FE03110966cA449057c",
        "LeakyFlashLender": "0xb3E6bBf0aC44965Ed5842d2feC2acCa89DB9C586",
        "WETH": "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
        "DAI": "0x181d62ff8c0aeed5bc2bf77a88c07235c4cc6905",
        "USDC": "0xf503d5cd87d10ce8172f9e77f76ade8109037b4c",
        "WBTC": "0x45a8451ceaae5976b4ae5f14a7ad789fae8e9971",
        "UniswapRouter": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
        "cETH": "0x40575f9Eb401f63f66F4c434248ad83D3441bf61",
        "cDAI": "0x4dc87a3d30c4a1b33e4349f02f4c5b1b1ef9a75d",
        "cUSDC": "0xf17c5c7240cbc83d3186a9d6935f003e451c5cdd",
        "cWBTC": "0xa8e51e20985e926de882ee700ec7f7d51d89d130",
        "UniswapWETHDAI": "0x4ba1d028e053A53842Ce31b0357C5864B40Ef909",
    },
}


def main():
    # Deployer = 0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef for kovan
    lender = "AaveFlashLender"
    deployer = accounts.add("0x43a6634021d4b1ff7fd350843eebaa7cf547aefbf9503c33af0ec27c83f76827")
    config = EnvironmentConfig[network.show_active()]
    liquidator = NotionalV2UniV3FlashLiquidator.deploy(
        config["NotionalV2"], 
        config[lender], 
        config["WETH"], 
        config["cETH"], 
        deployer.address,
        config["UniswapRouter"],  
        {"from": deployer}
    )
    liquidator.setCTokenAddress(config["cDAI"], {"from": deployer})
    liquidator.setCTokenAddress(config["cUSDC"], {"from": deployer})
    liquidator.setCTokenAddress(config["cWBTC"], {"from": deployer})
    liquidator.approveToken(config["cETH"], config["NotionalV2"], {"from": deployer})
    liquidator.approveToken(config["cUSDC"], config["NotionalV2"], {"from": deployer})
    liquidator.approveToken(config["cWBTC"], config["NotionalV2"], {"from": deployer})
    liquidator.approveToken(config["cDAI"], config["NotionalV2"], {"from": deployer})
    liquidator.approveToken(config["WETH"], config[lender], {"from": deployer})
    liquidator.approveToken(config["WETH"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["DAI"], config[lender], {"from": deployer})
    liquidator.approveToken(config["DAI"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["USDC"], config[lender], {"from": deployer})
    liquidator.approveToken(config["USDC"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["WBTC"], config[lender], {"from": deployer})
    liquidator.approveToken(config["WBTC"], config["UniswapRouter"], {"from": deployer})

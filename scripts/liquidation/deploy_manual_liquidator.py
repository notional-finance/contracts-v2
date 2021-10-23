import json
import os

from brownie import MockUniV3SwapRouter, BeaconProxy, accounts, network
from brownie.project import ContractsVProject
from brownie.network.contract import Contract

EnvironmentConfig = {
    "kovan": {
        "WETH": "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
        "UniswapRouter": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
        "UniswapWETHDAI": "0x4ba1d028e053A53842Ce31b0357C5864B40Ef909",
        "MockUniswapRouter": "0xcBb07045B5365D5Cb0b98dC5980950d9f1c84dc7"
    },
}

def setManualLiquidatorApprovals(liquidator, deployer):
    liquidator.enableCToken(env.cToken["DAI"].address, {"from": deployer})
    liquidator.enableCToken(env.cToken["USDC"].address, {"from": deployer})
    liquidator.enableCToken(env.cToken["WBTC"].address, {"from": deployer})
    liquidator.approveToken(env.cToken["ETH"].address, env.notional.address, {"from": deployer})
    liquidator.approveToken(env.weth.address, env.flashLender.address, {"from": deployer})
    liquidator.approveToken(env.weth.address, env.swapRouter.address, {"from": deployer})
    liquidator.approveToken(env.token["DAI"].address, env.flashLender.address, {"from": deployer})
    liquidator.approveToken(env.token["DAI"], env.swapRouter.address, {"from": deployer})
    liquidator.approveToken(env.token["USDC"].address, env.flashLender.address, {"from": deployer})
    liquidator.approveToken(env.token["USDC"], env.swapRouter.address, {"from": deployer})
    liquidator.approveToken(env.token["WBTC"].address, env.flashLender.address, {"from": deployer})
    liquidator.approveToken(env.token["WBTC"], env.swapRouter.address, {"from": deployer})

def deployManualLiquidator(currencyId, assetAddress, underlyingAddress, transferFee, deployer):
    initData = env.manualLiquidator.initialize.encode_input(
        currencyId, 
        assetAddress, 
        underlyingAddress, 
        transferFee
    )
    proxy = BeaconProxy.deploy(env.manualLiquidatorBeacon.address, initData, {"from": deployer})
    abi = ContractsVProject._build.get("NotionalV2ManualLiquidator")["abi"]
    env.manualLiquidatorETH = Contract.from_abi(
        "Notional", proxy.address, abi=abi, owner=deployer
    )
    setManualLiquidatorApprovals(env, env.manualLiquidatorETH)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    config = EnvironmentConfig[network.show_active()]
    # Deploy manual liquidator implementation
    env.manualLiquidator = NotionalV2ManualLiquidator.deploy(
        env.notional.address,
        env.weth,
        env.cToken["ETH"].address,
        deployer.address,
        env.swapRouter.address,
        env.noteERC20Proxy.address,
        {"from": deployer})

    # Deploy upgradable beacon
    env.manualLiquidatorBeacon = UpgradeableBeacon.deploy(env.manualLiquidator.address, {"from": deployer})

    deployManualLiquidator()

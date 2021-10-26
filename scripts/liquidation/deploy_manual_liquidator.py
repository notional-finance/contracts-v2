from brownie import UpgradeableBeacon, BeaconProxy, NotionalV2ManualLiquidator, accounts, network
from brownie.project import ContractsVProject
from brownie.network.contract import Contract
from scripts.liquidation.liquidation_config import LiquidationConfig

config = LiquidationConfig[network.show_active()]

def setManualLiquidatorApprovals(liquidator, deployer):
    liquidator.enableCToken(config["cDAI"], {"from": deployer})
    liquidator.enableCToken(config["cUSDC"], {"from": deployer})
    liquidator.enableCToken(config["cWBTC"], {"from": deployer})
    liquidator.approveToken(config["cETH"], config["NotionalV2"], {"from": deployer})
    liquidator.approveToken(config["WETH"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["DAI"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["USDC"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["WBTC"], config["UniswapRouter"], {"from": deployer})

def deployManualLiquidator(beacon, liquidator, currencyId, deployer):
    initData = liquidator.initialize.encode_input(currencyId)
    proxy = BeaconProxy.deploy(beacon.address, initData, {"from": deployer})
    abi = ContractsVProject._build.get("NotionalV2ManualLiquidator")["abi"]
    proxyContract = Contract.from_abi(
        "NotionalV2ManualLiquidator", proxy.address, abi=abi, owner=deployer
    )
    setManualLiquidatorApprovals(proxyContract, deployer)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    # Deploy manual liquidator implementation
    manualLiquidator = NotionalV2ManualLiquidator.deploy(
        config["NotionalV2"],
        config["WETH"],
        config["cETH"],
        config["UniswapRouter"],
        config["NoteToken"],
        {"from": deployer})

    # Deploy upgradable beacon
    manualLiquidatorBeacon = UpgradeableBeacon.deploy(manualLiquidator.address, {"from": deployer})

    deployManualLiquidator(manualLiquidatorBeacon, manualLiquidator, 1, deployer)
    deployManualLiquidator(manualLiquidatorBeacon, manualLiquidator, 2, deployer)
    deployManualLiquidator(manualLiquidatorBeacon, manualLiquidator, 3, deployer)
    deployManualLiquidator(manualLiquidatorBeacon, manualLiquidator, 4, deployer)

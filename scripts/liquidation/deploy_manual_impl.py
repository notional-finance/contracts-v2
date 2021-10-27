import json
from brownie import UpgradeableBeacon, BeaconProxy, NotionalV2ManualLiquidator, accounts, network
from brownie.project import ContractsVProject
from brownie.network.contract import Contract
from scripts.liquidation.liquidation_config import LiquidationConfig

config = LiquidationConfig[network.show_active()]

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    # Deploy manual liquidator implementation
    NotionalV2ManualLiquidator.deploy(
        config["NotionalV2"],
        config["WETH"],
        config["cETH"],
        config["UniswapRouter"],
        config["NoteToken"],
        {"from": deployer})
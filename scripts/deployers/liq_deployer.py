import json

from brownie import (
    Contract,
    accounts, 
    network, 
    MockAaveFlashLender, 
    NotionalV2FlashLiquidator,
    MockUniV3SwapRouter,
    NotionalV2ManualLiquidator,
    UpgradeableBeacon,
    BeaconProxy
)
from scripts.config import TokenConfig
from scripts.common import ContractDeployer, isMainnet

LiquidationConfig = {
    "mainnet": {
        "lender": "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9",
        "exchange": "0xE592427A0AEce92De3Edee1F18E0157C05861564"
    }
}

class LiqDeployer:
    def __init__(self, network, deployer) -> None:
        self.liquidation = {}
        self.network = network
        self.deployer = deployer

    def deployFlashLender(self):
        if isMainnet(self.network):
            self.liquidation["lender"] = LiquidationConfig["mainnet"]["lender"]
            return
        deployer = ContractDeployer(self.liquidation, self.deployer)
        deployer.deploy("lender", MockAaveFlashLender, [
            self.config["tokens"]["WETH"]["address"], 
            self.deployer.address
        ])

    def deployExchange(self):
        if isMainnet(self.network):
            self.liquidation["exchange"] = LiquidationConfig["mainnet"]["exchange"]
        
        deployer = ContractDeployer(self.liquidation, self.deployer)
        deployer.deploy("exchange", MockUniV3SwapRouter, [
            self.config["tokens"]["WETH"]["address"], 
            self.deployer.address
        ])

    def deployFlashLiquidator(self):
        if "lender" not in self.liquidation:
            self.deployFlashLender()
        if "exchange" not in self.liquidation:
            self.deployExchange()

        deployer = ContractDeployer(self.liquidation, self.deployer)
        deployer.deploy("flash", NotionalV2FlashLiquidator, [
            self.config["notional"], 
            self.liquidation["lender"], 
            self.config["tokens"]["WETH"]["address"], 
            self.config["compound"]["ctokens"]["ETH"]["address"], 
            deployer.address,
            self.liquidation["exchange"],
        ])

    def _deployManualLiquidatorImpl(self, manual):
        if "exchange" not in self.liquidation:
            self.deployExchange()

        deployer = ContractDeployer(manual, self.deployer)
        deployer.deploy("impl", NotionalV2ManualLiquidator, [
            self.config["notional"],
            self.config["tokens"]["WETH"]["address"], 
            self.config["compound"]["ctokens"]["ETH"]["address"], 
            self.liquidation["exchange"],
            self.config["note"],
        ])

    def _deployManualBeacon(self, manual):
        if "impl" not in manual:
            self._deployManualLiquidatorImpl(manual)

        deployer = ContractDeployer(manual, self.deployer)
        deployer.deploy("beacon", UpgradeableBeacon, [manual["impl"]])

    def _deployManualLiquidator(self, manual, currencyId):
        if "beacon" not in manual:
            self._deployManualBeacon(manual)
        if "impl" not in manual:
            self._deployManualLiquidatorImpl(manual)

        deployer = ContractDeployer(manual, self.deployer)
        liquidator = Contract.from_abi("manualLiquidator", manual["impl"], abi=NotionalV2ManualLiquidator.abi)
        initData = liquidator.initialize.encode_input(currencyId)
        deployer.deploy(str(currencyId), BeaconProxy, [manual["beacon"], initData])

    def deployManualLiquidator(self, currencyId):
        manual = {}
        if "manual" in self.liquidation:
            manual = self.liquidation["manual"]

        if "impl" in manual:
            print("Manual liquidator implementation deployed at {}".format(manual["impl"]))
        else:
            self._deployManualLiquidatorImpl(manual)

        if "beacon" in manual:
            print("Manual beacon deployed at {}".format(manual["beacon"]))
        else:
            self._deployManualBeacon(manual)

        if currencyId in manual:
            print("Manual liquidator for currency {} deployed at {}".format(currencyId, manual[currencyId]))
        else:
            self._deployManualLiquidator(manual, currencyId)

    def load(self):
        print("Loading liquidator addresses")
        with open("v2.{}.json".format(self.network), "r") as f:
            self.config = json.load(f)
        if "liquidation" in self.config:
            self.liquidation = self.config["liquidation"]

    def save(self):
        print("Saving liquidator addresses")
        self.config["liquidation"] = self.liquidation
        with open("v2.{}.json".format(self.network), "w") as f:
            json.dump(self.config, f, sort_keys=True, indent=4)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    liq = LiqDeployer(network.show_active(), deployer)
    liq.load()
    liq.deployExchange()
    liq.deployFlashLender()
    liq.deployFlashLiquidator()
    liq.deployManualLiquidator(1)
    liq.deployManualLiquidator(2)
    liq.deployManualLiquidator(3)
    liq.deployManualLiquidator(4)
    liq.save()

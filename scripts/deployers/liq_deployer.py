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
from scripts.deployers.contract_deployer import ContractDeployer
from scripts.common import isProduction

LiquidationConfig = {
    "mainnet": {
        "lender": "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9",
        "exchange": "0xE592427A0AEce92De3Edee1F18E0157C05861564"
    }
}

class LiqDeployer:
    def __init__(self, network, deployer, config=None, persist=True) -> None:
        self.config = config
        if self.config == None:
            self.config = {}
        self.persist = persist
        self.liquidation = {}
        self.network = network
        self.deployer = deployer
        self._load()

    def _load(self):
        print("Loading liquidator config")
        if self.persist:
            with open("v2.{}.json".format(self.network), "r") as f:
                self.config = json.load(f)
        if "liquidation" in self.config:
            self.liquidation = self.config["liquidation"]

    def _save(self):
        print("Saving liquidator config")
        self.config["liquidation"] = self.liquidation
        if self.persist:
            with open("v2.{}.json".format(self.network), "w") as f:
                json.dump(self.config, f, sort_keys=True, indent=4)

    def deployFlashLender(self):
        if isProduction(self.network):
            self.liquidation["lender"] = LiquidationConfig[self.network]["lender"]
            return

        if "lender" in self.liquidation:
            print("Lender deployed at {}".format(self.liquidation["exchange"]))
            return

        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(MockAaveFlashLender, [
            self.config["tokens"]["WETH"]["address"], 
            self.deployer.address
        ])
        self.liquidation["lender"] = contract.address
        # Re-deploy dependent contracts
        self.liquidation.pop("flash", None)
        self._save()

    def deployExchange(self):
        if isProduction(self.network):
            self.liquidation["exchange"] = LiquidationConfig[self.network]["exchange"]
            return

        if "exchange" in self.liquidation:
            print("Exchanged deployed at {}".format(self.liquidation["exchange"]))
            return
        
        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(MockUniV3SwapRouter, [
            self.config["tokens"]["WETH"]["address"], 
            self.deployer.address
        ])
        self.liquidation["exchange"] = contract.address
        # Re-deploy dependent contracts
        self.liquidation.pop("flash", None)
        self.liquidation.pop("manual", None)
        self._save()

    def deployFlashLiquidator(self):
        if "flash" in self.liquidation:
            print("Flash liquidator deployed at {}".format(self.liquidation["flash"]))
            return

        if "lender" not in self.liquidation:
            self.deployFlashLender()
        if "exchange" not in self.liquidation:
            self.deployExchange()

        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(NotionalV2FlashLiquidator, [
            self.config["notional"], 
            self.liquidation["lender"], 
            self.config["tokens"]["WETH"]["address"], 
            self.config["compound"]["ctokens"]["ETH"]["address"], 
            self.deployer.address,
            self.liquidation["exchange"],
        ])
        self.liquidation["flash"] = contract.address
        self._save()

    def _deployManualLiquidatorImpl(self, manual):
        if "impl" in manual:
            print("Manual liquidator implementation deployed at {}".format(manual["impl"]))
            return

        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(NotionalV2ManualLiquidator, [
            self.config["notional"],
            self.config["tokens"]["WETH"]["address"], 
            self.config["compound"]["ctokens"]["ETH"]["address"], 
            self.liquidation["exchange"],
            self.config["note"],
        ])
        manual["impl"] = contract.address
        self._save()

    def _deployManualBeacon(self, manual):
        if "beacon" in manual:
            print("Manual beacon deployed at {}".format(manual["beacon"]))
            return

        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(UpgradeableBeacon, [manual["impl"]])
        manual["beacon"] = contract.address
        self._save()

    def _deployManualLiquidator(self, manual, currencyId):
        proxies = {}
        if "proxies" in manual:
            proxies = manual["proxies"]
        else:
            manual["proxies"] = proxies

        if str(currencyId) in proxies:
            print("Manual liquidator for currency {} deployed at {}".format(currencyId, proxies[str(currencyId)]))
            return

        deployer = ContractDeployer(self.deployer)
        liquidator = Contract.from_abi("manualLiquidator", manual["impl"], abi=NotionalV2ManualLiquidator.abi)
        initData = liquidator.initialize.encode_input(currencyId)
        contract = deployer.deploy(BeaconProxy, [manual["beacon"], initData])
        proxies[str(currencyId)] = contract.address
        self._save()

    def deployManualLiquidator(self, currencyId):
        manual = {}
        if "manual" in self.liquidation:
            manual = self.liquidation["manual"]
        else:
            self.liquidation["manual"] = manual

        self._deployManualLiquidatorImpl(manual)
        self._deployManualBeacon(manual)
        self._deployManualLiquidator(manual, currencyId)


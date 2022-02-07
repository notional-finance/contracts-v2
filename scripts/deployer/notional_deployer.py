import json
import subprocess

from brownie import accounts, network
from scripts.config import TokenConfig

class NotionalDeployer:
    def __init__(self, network, deployer) -> None:
        self.network = network
        self.deployer = deployer
        pass

    def deployLibs():
        pass

    def load(self):
        with open("v2.{}.json".format(self.network), "r") as f:
            self.config = json.load(f)
        if "notional" in self.config:
            self.notional = self.config["notional"]
    
    def save(self):
        self.config["notional"] = self.notional
        with open("v2.{}.json".format(self.network), "w") as f:
            json.dump(self.config, f, sort_keys=True, indent=4)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    notional = NotionalDeployer(network.show_active(), deployer)
    notional.load()
    notional.deployLibs()
    notional.save()
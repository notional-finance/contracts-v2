import json
from brownie import Contract, network, cTokenAggregator
from scripts.common import loadContractFromABI, loadContractFromArtifact

class EnvironmentV2:
    def __init__(self, config) -> None:
        self.tokens = {}
        self.ctokens = {}
        self.ethOracles = {}
        self.cTokenOracles = {}        
        self.config = config
        # Load notional
        if "notional" in self.config:
            self.notional = loadContractFromABI("NotionalProxy", self.config["notional"], "abi/Notional.json")

        # Load tokens
        tokens = self.config["tokens"]
        for k, v in tokens.items():
            self.tokens[k] = loadContractFromABI(k, v["address"], "abi/ERC20.json")
            if k != "WETH":
                self.ethOracles[k] = v["oracle"]

        # Load compound
        ctokens = self.config["compound"]["ctokens"]
        for k, v in ctokens.items():
            if k == "ETH":
                path = "scripts/compound_artifacts/nCEther.json"
            else:
                path = "scripts/compound_artifacts/nCErc20.json"
            self.ctokens[k] = loadContractFromArtifact("c{}".format(k), v["address"], path)
            self.cTokenOracles[k] = Contract.from_abi("c{}Oracle".format(k), v["oracle"], cTokenAggregator.abi)

        # Load init data
        if "notionalInit" in self.config:
            self.notionalInit = self.config["notionalInit"]

def main():
    with open("v2.{}.json".format(network.show_active()), "r") as f:
        config = json.load(f)
    env = EnvironmentV2(config)

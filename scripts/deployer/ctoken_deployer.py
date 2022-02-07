import json
import subprocess

from brownie import accounts, network, cTokenAggregator
from scripts.deployment import deployArtifact
from scripts.config import CompoundConfig, TokenConfig
from scripts.common import loadContractFromArtifact

# Mainnet token addresses
TokenAddress = {
    "ETH": "",
    "DAI": "",
    "USDC": "",
    "WBTC": "",
}

# Mainnet oracle addresses
OracleAddress = {
    "DAI": "",
    "USDC": "",
    "WBTC": "",
}

class CTokenDeployer:
    def __init__(self, network, deployer) -> None:
        self.compound = {}
        self.network = network
        self.deployer = deployer

    def deployInterestRateModel(self, symbol):
        print("Deploying c{} interest rate model".format(symbol))
        config = CompoundConfig[symbol]
        # Deploy interest rate model
        interestRateModel = None
        if config["interestRateModel"]["name"] == "whitepaper":
            interestRateModel = deployArtifact(
                "scripts/compound_artifacts/nWhitePaperInterestRateModel.json",
                [
                    config["interestRateModel"]["baseRate"],
                    config["interestRateModel"]["multiplier"],
                ],
                self.deployer,
                "InterestRateModel",
            )
        elif config["interestRateModel"]["name"] == "jump":
            interestRateModel = deployArtifact(
                "scripts/compound_artifacts/nJumpRateModel.json",
                [
                    config["interestRateModel"]["baseRate"],
                    config["interestRateModel"]["multiplier"],
                    config["interestRateModel"]["jumpMultiplierPerYear"],
                    config["interestRateModel"]["kink"],
                ],
                self.deployer,
                "JumpRateModel",
            )
        return interestRateModel
    
    def deployCETH(self):
        config = CompoundConfig["ETH"]
        return deployArtifact(
            "scripts/compound_artifacts/nCEther.json",
            [
                self.compound["comptroller"],
                self.compound["ctokens"]["ETH"]["model"],
                config["initialExchangeRate"],
                "Compound Ether",
                "cETH",
                8,
                self.deployer.address,
            ],
            self.deployer,
            "cETH",
        )

    def deployCERC20(self, symbol):
        config = CompoundConfig[symbol]
        return deployArtifact(
            "scripts/compound_artifacts/nCErc20.json",
            [
                self.config["tokens"][symbol]["address"],
                self.compound["comptroller"],
                self.compound["ctokens"][symbol]["model"],
                config["initialExchangeRate"],
                "Compound " + symbol,  # This is not exactly correct but whatever
                "c" + symbol,
                8,
                self.deployer.address,
            ],
            self.deployer,
            "cErc20",
        )

    def initCToken(self, ctoken, symbol):
        comptroller = loadContractFromArtifact(
            "scripts/compound_artifacts/nComptroller.json",
            "nComptroller",
            self.compound["comptroller"]
        )
        if comptroller is not None:
            print("Initializing comptroller for {}".format(symbol))
            comptroller._supportMarket(ctoken["address"], {"from": self.deployer})
            comptroller._setCollateralFactor(
                ctoken["address"], 750000000000000000, {"from": self.deployer}
            )
            if symbol != "ETH":
                print("Initializing price oracle for {}".format(symbol))
                compPriceOracle = loadContractFromArtifact(
                    "scripts/compound_artifacts/nPriceOracle.json",
                    "nPriceOracle",
                    self.compound["oracle"]
                )
                if compPriceOracle != None:
                    compPriceOracle.setUnderlyingPrice(
                        ctoken["address"], 
                        TokenConfig[symbol]["rate"],
                        {"from": self.deployer}
                    )

    def deployCToken(self, symbol):
        ctokens = {}
        if "ctokens" in self.compound:
            ctokens = self.compound["ctokens"]

        if self.network == "mainnet" or self.network == "hardhat-fork":
            # Save token address directly for mainnet and mainnet fork
            ctokens[symbol] = {
                "address": TokenAddress[symbol],
                "oracle": OracleAddress[symbol]
            }
        else:
            ctoken = {}
            if symbol in ctokens:
                ctoken = ctokens[symbol]

            # Deploy interest rate model
            if "model" in ctoken:
                print("c{} interest model deployed at {}".format(symbol, ctoken["model"]))
            else:
                try:
                    model = self.deployInterestRateModel(symbol)
                    ctoken["model"] = model.address
                except Exception as e:
                    print("Failed to deploy c{} interest rate model: {}".format(symbol, e))
                    return

            # Deploy cToken contract
            if "address" in ctoken:
                print("c{} deployed at {}".format(symbol, ctoken["address"]))
            else:
                try:
                    if symbol == "ETH":
                        t = self.deployCETH()
                    else:
                        t = self.deployCERC20(symbol)
                    ctoken["address"] = t.address
                    ctoken["initialized"] = False
                except Exception as e:
                    print("Failed to deploy c{}: {}".format(symbol, e))
                    return

            # Initialize cToken
            if "initialized" not in ctoken or ctoken["initialized"] == False:
                try:
                    self.initCToken(ctoken, symbol)
                    ctoken["initialized"] = True
                except Exception as e:
                    print("Failed to initialize c{}: {}".format(symbol, e))       
                    return         

            # Deploy aggregator
            if "aggregator" in ctoken:
                print("c{} aggregator deployed at {}".format(symbol, ctoken["aggregator"]))
            else:
                try:
                    aggregator = cTokenAggregator.deploy(ctoken["address"], {"from": self.deployer})
                    ctoken["aggregator"] = aggregator.address
                except Exception as e:
                    print("Failed to deploy c{} aggregator: {}".format(symbol, e))

            ctokens[symbol] = ctoken
        self.compound["ctokens"] = ctokens

    def deployComptroller(self):
        if "oracle" in self.compound:
            print("Compound price oracle is already deployed")
        else:
            try:
                oracle = deployArtifact(
                    "scripts/compound_artifacts/nPriceOracle.json", 
                    [], 
                    self.deployer, 
                    "nPriceOracle"
                )
                self.compound["oracle"] = oracle.address
            except:
                print("Failed to deploy compound price oracle")

        if "comptroller" in self.compound:
            print("Comptroller is already deployed")
        else:
            try:
                comptroller = deployArtifact(
                    "scripts/compound_artifacts/nComptroller.json", 
                    [], 
                    self.deployer, 
                    "nComptroller"
                )
                comptroller._setMaxAssets(20)
                comptroller._setPriceOracle(self.compound["oracle"])
                self.compound["comptroller"] = comptroller.address
            except:
                print("Failed to deploy comptroller")

    def load(self):
        print("Loading compound addresses")
        with open("v2.{}.json".format(self.network), "r") as f:
            self.config = json.load(f)
        if "compound" in self.config:
            self.compound = self.config["compound"]

    def save(self):
        print("Saving compound addresses")
        self.config["compound"] = self.compound
        with open("v2.{}.json".format(self.network), "w") as f:
            json.dump(self.config, f, sort_keys=True, indent=4)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    ctokens = CTokenDeployer(network.show_active(), deployer)
    ctokens.load()
    ctokens.deployComptroller()
    ctokens.deployCToken("ETH")
    ctokens.deployCToken("DAI")
    ctokens.deployCToken("USDC")
    ctokens.deployCToken("WBTC")
    ctokens.save()    
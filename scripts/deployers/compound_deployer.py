import json

from brownie import accounts, network, cTokenAggregator
from scripts.deployment import deployArtifact
from scripts.config import CompoundConfig, TokenConfig
from scripts.common import loadContractFromArtifact, isMainnet

# Mainnet cToken addresses
TokenAddress = {
    "mainnet": {
        "ETH": "0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5",
        "DAI": "0x5d3a536e4d6dbd6114cc1ead35777bab948e3643",
        "USDC": "0x39aa39c021dfbae8fac545936693ac917d5e7563",
        "WBTC": "0xccf4429db6322d5c611ee964527d42e5d685dd6a"
    }
}

# Mainnet asset rate oracle addresses
OracleAddress = {
    "mainnet": {
        "ETH": "0x5fbf4539a89fbd1e5d784db3f7ba6c394ac450fc",
        "DAI": "0xc7b9c53d345ec7a00d5c085085cb882dce79d2e9",
        "USDC": "0x181900d998a8a922e68b3fc186ce0fa525c3c424",
        "WBTC": "0x913f575653c933ac15c8eb5996ed71a5547977d8"
    }
}

class CompoundDeployer:
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
            "nComptroller",
            self.compound["comptroller"],
            "scripts/compound_artifacts/nComptroller.json"
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
                    "nPriceOracle",
                    self.compound["oracle"],
                    "scripts/compound_artifacts/nPriceOracle.json"
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

        if isMainnet(self.network):
            # Save token address directly for mainnet and mainnet fork
            ctokens[symbol] = {
                "address": TokenAddress["mainnet"][symbol],
                "oracle": OracleAddress["mainnet"][symbol]
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
                comptroller._setMaxAssets(20, {"from": self.deployer})
                comptroller._setPriceOracle(self.compound["oracle"], {"from": self.deployer})
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

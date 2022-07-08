import json

from brownie import cTokenV2Aggregator
from scripts.common import isProduction
from scripts.config import CompoundConfig
from scripts.deployers.contract_deployer import ContractDeployer
from scripts.deployment import deployArtifact

# Mainnet cToken addresses
TokenAddress = {
    "mainnet": {
        "ETH": "0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5",
        "DAI": "0x5d3a536e4d6dbd6114cc1ead35777bab948e3643",
        "USDC": "0x39aa39c021dfbae8fac545936693ac917d5e7563",
        "WBTC": "0xccf4429db6322d5c611ee964527d42e5d685dd6a",
    }
}

# Mainnet asset rate oracle addresses
OracleAddress = {
    "mainnet": {
        "ETH": "0x5fbf4539a89fbd1e5d784db3f7ba6c394ac450fc",
        "DAI": "0xc7b9c53d345ec7a00d5c085085cb882dce79d2e9",
        "USDC": "0x181900d998a8a922e68b3fc186ce0fa525c3c424",
        "WBTC": "0x913f575653c933ac15c8eb5996ed71a5547977d8",
    }
}

ComptrollerAddress = {"mainnet": "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b"}


class CompoundDeployer:
    def __init__(self, network, deployer, config=None, persist=True) -> None:
        self.config = config
        if self.config is None:
            self.config = {}
        self.persist = persist
        self.compound = {}
        self.ctokens = {}
        self.network = network
        self.deployer = deployer
        self._load()

    def _load(self):
        print("Loading compound config")
        if self.persist:
            with open("v2.{}.json".format(self.network), "r") as f:
                self.config = json.load(f)
        if "compound" in self.config:
            self.compound = self.config["compound"]
            if "ctokens" in self.compound:
                self.ctokens = self.compound["ctokens"]

    def _save(self):
        print("Saving compound config")
        self.compound["ctokens"] = self.ctokens
        self.config["compound"] = self.compound
        if self.persist:
            with open("v2.{}.json".format(self.network), "w") as f:
                json.dump(self.config, f, sort_keys=True, indent=4)

    def _deployInterestRateModel(self, ctoken, symbol):
        if "model" in ctoken:
            print("c{} interest model deployed at {}".format(symbol, ctoken["model"]))
            return

        print("Deploying c{} interest rate model".format(symbol))
        config = CompoundConfig[symbol]
        # Deploy interest rate model
        if config["interestRateModel"]["name"] == "whitepaper":
            interestRateModel = deployArtifact(
                "scripts/artifacts/nWhitePaperInterestRateModel.json",
                [
                    config["interestRateModel"]["baseRate"],
                    config["interestRateModel"]["multiplier"],
                ],
                self.deployer,
                "InterestRateModel",
            )
        elif config["interestRateModel"]["name"] == "jump":
            interestRateModel = deployArtifact(
                "scripts/artifacts/nJumpRateModel.json",
                [
                    config["interestRateModel"]["baseRate"],
                    config["interestRateModel"]["multiplier"],
                    config["interestRateModel"]["jumpMultiplierPerYear"],
                    config["interestRateModel"]["kink"],
                ],
                self.deployer,
                "JumpRateModel",
            )
        ctoken["model"] = interestRateModel.address
        # Re-deploy dependent contracts
        ctoken.pop("oracle", None)
        ctoken.pop("address", None)
        self._save()

    def _deployCETH(self, ctoken):
        if "address" in ctoken:
            print("c{} deployed at {}".format("ETH", ctoken["address"]))
            return

        config = CompoundConfig["ETH"]
        contract = deployArtifact(
            "scripts/artifacts/nCEther.json",
            [
                self.compound["comptroller"],
                self.ctokens["ETH"]["model"],
                config["initialExchangeRate"],
                "Compound Ether",
                "cETH",
                8,
                self.deployer.address,
            ],
            self.deployer,
            "cETH",
        )
        ctoken["address"] = contract.address
        # Re-deploy dependent contracts
        ctoken.pop("oracle", None)
        self._save()

    def _deployCERC20(self, ctoken, symbol):
        if "address" in ctoken:
            print("c{} deployed at {}".format(symbol, ctoken["address"]))
            return

        config = CompoundConfig[symbol]
        contract = deployArtifact(
            "scripts/artifacts/nCErc20.json",
            [
                self.config["tokens"][symbol]["address"],
                self.compound["comptroller"],
                self.ctokens[symbol]["model"],
                config["initialExchangeRate"],
                "Compound " + symbol,  # This is not exactly correct but whatever
                "c" + symbol,
                8,
                self.deployer.address,
            ],
            self.deployer,
            "cErc20",
        )
        ctoken["address"] = contract.address
        # Re-deploy dependent contracts
        ctoken.pop("oracle", None)
        self._save()

    def _deployCTokenOracle(self, ctoken, symbol):
        if "oracle" in ctoken:
            print("c{} oracle deployed at {}".format(symbol, ctoken["oracle"]))
            return

        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(cTokenV2Aggregator, [ctoken["address"]], symbol, True)
        ctoken["oracle"] = contract.address
        self._save()

    def deployCToken(self, symbol):
        if isProduction(self.network):
            self.ctokens[symbol] = {
                "address": TokenAddress[self.network][symbol],
                "oracle": OracleAddress[self.network][symbol],
            }
            self._save()
            return

        ctoken = {}
        if symbol in self.ctokens:
            ctoken = self.ctokens[symbol]
        else:
            self.ctokens[symbol] = ctoken

        # Deploy interest rate model
        self._deployInterestRateModel(ctoken, symbol)

        # Deploy cToken contract
        if symbol == "ETH":
            self._deployCETH(ctoken)
        else:
            self._deployCERC20(ctoken, symbol)

        # Deploy cToken oracle
        self._deployCTokenOracle(ctoken, symbol)

    def _deployPriceOracle(self):
        if "oracle" in self.compound:
            print("Compound price oracle deployed at {}".format(self.compound["oracle"]))
            return

        oracle = deployArtifact(
            "scripts/artifacts/nPriceOracle.json", [], self.deployer, "nPriceOracle"
        )
        self.compound["oracle"] = oracle.address
        # Re-deploy dependent contracts
        self.compound.pop("comptroller", None)
        self._save()

    def _deployComptroller(self):
        if "comptroller" in self.compound:
            print("Comptroller deployed at {}".format(self.compound["comptroller"]))
            return

        comptroller = deployArtifact(
            "scripts/artifacts/nComptroller.json", [], self.deployer, "nComptroller"
        )
        comptroller._setMaxAssets(20, {"from": self.deployer})
        comptroller._setPriceOracle(self.compound["oracle"], {"from": self.deployer})
        self.compound["comptroller"] = comptroller.address
        # Re-deploy dependent contracts
        self.compound.pop("ctokens", None)
        self._save()

    def deployComptroller(self):
        if isProduction(self.network):
            self.compound["comptroller"] = ComptrollerAddress[self.network]
            self._save()
            return

        self._deployPriceOracle()
        self._deployComptroller()

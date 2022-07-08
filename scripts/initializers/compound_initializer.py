import json

from scripts.common import isProduction, loadContractFromArtifact
from scripts.config import TokenConfig


class CompoundInitializer:
    def __init__(self, network, deployer, config=None, persist=True) -> None:
        self.config = config
        if self.config is None:
            self.config = {}
        self.persist = persist
        self.compoundInit = {}
        self.comptroller = None
        self.oracle = None
        self.compound = None
        self.ctokens = None
        self.network = network
        self.deployer = deployer
        self._load()

    def _load(self):
        print("Loading Compound config")
        if self.persist:
            with open("v2.{}.json".format(self.network), "r") as f:
                self.config = json.load(f)
        if "compound" not in self.config:
            raise Exception("Compound not deployed!")
        self.compound = self.config["compound"]
        if "comptroller" not in self.compound:
            raise Exception("Comptroller not deployed!")
        self.comptroller = loadContractFromArtifact(
            "nComptroller", self.compound["comptroller"], "scripts/artifacts/nComptroller.json"
        )
        if "oracle" not in self.compound:
            raise Exception("Compound price oracle not deployed!")
        self.oracle = loadContractFromArtifact(
            "nPriceOracle", self.compound["oracle"], "scripts/artifacts/nPriceOracle.json"
        )
        if "ctokens" not in self.compound:
            raise Exception("CTokens not deployed!")
        self.ctokens = self.compound["ctokens"]
        if "compoundInit" in self.config:
            self.compoundInit = self.config["compoundInit"]

    def _save(self):
        print("Saving Compound config")
        self.config["compoundInit"] = self.compoundInit
        if self.persist:
            with open("v2.{}.json".format(self.network), "w") as f:
                json.dump(self.config, f, sort_keys=True, indent=4)

    def initCToken(self, symbol):
        if isProduction(self.network):
            print("Skipping c{} initialization for {}".format(symbol, self.network))
            return

        if symbol in self.compoundInit and self.compoundInit[symbol]:
            print("c{} is already initialized".format(symbol))
            return

        if symbol not in self.ctokens:
            raise Exception("c{} not deployed!".format(symbol))

        ctoken = self.ctokens[symbol]

        if "address" not in ctoken:
            raise Exception("c{} not deployed correctly!".format(symbol))

        print("Initializing comptroller for {}".format(symbol))
        self.comptroller._supportMarket(ctoken["address"], {"from": self.deployer})
        self.comptroller._setCollateralFactor(
            ctoken["address"], 750000000000000000, {"from": self.deployer}
        )

        if symbol == "ETH":
            self.compoundInit[symbol] = True
            self._save()
            return

        print("Initializing price oracle for {}".format(symbol))
        self.oracle.setUnderlyingPrice(
            ctoken["address"], TokenConfig[symbol]["rate"], {"from": self.deployer}
        )
        self.compoundInit[symbol] = True
        self._save()

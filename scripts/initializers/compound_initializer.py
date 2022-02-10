import json
from scripts.common import loadContractFromArtifact
from scripts.config import TokenConfig

class CompoundInitializer:
    def __init__(self, network, deployer) -> None:
        self.comptroller = None
        self.oracle = None
        self.compound = None
        self.ctokens = None
        self.network = network
        self.deployer = deployer
        self._load()
        
    def _load(self):
        print("Loading Compound config")
        with open("v2.{}.json".format(self.network), "r") as f:
            self.config = json.load(f)
        if "compound" not in self.config:
            raise Exception("Compound not deployed!")
        self.compound = self.config["compound"]
        if "comptroller" not in self.compound:
            raise Exception("Comptroller not deployed!")
        self.comptroller = loadContractFromArtifact(
            "nComptroller",
            self.compound["comptroller"],
            "scripts/compound_artifacts/nComptroller.json"
        )
        if "oracle" not in self.compound:
            raise Exception("Compound price oracle not deployed!")
        self.oracle = loadContractFromArtifact(
            "nPriceOracle",
            self.compound["oracle"],
            "scripts/compound_artifacts/nPriceOracle.json"
        )
        if "ctokens" not in self.compound:
            raise Exception("CTokens not deployed!")
        self.ctokens = self.compound["ctokens"]
        

    def initCToken(self, symbol):
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
            return

        print("Initializing price oracle for {}".format(symbol))
        self.oracle.setUnderlyingPrice(ctoken["address"], TokenConfig[symbol]["rate"], {"from": self.deployer})

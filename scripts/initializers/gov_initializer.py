import json
from brownie import Contract, NoteERC20

class GovInitializer:
    def __init__(self, network, deployer, config=None, persist=True) -> None:
        self.config = config
        if self.config == None:
            self.config = {}
        self.note = None
        self.persist = persist
        self.network = network
        self.deployer = deployer
        self._load()

    def _load(self):
        if self.persist:
            with open("v2.{}.json".format(self.network), "r") as f:
                self.config = json.load(f)
        if "note" in self.config:
            self.note =  Contract.from_abi("NoteERC20", self.config["note"], abi=NoteERC20.abi)
        
    def initNOTE(self, initialAccounts, initialGrantAmount):
        if self.note is None:
            print("NoteProxy not deployed")
            return

        try:
            self.note.initialize(initialAccounts, initialGrantAmount, self.deployer, {"from": self.deployer})
            print("NOTE contract initialized")
        except:
            print("NOTE contract is already initialized")

        
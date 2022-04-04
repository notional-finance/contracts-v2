import json

from brownie import accounts, network, NoteERC20, nProxy, GovernorAlpha
# TODO: refactor config definitions
from scripts.mainnet.deploy_governance import EnvironmentConfig, GovernanceConfig
from scripts.deployers.contract_deployer import ContractDeployer

class GovDeployer:
    def __init__(self, network, deployer, config=None, persist=True) -> None:
        self.config = config
        if self.config == None:
            self.config = {}
        self.persist = persist
        self.governor = None
        self.note = None
        self.noteImpl = None
        self.network = network
        self.deployer = deployer
        self._load()

    def _load(self):
        print("Loading governance config")
        if self.persist:
            with open("v2.{}.json".format(self.network), "r") as f:
                self.config = json.load(f)
        if "governor" in self.config:
            self.governor = self.config["governor"]
        if "note" in self.config:
            self.note = self.config["note"]
        if "noteImpl" in self.config:
            self.noteImpl = self.config["noteImpl"]

    def _save(self):
        print("Saving governance config")
        if self.governor != None:
            self.config["governor"] = self.governor
        if self.noteImpl != None:
            self.config["noteImpl"] = self.noteImpl
        if self.note != None:
            self.config["note"] = self.note
        if self.persist:
            with open("v2.{}.json".format(self.network), "w") as f:
                json.dump(self.config, f, sort_keys=True, indent=4)

    def _deployNOTEImpl(self):
        if self.noteImpl:
            print("NOTE implementation deployed at {}".format(self.noteImpl))
            return

        deployer = ContractDeployer(self.deployer)
        # Deploy NOTE implementation contract
        contract = deployer.deploy(NoteERC20, [], "noteERC20Impl", True)
        self.noteImpl = contract.address
        # Re-deploy dependent contracts
        self.note = None
        self._save()

    def _deployNOTEProxy(self):
        deployer = ContractDeployer(self.deployer)
        # This is a proxied ERC20
        contract = deployer.deploy(nProxy, [self.config["noteImpl"], bytes()], "noteERC20")
        self.note = contract.address
        # Re-deploy dependent contracts
        self.governor = None
        self._save()

    def deployNOTE(self):
        if self.note:
            print("NOTE deployed at {}".format(self.note))
            return

        # These two lines ensure that the note token is deployed to the correct address
        # every time.
        if network.show_active() == "sandbox":
            deployer = accounts.load("DEVELOPMENT_DEPLOYER")
            accounts[0].transfer(deployer, 100e18)
        elif network.show_active() == "development" or network.show_active() == "hardhat":
            deployer = "0x8B64fA5Fd129df9c755eB82dB1e16D6D0Bdf5Bc3"

        self._deployNOTEImpl()
        self._deployNOTEProxy()

 
    def deployGovernor(self):
        if self.governor:
            print("Governor deployed at {}".format(self.governor))
            return

        if not self.note:
            self.deployNOTE()

        governorConfig = GovernanceConfig["governorConfig"]
        guardian = EnvironmentConfig[self.network]["GuardianMultisig"]
        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(GovernorAlpha, [
            governorConfig["quorumVotes"],
            governorConfig["proposalThreshold"],
            governorConfig["votingDelayBlocks"],
            governorConfig["votingPeriodBlocks"],
            self.config["note"],
            guardian,
            governorConfig["minDelay"],
            0,
        ], "", True)
        self.governor = contract.address
        self._save()

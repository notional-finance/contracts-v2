import json

from brownie import (
    SettleAssetsExternal,
    FreeCollateralExternal,
    TradingAction,
    nTokenMintAction,
    nTokenRedeemAction,
    MigrateIncentives,
    GovernanceAction,
    Views,
    InitializeMarketsAction,
    nTokenAction,
    BatchAction,
    AccountAction,
    ERC1155Action,
    LiquidateCurrencyAction,
    LiquidatefCashAction,
    TreasuryAction,
    PauseRouter,
    Router,
    nProxy
)
from brownie.network import web3
from scripts.deployers.contract_deployer import ContractDeployer

class NotionalDeployer:
    def __init__(self, network, deployer, config={}, persist=True) -> None:
        self.config = config
        self.persist = persist
        self.libs = {}
        self.actions = {}
        self.routers = {}
        self.notional = None
        self.network = network
        self.deployer = deployer
        self._load()

    def _load(self):
        if self.persist:
            with open("v2.{}.json".format(self.network), "r") as f:
                self.config = json.load(f)
        if "libs" in self.config:
            self.libs = self.config["libs"]
        if "actions" in self.config:
            self.actions = self.config["actions"]
        if "routers" in self.config:
            self.routers = self.config["routers"]
        if "notional" in self.config:
            self.notional = self.config["notional"]
    
    def _save(self):
        self.config["libs"] = self.libs
        self.config["actions"] = self.actions
        self.config["routers"] = self.routers
        if self.notional != None:
            self.config["notional"] = self.notional
        if self.persist:
            with open("v2.{}.json".format(self.network), "w") as f:
                json.dump(self.config, f, sort_keys=True, indent=4)

    def _deployLib(self, deployer, contract):
        if contract._name in self.libs:
            print("{} deployed at {}".format(contract._name, self.libs[contract._name]))
            return

        # Make sure isLib is set to true
        # This ensures that map.json only contains 1 copy of the lib
        deployed = deployer.deploy(contract, [], "", False, True)
        self.libs[contract._name] = deployed.address
        # Re-deploy dependent contracts
        self.actions = {}
        self.routers = {}
        self.notional = None
        self._save()

    def deployLibs(self):
        deployer = ContractDeployer(self.deployer, self.libs)
        self._deployLib(deployer, SettleAssetsExternal)
        self._deployLib(deployer, FreeCollateralExternal)
        self._deployLib(deployer, TradingAction)
        self._deployLib(deployer, nTokenMintAction)
        self._deployLib(deployer, nTokenRedeemAction)
        self._deployLib(deployer, MigrateIncentives)

    def _deployAction(self, deployer, contract, args=[]):
        if contract._name in self.actions:
            print("{} deployed at {}".format(contract._name, self.actions[contract._name]))
            return

        deployed = deployer.deploy(contract, args)
        self.actions[contract._name] = deployed.address
        # Re-deploy dependent contracts
        self.routers = {}
        self.notional = None
        self._save()

    def deployActions(self):
        deployer = ContractDeployer(self.deployer, self.actions, self.libs)
        self._deployAction(deployer, GovernanceAction)
        # Brownie and Hardhat do not compile to the same bytecode for this contract, during mainnet
        # deployment. Therefore, when we deploy to mainnet we actually deploy the artifact generated
        # by the hardhat deployment here. NOTE: this artifact must be generated, the artifact here will
        # not be correct for future upgrades.
        # contracts["Governance"] = deployArtifact("./scripts/mainnet/GovernanceAction.json", [],
        #   deployer, "Governance")
        self._deployAction(deployer, Views)
        self._deployAction(deployer, InitializeMarketsAction)
        self._deployAction(deployer, nTokenAction)
        self._deployAction(deployer, BatchAction)
        self._deployAction(deployer, AccountAction)
        self._deployAction(deployer, ERC1155Action)
        self._deployAction(deployer, LiquidateCurrencyAction)
        self._deployAction(deployer, LiquidatefCashAction)
        self._deployAction(deployer, TreasuryAction, [
            self.config["compound"]["comptroller"],
            self.config["tokens"]["WETH"]["address"]
        ])

    def _deployRouter(self, deployer, contract, args=[]):
        if contract._name in self.routers:
            print("{} deployed at {}".format(contract._name, self.routers[contract._name]))
            return

        deployed = deployer.deploy(contract, args)
        self.routers[contract._name] = deployed.address
        # Re-deploy dependent contracts
        self.notional = None
        self._save()

    def deployPauseRouter(self):
        deployer = ContractDeployer(self.deployer, self.routers)
        self._deployRouter(deployer, PauseRouter, [
            self.actions["Views"],
            self.actions["LiquidateCurrencyAction"],
            self.actions["LiquidatefCashAction"]
        ])

    def deployRouter(self):
        deployer = ContractDeployer(self.deployer, self.routers)
        self._deployRouter(deployer, Router, [
            self.actions["GovernanceAction"],
            self.actions["Views"],
            self.actions["InitializeMarketsAction"],
            self.actions["nTokenAction"],
            self.actions["BatchAction"],
            self.actions["AccountAction"],
            self.actions["ERC1155Action"],
            self.actions["LiquidateCurrencyAction"],
            self.actions["LiquidatefCashAction"],
            self.config["compound"]["ctokens"]["ETH"]["address"],
            self.actions["TreasuryAction"],
        ])

    def deployProxy(self):
        # Already deployed
        if self.notional != None:
            print("Notional deployed at {}".format(self.notional))
            return

        initializeData = web3.eth.contract(abi=Router.abi).encodeABI(
            fn_name="initialize", args=[self.deployer.address, self.routers["PauseRouter"], self.routers["Router"]]
        )

        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(nProxy, [self.routers["Router"], initializeData])
        self.notional = contract.address
        self._save()

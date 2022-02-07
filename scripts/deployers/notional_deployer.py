import json
import subprocess

from brownie import (
    accounts, 
    network,
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

class NotionalDeployer:
    def __init__(self, network, deployer) -> None:
        self.libs = {}
        self.actions = {}
        self.routers = {}
        self.notional = None
        self.network = network
        self.deployer = deployer

    def deployContract(self, ctx, name, contract, args):
        print("Deploying {}".format(name))
        if name in ctx:
            print("{} deployed at {}".format(name, self.libs[name]))
        else:
            try:
                lib = contract.deploy(*args, {"from": self.deployer})
                ctx[name] = lib.address
            except Exception as e:
                print("Failed to deploy {}: {}".format(name, e))

    def deployLibs(self):
        self.deployContract(self.libs, "SettleAssetsExternal", SettleAssetsExternal, [])
        self.deployContract(self.libs, "FreeCollateralExternal", FreeCollateralExternal, [])
        self.deployContract(self.libs, "TradingAction", TradingAction, [])
        self.deployContract(self.libs, "nTokenMintAction", nTokenMintAction, [])
        self.deployContract(self.libs, "nTokenRedeemAction", nTokenRedeemAction, [])
        self.deployContract(self.libs, "MigrateIncentives", MigrateIncentives, [])

    def deployActions(self):
        self.deployContract(self.actions, "Governance", GovernanceAction, [])
        # Brownie and Hardhat do not compile to the same bytecode for this contract, during mainnet
        # deployment. Therefore, when we deploy to mainnet we actually deploy the artifact generated
        # by the hardhat deployment here. NOTE: this artifact must be generated, the artifact here will
        # not be correct for future upgrades.
        # contracts["Governance"] = deployArtifact("./scripts/mainnet/GovernanceAction.json", [],
        #   deployer, "Governance")
        self.deployContract(self.actions, "Views", Views, [])
        self.deployContract(self.actions, "InitializeMarketsAction", InitializeMarketsAction, [])
        self.deployContract(self.actions, "nTokenAction", InitializeMarketsAction, [])
        self.deployContract(self.actions, "BatchAction", BatchAction, [])
        self.deployContract(self.actions, "AccountAction", AccountAction, [])
        self.deployContract(self.actions, "ERC1155Action", ERC1155Action, [])
        self.deployContract(self.actions, "LiquidateCurrencyAction", LiquidateCurrencyAction, [])
        self.deployContract(self.actions, "LiquidatefCashAction", LiquidatefCashAction, [])
        self.deployContract(self.actions, "TreasuryAction", TreasuryAction, [
            self.config["compound"]["comptroller"],
            self.config["tokens"]["WETH"]["address"]
        ])

    def deployPauseRouter(self):
        self.deployContract(self.routers, "PauseRouter", PauseRouter, [
            self.actions["Views"],
            self.actions["LiquidateCurrencyAction"],
            self.actions["LiquidatefCashAction"]
        ])

    def deployRouter(self):
        self.deployContract(self.routers, "Router", Router, [
            self.actions["Governance"],
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

        ctx = {}
        self.deployContract(ctx, "Notional", nProxy, [self.routers["Router"], initializeData])
        if "Notional" in ctx:
            self.notional = ctx["Notional "]

    def load(self):
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
    
    def save(self):
        self.config["libs"] = self.libs
        self.config["actions"] = self.actions
        self.config["routers"] = self.routers
        if self.notional != None:
            self.config["notional"] = self.notional
        with open("v2.{}.json".format(self.network), "w") as f:
            json.dump(self.config, f, sort_keys=True, indent=4)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    notional = NotionalDeployer(network.show_active(), deployer)
    notional.load()
    notional.deployLibs()
    notional.deployActions()
    notional.deployPauseRouter()
    notional.deployRouter()
    notional.deployProxy()
    notional.save()
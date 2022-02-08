import json

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
from scripts.common import ContractDeployer

class NotionalDeployer:
    def __init__(self, network, deployer) -> None:
        self.libs = {}
        self.actions = {}
        self.routers = {}
        self.notional = None
        self.network = network
        self.deployer = deployer

    def deployLibs(self):
        deployer = ContractDeployer(self.libs, self.deployer)
        deployer.deploy("SettleAssetsExternal", SettleAssetsExternal, [])
        deployer.deploy("FreeCollateralExternal", FreeCollateralExternal, [])
        deployer.deploy("TradingAction", TradingAction, [])
        deployer.deploy("nTokenMintAction", nTokenMintAction, [])
        deployer.deploy("nTokenRedeemAction", nTokenRedeemAction, [])
        deployer.deploy("MigrateIncentives", MigrateIncentives, [])

    def deployActions(self):
        deployer = ContractDeployer(self.actions, self.deployer)
        deployer.deploy("Governance", GovernanceAction, [])
        # Brownie and Hardhat do not compile to the same bytecode for this contract, during mainnet
        # deployment. Therefore, when we deploy to mainnet we actually deploy the artifact generated
        # by the hardhat deployment here. NOTE: this artifact must be generated, the artifact here will
        # not be correct for future upgrades.
        # contracts["Governance"] = deployArtifact("./scripts/mainnet/GovernanceAction.json", [],
        #   deployer, "Governance")
        deployer.deploy("Views", Views, [])
        deployer.deploy("InitializeMarketsAction", InitializeMarketsAction, [])
        deployer.deploy("nTokenAction", InitializeMarketsAction, [])
        deployer.deploy("BatchAction", BatchAction, [])
        deployer.deploy("AccountAction", AccountAction, [])
        deployer.deploy("ERC1155Action", ERC1155Action, [])
        deployer.deploy("LiquidateCurrencyAction", LiquidateCurrencyAction, [])
        deployer.deploy("LiquidatefCashAction", LiquidatefCashAction, [])
        deployer.deploy("TreasuryAction", TreasuryAction, [
            self.config["compound"]["comptroller"],
            self.config["tokens"]["WETH"]["address"]
        ])

    def deployPauseRouter(self):
        deployer = ContractDeployer(self.routers, self.deployer)
        deployer.deploy("PauseRouter", PauseRouter, [
            self.actions["Views"],
            self.actions["LiquidateCurrencyAction"],
            self.actions["LiquidatefCashAction"]
        ])

    def deployRouter(self):
        deployer = ContractDeployer(self.routers, self.deployer)
        deployer.deployer("Router", Router, [
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
        deployer = ContractDeployer(ctx, self.deployer)
        deployer.deploy("Notional", nProxy, [self.routers["Router"], initializeData])
        if "Notional" in ctx:
            self.notional = ctx["Notional"]

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

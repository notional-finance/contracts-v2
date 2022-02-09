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
from scripts.common import ContractDeployer, getDependencies

LIBS = [
    "SettleAssetsExternal",
    "FreeCollateralExternal",
    "TradingAction",
    "nTokenMintAction",
    "nTokenRedeemAction",
    "MigrateIncentives"
]

class NotionalDeployer:
    def __init__(self, network, deployer) -> None:
        self.libs = {}
        self.actions = {}
        self.routers = {}
        self.notional = None
        self.network = network
        self.deployer = deployer

    def deployLibs(self):
        deployer = ContractDeployer(self.deployer, self.libs)
        deployer.deploy(SettleAssetsExternal)
        deployer.deploy(FreeCollateralExternal)
        deployer.deploy(TradingAction)
        deployer.deploy(nTokenMintAction)
        deployer.deploy(nTokenRedeemAction)
        deployer.deploy(MigrateIncentives)

    def deployActions(self):
        deployer = ContractDeployer(self.deployer, self.actions, self.libs)
        deployer.deploy(GovernanceAction)
        # Brownie and Hardhat do not compile to the same bytecode for this contract, during mainnet
        # deployment. Therefore, when we deploy to mainnet we actually deploy the artifact generated
        # by the hardhat deployment here. NOTE: this artifact must be generated, the artifact here will
        # not be correct for future upgrades.
        # contracts["Governance"] = deployArtifact("./scripts/mainnet/GovernanceAction.json", [],
        #   deployer, "Governance")
        deployer.deploy(Views)
        deployer.deploy(InitializeMarketsAction)
        deployer.deploy(nTokenAction)
        deployer.deploy(BatchAction)
        deployer.deploy(AccountAction)
        deployer.deploy(ERC1155Action)
        deployer.deploy(LiquidateCurrencyAction)
        deployer.deploy(LiquidatefCashAction)
        deployer.deploy(TreasuryAction, [
            self.config["compound"]["comptroller"],
            self.config["tokens"]["WETH"]["address"]
        ])

    def deployPauseRouter(self):
        deployer = ContractDeployer(self.deployer, self.routers)
        deployer.deploy(PauseRouter, [
            self.actions["Views"],
            self.actions["LiquidateCurrencyAction"],
            self.actions["LiquidatefCashAction"]
        ])

    def deployRouter(self):
        deployer = ContractDeployer(self.deployer, self.routers)
        deployer.deployer(Router, [
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

        deployer = ContractDeployer(self.deployer)
        deployer.deploy(nProxy, [self.routers["Router"], initializeData])
        if "nProxy" in deployer.context:
            self.notional = deployer.context["nProxy"]

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
    #ctx = {}
    #deployer = ContractDeployer(ctx, deployer, [])
    #deployer.deploy("AccountAction", AccountAction, [], [SettleAssetsExternal, FreeCollateralExternal])
    #notional.load()
    #notional.deployLibs()
    #notional.deployActions()
    #notional.deployPauseRouter()
    #notional.deployRouter()
    #notional.deployProxy()
    #notional.save()

import json

from brownie import (
    AccountAction,
    BatchAction,
    CalculationViews,
    ERC1155Action,
    FreeCollateralExternal,
    GovernanceAction,
    InitializeMarketsAction,
    LiquidateCurrencyAction,
    LiquidatefCashAction,
    MigrateIncentives,
    PauseRouter,
    Router,
    SettleAssetsExternal,
    TradingAction,
    TreasuryAction,
    VaultAccountAction,
    VaultAction,
    Views,
    nProxy,
    nTokenAction,
    nTokenMintAction,
    nTokenRedeemAction,
)
from brownie.network import web3
from scripts.common import loadContractFromABI
from scripts.deployers.contract_deployer import ContractDeployer


class NotionalDeployer:
    def __init__(self, network, deployer, dryRun, config=None, persist=True) -> None:
        self.config = config
        self.network = network
        self.persist = persist
        if self.network == "hardhat-fork" or self.network == "mainnet-fork":
            self.network = "mainnet"
            self.persist = False
        self.libs = {}
        self.actions = {}
        self.routers = {}
        self.notional = None
        self.deployer = deployer
        self.dryRun = dryRun
        self._load()

    def _load(self):
        if self.config is None:
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
            self.proxy = loadContractFromABI(
                "NotionalProxy", self.config["notional"], "abi/Notional.json"
            )

    def _save(self):
        self.config["libs"] = self.libs
        self.config["actions"] = self.actions
        self.config["routers"] = self.routers
        if self.notional is not None:
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
        if self.dryRun:
            print("Will deploy library {}".format(contract._name))
        else:
            deployed = deployer.deploy(contract, [], "", True, True)
            self.libs[contract._name] = deployed.address
            self._save()

    def deployLibs(self):
        deployer = ContractDeployer(self.deployer, {}, self.libs)
        self._deployLib(deployer, SettleAssetsExternal)
        self._deployLib(deployer, FreeCollateralExternal)
        self._deployLib(deployer, TradingAction)
        self._deployLib(deployer, nTokenMintAction)
        self._deployLib(deployer, nTokenRedeemAction)
        self._deployLib(deployer, MigrateIncentives)

    def _deployAction(self, deployer, contract, args=None):
        if contract._name in self.actions:
            print("{} deployed at {}".format(contract._name, self.actions[contract._name]))
            return

        if self.dryRun:
            print("Will deploy action contract {}".format(contract._name))
        else:
            deployed = deployer.deploy(contract, args, "", True)
            self.actions[contract._name] = deployed.address
            self._save()

    def deployAction(self, action, args=None):
        deployer = ContractDeployer(self.deployer, self.actions, self.libs)
        self._deployAction(deployer, action, args)

    def deployActions(self):
        deployer = ContractDeployer(self.deployer, self.actions, self.libs)
        self._deployAction(deployer, GovernanceAction)
        # Brownie and Hardhat do not compile to the same bytecode for this contract, during mainnet
        # deployment. Therefore, when we deploy to mainnet we actually deploy the artifact generated
        # by the hardhat deployment here. NOTE: this artifact must be generated, the artifact here
        # will not be correct for future upgrades.
        # contracts["Governance"] = deployArtifact("./scripts/mainnet/GovernanceAction.json", [],
        #   deployer, "Governance")
        self._deployAction(deployer, Views)
        self._deployAction(deployer, CalculationViews)
        self._deployAction(deployer, InitializeMarketsAction)
        self._deployAction(deployer, nTokenAction)
        self._deployAction(deployer, BatchAction)
        self._deployAction(deployer, AccountAction)
        self._deployAction(deployer, ERC1155Action)
        self._deployAction(deployer, LiquidateCurrencyAction)
        self._deployAction(deployer, LiquidatefCashAction)
        self._deployAction(deployer, TreasuryAction, [self.config["compound"]["comptroller"]])
        self._deployAction(deployer, VaultAccountAction)
        self._deployAction(deployer, VaultAction)

    def _deployRouter(self, deployer, contract, args=[]):
        if contract._name in self.routers:
            print("{} deployed at {}".format(contract._name, self.routers[contract._name]))
            return

        if self.dryRun:
            print("Will deploy {} with args:".format(contract._name))
            # Print this for hardhat verification
            print(
                {
                    n["name"]: args[0][i]
                    for (i, n) in enumerate(contract.deploy.abi["inputs"][0]["components"])
                }
            )
        else:
            deployed = deployer.deploy(contract, args, "", True)
            print("Deployed {} with args:".format(contract._name))
            print(
                {
                    n["name"]: args[0][i]
                    for (i, n) in enumerate(contract.deploy.abi["inputs"][0]["components"])
                }
            )

            self.routers[contract._name] = deployed.address
            self._save()

    def deployPauseRouter(self):
        deployer = ContractDeployer(self.deployer, self.routers)
        self._deployRouter(
            deployer,
            PauseRouter,
            [
                self.actions["Views"],
                self.actions["LiquidateCurrencyAction"],
                self.actions["LiquidatefCashAction"],
                self.actions["CalculationViews"],
            ],
        )

    def deployRouter(self):
        deployer = ContractDeployer(self.deployer, self.routers)
        self._deployRouter(
            deployer,
            Router,
            [
                (
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
                    self.actions["CalculationViews"],
                    self.actions["VaultAccountAction"],
                    self.actions["VaultAction"],
                )
            ],
        )

    def upgradeProxy(self, oldRouter):
        print("Upgrading router from {} to {}".format(oldRouter, self.routers["Router"]))
        self.proxy.upgradeTo(self.routers["Router"], {"from": self.deployer})

    def deployProxy(self):
        # Already deployed
        if self.notional is not None:
            print("Notional deployed at {}".format(self.notional))
            # Check if proxy needs to be upgraded
            impl = self.proxy.getImplementation()
            if impl != self.routers["Router"]:
                self.upgradeProxy(impl)
            else:
                print("Router is up to date")
            return

        deployer = ContractDeployer(self.deployer)
        initializeData = web3.eth.contract(abi=Router.abi).encodeABI(
            fn_name="initialize",
            args=[self.deployer.address, self.routers["PauseRouter"], self.routers["Router"]],
        )
        contract = deployer.deploy(nProxy, [self.routers["Router"], initializeData], "", True)
        self.notional = contract.address
        self._save()

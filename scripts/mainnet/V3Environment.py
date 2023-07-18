import json
from brownie import (
    accounts,
    Contract, 
    interface, 
    ZERO_ADDRESS,
    MigratePrimeCash, 
    nProxy, 
    Router, 
    CompoundV2HoldingsOracle, 
    MockERC20, 
    ProportionalRebalancingStrategy
)
from tests.helpers import get_interest_rate_curve
from scripts.primeCashOracle import CompoundConfig
from scripts.deployment import deployNotionalContracts, deployBeacons

def getEnvironment(accounts, configFile, deploy=True, migrate=False):
    with open(configFile, "r") as j:
        config = json.load(j)
    return V3Environment(accounts, config, deploy, migrate)

class V3Environment:
    def __init__(self, accounts, config, deploy=True, migrate=True):
        notionalInterfaceABI = interface.NotionalProxy.abi
        self.deployer = accounts[0]
        self.notional = Contract.from_abi(
            "Notional", config["notional"], abi=notionalInterfaceABI
        )
        self.proxy = Contract.from_abi(
            "Notional", config["notional"], abi=nProxy.abi
        )
        self.router = Contract.from_abi(
            "Notional", config["notional"], abi=Router.abi
        )

        self.tokens = {
            'DAI': Contract.from_abi('DAI', config['tokens']['DAI']['address'], MockERC20.abi),
            'USDC': Contract.from_abi('USDC', config['tokens']['USDC']['address'], MockERC20.abi),
            'WBTC': Contract.from_abi('WBTC', config['tokens']['WBTC']['address'], MockERC20.abi),
            'WETH': Contract.from_abi('WETH', config['tokens']['WETH']['address'], MockERC20.abi),
            'wstETH': Contract.from_abi('wstETH', config['tokens']['wstETH']['address'], MockERC20.abi),
            'FRAX': Contract.from_abi('FRAX', config['tokens']['FRAX']['address'], MockERC20.abi),
        }

        self.owner = self.notional.owner()
        self.pauseRouter = self.router.pauseRouter()
        self.guardian = self.router.pauseGuardian()
        self.multisig = "0x02479BFC7Dce53A02e26fE7baea45a0852CB0909"

        if migrate:
            deployBeacons(self.deployer, self.notional)
            deploy = True

        if deploy:
            comptroller = ZERO_ADDRESS
            if "compound" in config:
                comptroller = config["compound"]["comptroller"]

            self.rebalancingStrategy = ProportionalRebalancingStrategy.deploy(
                config["notional"], 
                {"from": self.deployer}
            )

            (self.finalRouter, self.pauseRouter, self.contracts) = deployNotionalContracts(
                self.deployer, 
                Comptroller=comptroller,
                RebalancingStrategy=self.rebalancingStrategy
            )

        if migrate:
            self.patchFix = MigratePrimeCash.deploy(
                self.proxy.getImplementation(),
                self.pauseRouter.address,
                self.proxy.address,
                {"from": self.deployer}
            )

            # Deploys Prime Cash Oracles
            self.pETH = CompoundV2HoldingsOracle.deploy([
                self.notional,
                CompoundConfig["ETH"]["underlying"],
                CompoundConfig["ETH"]["cToken"],
                self.notional.getCurrencyAndRates(1)["assetRate"]["rateOracle"],
            ], {"from": self.deployer})

            self.pDAI = CompoundV2HoldingsOracle.deploy([
                self.notional,
                CompoundConfig["DAI"]["underlying"],
                CompoundConfig["DAI"]["cToken"],
                self.notional.getCurrencyAndRates(2)["assetRate"]["rateOracle"]
            ], {"from": self.deployer})

            self.pUSDC = CompoundV2HoldingsOracle.deploy([
                self.notional,
                CompoundConfig["USDC"]["underlying"],
                CompoundConfig["USDC"]["cToken"],
                self.notional.getCurrencyAndRates(3)["assetRate"]["rateOracle"],
            ], {"from": self.deployer})

            self.pWBTC = CompoundV2HoldingsOracle.deploy([
                self.notional,
                CompoundConfig["WBTC"]["underlying"],
                CompoundConfig["WBTC"]["cToken"],
                self.notional.getCurrencyAndRates(4)["assetRate"]["rateOracle"],
            ], {"from": self.deployer})

            self.primeCashOracles = { 'ETH': self.pETH, 'DAI': self.pDAI, 'USDC': self.pUSDC, 'WBTC': self.pWBTC }

            self.tokens['cETH'] = Contract.from_abi('cETH', CompoundConfig['ETH']['cToken'], MockERC20.abi)
            self.tokens['cDAI'] = Contract.from_abi('cDAI', CompoundConfig['DAI']['cToken'], MockERC20.abi)
            self.tokens['cUSDC'] = Contract.from_abi('cUSDC', CompoundConfig['USDC']['cToken'], MockERC20.abi)
            self.tokens['cWBTC'] = Contract.from_abi('cWBTC', CompoundConfig['WBTC']['cToken'], MockERC20.abi)
        else:
            self.notional.upgradeTo(self.finalRouter, {"from": self.owner})


    def setMigrationSettings(self):
        # TODO: change these...
        self.patchFix.setMigrationSettings(
            1,
            [
                get_interest_rate_curve(),
                self.primeCashOracles['ETH'],
                12, # 60 min oracle rate window
                True,
                'ETH',
                'Ether',
                [
                    get_interest_rate_curve(
                        kinkUtilization1=15,
                        kinkUtilization2=80,
                        kinkRate1=21,
                        kinkRate2=60,
                        maxRateUnits=120,
                        feeRatePercent=8,
                        minFeeRateBPS=0,
                        maxFeeRateBPS=100,
                    ),
                    get_interest_rate_curve(
                        kinkUtilization1=15,
                        kinkUtilization2=80,
                        kinkRate1=21,
                        kinkRate2=56,
                        maxRateUnits=120,
                        feeRatePercent=10,
                        minFeeRateBPS=15,
                        maxFeeRateBPS=100,
                    ),
                ],
                []
            ],
            {"from": self.owner}
        )

        self.patchFix.setMigrationSettings(
            2,
            [
                get_interest_rate_curve(),
                self.primeCashOracles['DAI'],
                12, # 60 min oracle rate window
                True,
                'DAI',
                'Dai Stablecoin',
                [get_interest_rate_curve(
                    kinkUtilization1=15,
                    kinkUtilization2=80,
                    kinkRate1=21,
                    kinkRate2=48,
                    maxRateUnits=120,
                    feeRatePercent=10,
                    minFeeRateBPS=15,
                    maxFeeRateBPS=100,
                )] * 3,
                []
            ],
            {"from": self.owner}
        )

        self.patchFix.setMigrationSettings(
            3,
            [
                get_interest_rate_curve(),
                self.primeCashOracles['USDC'],
                12, # 60 min oracle rate window
                True,
                'USDC',
                'USD Coin',
                [get_interest_rate_curve(
                    kinkUtilization1=15,
                    kinkUtilization2=80,
                    kinkRate1=21,
                    kinkRate2=48,
                    maxRateUnits=120,
                    feeRatePercent=10,
                    minFeeRateBPS=15,
                    maxFeeRateBPS=100,
                )] * 3,
                []
            ],
            {"from": self.owner}
        )

        self.patchFix.setMigrationSettings(
            4,
            [
                get_interest_rate_curve(),
                self.primeCashOracles['WBTC'],
                12, # 60 min oracle rate window
                True,
                'WBTC',
                'Wrapped Bitcoin',
                [get_interest_rate_curve(
                    kinkUtilization1=15,
                    kinkUtilization2=80,
                    kinkRate1=21,
                    kinkRate2=30,
                    maxRateUnits=80,
                    feeRatePercent=10,
                    minFeeRateBPS=15,
                    maxFeeRateBPS=100,
                )] * 2,
                []
            ],
            {"from": self.owner}
        )

    def runMigrationPrerequisites(self):
        # Settle all outstanding accounts
        # Settle all negative cash balances
        pass

    def upgradeToV3(self):
        self.runMigrationPrerequisites()
        self.setMigrationSettings()

        # TODO: this is not listed on the current router so we can't set it
        # need to upgrade the router to include the missing one
        # self.notional.setPauseRouterAndGuardian(self.pauseRouter, self.guardian, {"from": self.owner})
        self.notional.transferOwnership(self.patchFix, False, {"from": self.owner})

        # Pause Notional using the new pauseRouter that allows claimOwnership
        # self.notional.upgradeTo(self.pauseRouter, {"from": self.guardian})

        # Inside here we can update totalfCash debts if required
        manager = accounts.at("0x02479BFC7Dce53A02e26fE7baea45a0852CB0909", force=True)
        self.patchFix.updateTotalfCashDebt(1, [
            [1679616000, 1003407512775],
            [1687392000, 201970086079]
        ], {"from": manager})
        self.patchFix.updateTotalfCashDebt(2, [
            [1679616000, 1072883461002390],
            [1687392000, 789570035516478],
            [1695168000, 52008307749624],
            [1702944000, 275220459188932]
        ], {"from": manager})
        self.patchFix.updateTotalfCashDebt(3, [
            [1679616000, 1457772038632780],
            [1687392000, 1162183350991920],
            [1695168000, 32997025882811],
            [1702944000, 576507718708683]
        ], {"from": manager})
        self.patchFix.updateTotalfCashDebt(4, [
            [1679616000, 3539631484],
            [1687392000, 1300752453]
        ], {"from": manager})

        # Call Upgrade Patch Fix
        self.patchFix.atomicPatchAndUpgrade({"from": self.owner})

        # At this point, Notional V3 is upgraded but paused
        self.notional.upgradeTo(self.finalRouter, {"from": self.owner})

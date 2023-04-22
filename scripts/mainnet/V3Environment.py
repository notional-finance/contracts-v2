import json
from brownie import (
    accounts,
    Contract, 
    interface, 
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

with open("v2.mainnet.json", "r") as j:
    MAINNET = json.load(j)

class V3Environment:
    def __init__(self, accounts):
        notionalInterfaceABI = interface.NotionalProxy.abi
        self.deployer = accounts[0]
        self.notional = Contract.from_abi(
            "Notional", MAINNET["notional"], abi=notionalInterfaceABI
        )
        self.proxy = Contract.from_abi(
            "Notional", MAINNET["notional"], abi=nProxy.abi
        )
        self.router = Contract.from_abi(
            "Notional", MAINNET["notional"], abi=Router.abi
        )

        deployBeacons(self.deployer, self.notional)
    
        self.rebalancingStrategy = ProportionalRebalancingStrategy.deploy(MAINNET["notional"], {"from": self.deployer})

        (self.finalRouter, self.pauseRouter, self.contracts) = deployNotionalContracts(
            self.deployer, 
            Comptroller=MAINNET["compound"]["comptroller"],
            RebalancingStrategy=self.rebalancingStrategy
        )

        self.patchFix = MigratePrimeCash.deploy(
            self.proxy.getImplementation(),
            self.pauseRouter.address,
            self.proxy.address,
            {"from": self.deployer}
        )

        self.owner = self.notional.owner()
        self.pauseRouter = self.router.pauseRouter()
        self.guardian = self.router.pauseGuardian()
        self.multisig = "0x02479BFC7Dce53A02e26fE7baea45a0852CB0909"

        self.tokens = {
            'DAI': Contract.from_abi('DAI', CompoundConfig['DAI']['underlying'], MockERC20.abi),
            'USDC': Contract.from_abi('USDC', CompoundConfig['USDC']['underlying'], MockERC20.abi),
            'WBTC': Contract.from_abi('WBTC', CompoundConfig['WBTC']['underlying'], MockERC20.abi),
            'cETH': Contract.from_abi('cETH', CompoundConfig['ETH']['cToken'], MockERC20.abi),
            'cDAI': Contract.from_abi('cDAI', CompoundConfig['DAI']['cToken'], MockERC20.abi),
            'cUSDC': Contract.from_abi('cUSDC', CompoundConfig['USDC']['cToken'], MockERC20.abi),
            'cWBTC': Contract.from_abi('cWBTC', CompoundConfig['WBTC']['cToken'], MockERC20.abi),
        }

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

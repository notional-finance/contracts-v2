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
import brownie
from tests.helpers import get_interest_rate_curve
from scripts.primeCashOracle import CompoundConfig
from scripts.deployment import deployNotionalContracts, deployBeacons
from tests.constants import DECIMALS_INTERNAL, CURRENCY_ID_TO_SYMBOL, SECONDS_IN_YEAR, CURRENCY_ID_TO_UNDERLYING_DECIMALS, CURRENCY_ID_TO_UNDERLYING_ADDRESS, CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS
from datetime import datetime
from brownie.network.state import Chain
from tests.helpers import get_balance_trade_action, get_balance_action
import math
import eth_abi
import pytest
from gql import gql, Client
from gql.transport.requests import RequestsHTTPTransport
import time


with open("v2.mainnet.json", "r") as j:
    MAINNET = json.load(j)

class V3Environment:
    def __init__(self, accounts):
        self.deployer = accounts[0]
    
        self.rebalancingStrategy = ProportionalRebalancingStrategy.deploy(MAINNET["notional"], {"from": self.deployer})

        (self.finalRouter, self.pauseRouter, self.contracts) = deployNotionalContracts(
            self.deployer, 
            Comptroller=MAINNET["compound"]["comptroller"],
            RebalancingStrategy=self.rebalancingStrategy
        )
        notionalInterfaceABI = interface.NotionalProxy.abi # ContractsV2PrivateProject._build.get("NotionalProxy")["abi"]

        self.notional = Contract.from_abi(
            "Notional", MAINNET["notional"], abi=notionalInterfaceABI
        )
        self.proxy = Contract.from_abi(
            "Notional", MAINNET["notional"], abi=nProxy.abi
        )
        self.router = Contract.from_abi(
            "Notional", MAINNET["notional"], abi=Router.abi
        )

        deployBeacons(self.deployer, self.proxy)

        self.patchFix = MigratePrimeCash.deploy(
            self.proxy.getImplementation(),
            self.finalRouter.address,
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
                        maxRate25BPS=120,
                        feeRatePercent=8,
                        minFeeRateBPS=0,
                        maxFeeRateBPS=100,
                    ),
                    get_interest_rate_curve(
                        kinkUtilization1=15,
                        kinkUtilization2=80,
                        kinkRate1=21,
                        kinkRate2=56,
                        maxRate25BPS=120,
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
                    maxRate25BPS=120,
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
                    maxRate25BPS=120,
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
                    maxRate25BPS=80,
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
            [1679616000, 3636251038],
            [1687392000, 1300752453]
        ], {"from": manager})

        # Call Upgrade Patch Fix
        self.patchFix.atomicPatchAndUpgrade({"from": self.owner})

    # Fetch account IDs from notional's subgraph
    def getAccountIds(self, block):
        # Connect with theGraph
        sample_transport = RequestsHTTPTransport(
            url="https://api.thegraph.com/subgraphs/name/notional-finance/mainnet-v2",
            verify=True,
            retries=10,
        )
        client = Client(
            transport=sample_transport
        )

        i = 0
        while True:
            query = gql('''
                        {
        accounts(block:{number:''' +(block)+ '''}, first: 1000, skip:''' + str(i) + '''){
            id
        }
        }''')
            response = client.execute(query)
            accounts = response['accounts']
            if accounts == []:
                return data
            if i == 0:
                data = accounts
            else:
                data += accounts
            i += 1000


    def getVaults(self, block):
        # Connect with theGraph
        sample_transport = RequestsHTTPTransport(
            url="https://api.thegraph.com/subgraphs/name/notional-finance/mainnet-v2",
            verify=True,
            retries=10,
        )
        client = Client(
            transport=sample_transport
        )

        query = gql('''
                        {
        leveragedVaults(block:{number:''' +(str(block))+ '''}, first: 1000){
            vaultAddress
        }
        }''')
        response = client.execute(query)
        return response['leveragedVaults']


    def getVaultMaturities(self, block, vault):
        # Connect with theGraph
        sample_transport = RequestsHTTPTransport(
            url="https://api.thegraph.com/subgraphs/name/notional-finance/mainnet-v2",
            verify=True,
            retries=10,
        )
        client = Client(
            transport=sample_transport
        )

        query = gql('''
                        {
        leveragedVaults(block:{number:''' +(str(block))+ '''}, where:{vaultAddress:"''' +(vault)+ '''"}, first: 1000){
            maturities{
                maturity
            }
        }
        }''')
        response = client.execute(query)
        return response['leveragedVaults'][0]["maturities"]

    
    def getVaultPrimaryBorrowCurrency(self, block, vault):
        # Connect with theGraph
        sample_transport = RequestsHTTPTransport(
            url="https://api.thegraph.com/subgraphs/name/notional-finance/mainnet-v2",
            verify=True,
            retries=10,
        )
        client = Client(
            transport=sample_transport
        )

        query = gql('''
                        {
        leveragedVaults(block:{number:''' +(str(block))+ '''}, where:{vaultAddress:"''' +str((vault))+ '''"}, first: 1000){
            primaryBorrowCurrency{
                id
            }
        }
        }''')
        response = client.execute(query)
        return response['leveragedVaults'][0]["primaryBorrowCurrency"]['id']

    def getBlockAtTimestamp(self, timestamp):
        # Connect with theGraph
        sample_transport = RequestsHTTPTransport(
            url="https://api.thegraph.com/subgraphs/name/blocklytics/ethereum-blocks",
            verify=True,
            retries=10,
        )
        client = Client(
            transport=sample_transport
        )

        query = gql('''
        {
        blocks(first:1, where:{timestamp_gt:''' +(str(timestamp))+ '''}, orderBy:timestamp, orderDirection:asc){
            number
            }
        }''')
        response = client.execute(query)
        return response['blocks'][0]["number"]

    def getAccountPositions(self, address):
        account = self.notional.getAccount(address)
        dict = {}
        dict['Account Address'] = address
        dict['Free collateral (ETH)'] = self.notional.getFreeCollateral(address)[0] / DECIMALS_INTERNAL

        for i in account[1]:
            if i[0] != 0:
                symbol = CURRENCY_ID_TO_SYMBOL[i[0]]
                dict[symbol] = {
                    'p{} Underlying value'.format(symbol): self.convertPCashToUnderlying(i[0], i[1]) / DECIMALS_INTERNAL,
                    'n{} Underlying value'.format(symbol): self.nTokenToUnderlying(i[0], i[2]) / DECIMALS_INTERNAL} 

        for j in account[2]:
            symbol = CURRENCY_ID_TO_SYMBOL[j[0]]
            if j[2] == 1:
                dict[symbol].update({'f{} {} {}'.format(symbol, j[1], datetime.fromtimestamp(j[1]).date()): j[3] / DECIMALS_INTERNAL})
            elif j[2] == 2:
                dict[symbol].update(
                    {'LT {}'.format(datetime.fromtimestamp(j[1]).date()): j[3] / DECIMALS_INTERNAL})
            elif j[3] == 3:
                dict[symbol].update(
                    {'LT {}'.format(datetime.fromtimestamp(j[1]).date()): j[3] / DECIMALS_INTERNAL})
            elif j[4] == 4:
                dict[symbol].update(
                    {'LT {}'.format(datetime.fromtimestamp(j[1]).date()): j[3] / DECIMALS_INTERNAL})
        return dict

    def nTokenToUnderlying(self, currencyId, amount):
        return self.getValuePerNToken(currencyId) * amount


    def getAssetExchangeRate(self, currencyId):
        return self.notional.getCurrencyAndRates(currencyId)[3][1]/1e10/self.getUnderlyingCurrencyDecimals(currencyId)


    def convertPCashToUnderlying(self, currencyId, pCashAmount):
        if currencyId == 1:
            interface.CEtherInterface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint({"from": self.multiCurrencyAccount, "value":0.01e18})
        else:  
            interface.CErc20Interface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint(1e8, {"from": self.multiCurrencyAccount})
        primeFactors = self.notional.getPrimeFactorsStored(currencyId)
        pCashAmountInUnderlying = pCashAmount * primeFactors["supplyScalar"]/1e18 * primeFactors["underlyingScalar"]/1e18
        return pCashAmountInUnderlying


    def convertPCashDebtToUnderlying(self, currencyId, pCashAmount):
        if currencyId == 1:
            interface.CEtherInterface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint({"from": self.multiCurrencyAccount, "value":0.01e18})
        else:  
            interface.CErc20Interface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint(1e8, {"from": self.multiCurrencyAccount})
        blocktime = self.chain.time()
        pCashAmountInUnderlying = pCashAmount * self.notional.getPrimeFactors(currencyId, blocktime)["factors"]["debtScalar"]/1e18 * self.notional.getPrimeFactors(currencyId, blocktime)["factors"]["underlyingScalar"]/1e18
        return pCashAmountInUnderlying


    def getUnderlyingCurrencyDecimals(self, currencyId):
        underlyingDecimals = self.notional.getCurrency(currencyId)[1][2]
        return underlyingDecimals


    def getValuePerNToken(self, currencyId):
        nTokenPVUnderlying = self.notional.nTokenPresentValueUnderlyingDenominated(currencyId)/DECIMALS_INTERNAL
        nTokenSupply = self.notional.getNTokenAccount(self.notional.nTokenAddress(currencyId))[1]/DECIMALS_INTERNAL
        return nTokenPVUnderlying/nTokenSupply


    def getLastImpliedRate(self, market):
        return market[5]/1e9
    

    def getOracleRate(self, market):
        return market[6]/1e9


    def getLastImpliedRates(self, currencyId):
        markets = self.notional.getActiveMarkets(currencyId)
        lastImpliedRates = []
        for market in markets:
            lastImpliedRates.append(market[5] / 1e9)
        return lastImpliedRates


    def getFCashUtilization(self, market, currencyId):
        totalFCash = market[2]
        totalCash = market[3] 
        totalCashInUnderlying = self.convertPCashToUnderlying(currencyId, totalCash) 
        utilization = totalFCash / (totalFCash + totalCashInUnderlying)
        return utilization


    def getPCashUtilization(self, currencyId):
        primeFactors = self.notional.getPrimeFactorsStored(currencyId)
        pCash_supply = primeFactors["totalPrimeSupply"]
        pCash_debt = primeFactors["totalPrimeDebt"]
        utilization = pCash_debt / pCash_supply
        return utilization

    def getMarket(self, currencyId, marketIndex):
        return self.notional.getActiveMarkets(currencyId)[marketIndex-1]


    def getTradeImpliedRate(self, fCashChange, cashChange, currencyId, maturity):
        changeInPCashUnderlying = self.convertPCashToUnderlying(currencyId, cashChange) 
        yearCount = (maturity - Chain().time())/SECONDS_IN_YEAR
        tradeImpliedRate = math.log(abs(fCashChange)/abs(changeInPCashUnderlying))/yearCount
        return tradeImpliedRate


    def invariantsLend(self, marketBefore, marketAfter, currencyId):
        # tradeImpliedRate = self.getTradeImpliedRate(marketBefore, marketAfter, currencyId)
        utilizationBefore = self.getFCashUtilization(marketBefore, currencyId)
        lastImpliedRateBefore = self.getLastImpliedRate(marketBefore)
        utilizationAfter = self.getFCashUtilization(marketAfter, currencyId)
        lastImpliedRateAfter = self.getLastImpliedRate(marketAfter)
        # assert tradeImpliedRate < lastImpliedRateAfter
        assert lastImpliedRateAfter < lastImpliedRateBefore
        assert utilizationAfter < utilizationBefore
        
    def invariantsBorrow(self, marketBefore, marketAfter, currencyId):
        # tradeImpliedRate = self.getTradeImpliedRate(marketBefore, marketAfter, currencyId)
        utilizationBefore = self.getFCashUtilization(marketBefore, currencyId)
        lastImpliedRateBefore = self.getLastImpliedRate(marketBefore)
        utilizationAfter = self.getFCashUtilization(marketAfter, currencyId)
        lastImpliedRateAfter = self.getLastImpliedRate(marketAfter)
        # assert tradeImpliedRate > lastImpliedRateAfter
        assert lastImpliedRateAfter > lastImpliedRateBefore
        assert utilizationAfter > utilizationBefore

    def tradeToTargetPCashUtilization(self, currencyId, targetUtilization):
        utilization = self.getPCashUtilization(currencyId)
        # convert pCash to underlying, convert pDebt to underlying
        # borrow pCash diff between 
        pCashSupplyUnderlying = self.notional.getPrimeFactors(currencyId, self.chain.time())["factors"]["totalPrimeSupply"]/DECIMALS_INTERNAL * self.notional.getPrimeFactors(currencyId, self.chain.time())["factors"]["supplyScalar"]/1e18 * self.notional.getPrimeFactors(currencyId, self.chain.time())["factors"]["underlyingScalar"]/1e18
        pCashDebtSupplyInUnderlying = self.notional.getPrimeFactors(currencyId, self.chain.time())["factors"]["totalPrimeDebt"]/DECIMALS_INTERNAL * self.notional.getPrimeFactors(currencyId, self.chain.time())["factors"]["debtScalar"]/1e18 * self.notional.getPrimeFactors(currencyId, self.chain.time())["factors"]["underlyingScalar"]/1e18
        

    def tradeToTargetUtilization(self, currencyId, marketIndex, targetUtilization, account):
        market = self.getMarket(currencyId, marketIndex)
        utilization = self.getFCashUtilization(market, currencyId)
        totalFCash = market[2]
        tradeSize = totalFCash * abs(utilization - targetUtilization) / DECIMALS_INTERNAL
        if utilization < targetUtilization:
            for i in range(0, 10): # utilization < targetUtilization:
                try:
                    self.singleMarketBorrow(currencyId, marketIndex, tradeSize , account)
                except:
                    continue
                market = self.getMarket(currencyId, marketIndex)
                utilization = self.getUtilization(market, currencyId)
                tradeSize = totalFCash * abs(utilization - targetUtilization) / DECIMALS_INTERNAL
                print("Utilization ", utilization)
                i+1
        elif utilization > targetUtilization:
             for i in range(0, 10): #while utilization > targetUtilization:
                try:
                    self.singleMarketLend(currencyId, marketIndex, tradeSize, account)
                except:
                    continue
                market = self.getMarket(currencyId, marketIndex)
                utilization = self.getFCashUtilization(market, currencyId)
                tradeSize = totalFCash * abs(utilization - targetUtilization) / DECIMALS_INTERNAL
                print("Utilization ", utilization)
                i+1


    def getLeverageThreshold(self, currencyId, marketIndex):
        return self.notional.getDepositParameters(currencyId)['leverageThresholds'][marketIndex-1]
        

    def initialize_market(self, currencyId, account):
        self.notional.initializeMarkets(currencyId, False, {'from': account})


    def deposit(self, currencyId, amount, account):
        if currencyId == 1:
            action = get_balance_trade_action(currencyId, "DepositUnderlying", [
                                            ], depositActionAmount = amount * CURRENCY_ID_TO_UNDERLYING_DECIMALS[currencyId]
                                            )
            self.notional.batchBalanceAndTradeAction(account, [action], {"from": account,  "value":amount * 1e18})
        else:
            action = get_balance_trade_action(currencyId, "DepositUnderlying", [
                                            ], depositActionAmount = amount * CURRENCY_ID_TO_UNDERLYING_DECIMALS[currencyId]
                                            )
            self.notional.batchBalanceAndTradeAction(account, [action], {"from": account,})

  
    def singleMarketLend(self, currencyId, marketIndex, amount, account):
        action = get_balance_trade_action(currencyId, "None", [
                                        {"tradeActionType": "Lend", "marketIndex": marketIndex, "notional": amount * DECIMALS_INTERNAL, "minSlippage": 0}
                                        ],
                                        )
        tx= self.notional.batchBalanceAndTradeAction(account, [action], {"from": account,})


    def singleMarketBorrow(self, currencyId, marketIndex, amount, account):
        action = get_balance_trade_action(currencyId, "None", [
                                        {"tradeActionType": "Borrow", "marketIndex": marketIndex, "notional": amount * DECIMALS_INTERNAL, "maxSlippage": 0}
                                        ],
                                        )
        tx = self.notional.batchBalanceAndTradeAction(account, [action], {"from": account,})

    def singleMarketDepositAndLend(self, currencyId, marketIndex, amount, account):
        if currencyId == 1:
            action = get_balance_trade_action(currencyId, "DepositUnderlying", [
                                            {"tradeActionType": "Lend", "marketIndex": marketIndex, "notional": amount * DECIMALS_INTERNAL, "minSlippage": 0}
                                            ], depositActionAmount = amount * CURRENCY_ID_TO_UNDERLYING_DECIMALS[currencyId]
                                            )
            self.notional.batchBalanceAndTradeAction(account, [action], {"from": account,  "value":amount * 1e18})
        else:
            action = get_balance_trade_action(currencyId, "DepositUnderlying", [
                                            {"tradeActionType": "Lend", "marketIndex": marketIndex, "notional": amount * DECIMALS_INTERNAL, "minSlippage": 0}
                                            ], depositActionAmount = amount * CURRENCY_ID_TO_UNDERLYING_DECIMALS[currencyId]
                                            )
            self.notional.batchBalanceAndTradeAction(account, [action], {"from": account,})


    def singleMarketDepositAndBorrow(self, currencyId, marketIndex, amount, account):
        if currencyId == 1:
            action = get_balance_trade_action(currencyId, "DepositUnderlying", [
                                            {"tradeActionType": "Borrow", "marketIndex": marketIndex, "notional": amount * DECIMALS_INTERNAL, "maxSlippage": 0}
                                            ], depositActionAmount = amount * CURRENCY_ID_TO_UNDERLYING_DECIMALS[currencyId]
                                            )
            self.notional.batchBalanceAndTradeAction(account, [action], {"from": account,  "value":amount * 1e18})
        else:
            action = get_balance_trade_action(currencyId, "DepositUnderlying", [
                                            {"tradeActionType": "Borrow", "marketIndex": marketIndex, "notional": amount * DECIMALS_INTERNAL, "maxSlippage": 0}
                                            ], depositActionAmount = amount * CURRENCY_ID_TO_UNDERLYING_DECIMALS[currencyId]
                                            )
            self.notional.batchBalanceAndTradeAction(account, [action], {"from": account,})
    

    def getInterimTradeUtilization(self, currencyId, market, fCashTradeAmount):
        return (market[2]/DECIMALS_INTERNAL + fCashTradeAmount)/ (market[2]/DECIMALS_INTERNAL + self.convertPCashToUnderlying(currencyId, market[3]/DECIMALS_INTERNAL))


    def assertCashSolvency(self, currencyId):
        blocktime = self.chain.time()
        if currencyId == 1:
            notionalUnderlyingBalance = self.notionalProxy.balance()/CURRENCY_ID_TO_UNDERLYING_DECIMALS[1]
            interface.CEtherInterface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint({"from": self.multiCurrencyAccount, "value":0.01e18})
        else:  
            notionalUnderlyingBalance = interface.IERC20(CURRENCY_ID_TO_UNDERLYING_ADDRESS[currencyId]).balanceOf(self.notional.address)/CURRENCY_ID_TO_UNDERLYING_DECIMALS[currencyId]
            interface.CErc20Interface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint(1e8, {"from": self.multiCurrencyAccount})
        notionalUnderlyingCTokenBalance = interface.IERC20(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).balanceOf(self.notional.address)/DECIMALS_INTERNAL
        cTokenExchangeRate = interface.CTokenInterface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).exchangeRateStored()/(1e10*CURRENCY_ID_TO_UNDERLYING_DECIMALS[currencyId])
        notionalCTokenValueInUnderlying = notionalUnderlyingCTokenBalance*cTokenExchangeRate
        pCashSupplyUnderlying = self.notional.getPrimeFactors(currencyId, blocktime)["factors"]["totalPrimeSupply"]/DECIMALS_INTERNAL * self.notional.getPrimeFactors(currencyId, blocktime)["factors"]["supplyScalar"]/1e18 * self.notional.getPrimeFactors(currencyId, blocktime)["factors"]["underlyingScalar"]/1e18
        pCashDebtSupplyInUnderlying = self.notional.getPrimeFactors(currencyId, blocktime)["factors"]["totalPrimeDebt"]/DECIMALS_INTERNAL * self.notional.getPrimeFactors(currencyId, blocktime)["factors"]["debtScalar"]/1e18 * self.notional.getPrimeFactors(currencyId, blocktime)["factors"]["underlyingScalar"]/1e18
        assert (pCashSupplyUnderlying-pCashDebtSupplyInUnderlying) <= (notionalCTokenValueInUnderlying+notionalUnderlyingBalance)
        return pCashSupplyUnderlying-pCashDebtSupplyInUnderlying, notionalCTokenValueInUnderlying+notionalUnderlyingBalance


    def assertScalarMonotonicity(self, primeFactorsBefore, primeFactorsAfter):
        assert primeFactorsBefore['debtScalar'] <= primeFactorsAfter['debtScalar']
        assert primeFactorsBefore['supplyScalar'] <= primeFactorsAfter['supplyScalar']
        assert primeFactorsBefore['underlyingScalar'] <= primeFactorsAfter['underlyingScalar']
        assert primeFactorsAfter['supplyScalar']/primeFactorsBefore['supplyScalar'] <= primeFactorsAfter['debtScalar']/primeFactorsBefore['debtScalar']
    

    def assertPrimeRates(self, currencyId):
        assert self.notional.getPrimeFactors(currencyId, self.chain.time())


    def assertTotalNetFCashIsZero(self, currencyId, maturity, accountsNetfCashPositions):
        nextSettleTime = self.notional.getActiveMarkets(currencyId)[0][1]
        market = self.notional.getMarket(currencyId, maturity, nextSettleTime)
        marketTotalFCash = market["totalfCash"]/DECIMALS_INTERNAL
        accountsNetfCashPosition = accountsNetfCashPositions[str(currencyId)+str(":")+str(maturity)]
        for market in self.notional.getNTokenPortfolio(self.notional.nTokenAddress(currencyId))["netfCashAssets"]:
            if market[1] == maturity:
                accountsNetfCashPosition += market[3]/DECIMALS_INTERNAL
        # THERE IS A DISCREPANCY IN NET TOTAL FCASH DUE TO THE OLD NTOKEN BUG 
        # if maturity == 1679616000:
        #     if currencyId == 2:
        #         accountsNetfCashPosition -= 1347.6741564702243
        #     elif currencyId == 3: 
        #         accountsNetfCashPosition -= 2803.4435052387416
        return marketTotalFCash+accountsNetfCashPosition


    def assertTotalfCashDebtOutstanding(self, currencyId, maturity, accountsNetfCashPositions):
        totalFCashOutstanding = self.notional.getTotalfCashDebtOutstanding(currencyId, maturity)
        totalNegativeFCashOutstanging = accountsNetfCashPositions[str(currencyId)+str(":")+str(maturity)]
        for market in self.notional.getNTokenPortfolio(self.notional.nTokenAddress(currencyId))["netfCashAssets"]:
            if market[1] == maturity:
                totalNegativeFCashOutstanging += market[3]/DECIMALS_INTERNAL
        return totalFCashOutstanding/DECIMALS_INTERNAL, totalNegativeFCashOutstanging


    def assertTotalPCashOutstanding(self, currencyId, accountsNetPCashPositions):
        if currencyId == 1:
            interface.CEtherInterface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint({"from": self.multiCurrencyAccount, "value":0.01e18})
        else:  
            interface.CErc20Interface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint(1e8, {"from": self.multiCurrencyAccount})
        primeFactors = self.notional.getPrimeFactorsStored(currencyId) #self.notional.getPrimeFactors(currencyId, self.chain.time())["factors"]
        totalAccountsPCash = accountsNetPCashPositions[str(currencyId)]
        totalMarketsPCash = 0
        markets = self.notional.getActiveMarkets(currencyId)
        for market in markets:
            totalMarketsPCash += market[3]/DECIMALS_INTERNAL
        totalNTokenPortfolioPCash = self.notional.getNTokenAccount(self.notional.nTokenAddress(currencyId))["cashBalance"]/DECIMALS_INTERNAL
        pCashSupplyUnderlying = primeFactors["totalPrimeSupply"]/DECIMALS_INTERNAL
        self.notional.accruePrimeInterest(currencyId, {'from':self.hotWallet})
        reserve = self.notional.getReserveBalance(currencyId)/DECIMALS_INTERNAL
        return totalNTokenPortfolioPCash + totalMarketsPCash + totalAccountsPCash + reserve, pCashSupplyUnderlying


    def assertTotalPCashDebtOutstanding(self, currencyId, accountsPCashDebtPositions):
        if currencyId == 1:
            interface.CEtherInterface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint({"from": self.multiCurrencyAccount, "value":0.01e18})
        else:  
            interface.CErc20Interface(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId]).mint(1e8, {"from": self.multiCurrencyAccount})
        primeFactors = self.notional.getPrimeFactorsStored(currencyId) #self.notional.getPrimeFactors(currencyId, self.chain.time())["factors"]
        totalAccountsPCashDebt = accountsPCashDebtPositions[str(currencyId)]
        pCashDebt = primeFactors["totalPrimeDebt"]/DECIMALS_INTERNAL
        return totalAccountsPCashDebt, pCashDebt


    def assertTotalNToken(self, currencyId, accountsNTokenPositions):
        totalAccountsNToken = accountsNTokenPositions[str(currencyId)]
        nTokenSupply = self.notional.nTokenTotalSupply(self.notional.nTokenAddress(currencyId))
        return totalAccountsNToken, nTokenSupply


    def approveNotionalAllCurrencies(self, account):
        for currencyId in range(2, self.notional.getMaxCurrencyId()+1):
            interface.ERC20(CURRENCY_ID_TO_UNDERLYING_ADDRESS[currencyId]).approve(self.notional.address, 2 ** 255, {"from": account})


    def approveCompoundAllCurrencies(self, account):
        for currencyId in range(2, self.notional.getMaxCurrencyId()+1):
            interface.ERC20(CURRENCY_ID_TO_UNDERLYING_ADDRESS[currencyId]).approve(CURRENCY_ID_TO_UNDERLYING_CTOKEN_ADDRESS[currencyId], 2 ** 255, {"from": account})


    def getNotionalAccountList(self, block):
        accounts = [self.hotWallet.address, self.ETH_Whale.address, self.DAI_Whale.address, self.USDC_Whale.address, self.WBTC_Whale.address, 
                        self.ETH_Account1.address, self.ETH_Account2.address, self.DAI_Account1.address, self.DAI_Account2.address, self.USDC_Account1.address, self.USDC_Account2.address,
                        self.WBTC_Account1.address, self.WBTC_Account2.address, self.multiCurrencyAccount.address]
        accounts = list(map(lambda x:x.lower(), accounts))
        accountsAtForkedTime = self.getAccountIds(str(16721445))
        for account in accountsAtForkedTime:
            accounts.append(account["id"])
        accounts = list(dict.fromkeys(accounts))
        for currencyId in range(1, self.notional.getMaxCurrencyId()+1):
            accounts.remove(self.notional.nTokenAddress(currencyId))
        return accounts


    def settleAllAccounts(self, block):
        accounts = self.getNotionalAccountList(block)
        for account in accounts:
            try:
                self.notional.getFreeCollateral(account)
            except:
                self.notional.settleAccount(account, {'from': self.hotWallet})


    def settleAllAccountsInitial(self):
        initialSettleAccounts = ['0x005b0743d8b2ed646499dc48b64b95e71b8afa43', '0x00e36331f4b8c6dcd7476f26c20b128ab82e5d5d', '0x02a6a59224c8838772931d596a2f74d8edab9112', '0x04a3b17cfbeef344127e78ad082fecb36ad76d64', '0x0702d9700b29366104e38dd824de118833469fe4', '0x07197a25bf7297c2c41dd09a79160d05b6232bcf', '0x071f090356ceae8b317b23d264cc9152cb3b97d2', '0x0d42c534b0aafe7c65df3df54cfd68e2b7886f67', '0x146ec7ae0f90229bab03f11558bbc6cf0f644aab', '0x1bd3abb6ef058408734ea01ca81d325039cd7bca', '0x1d9f186e485dbd4943fa9788082c8edd45de2d69', '0x29afb1043ed699a89ca0f0942ed6f6f65e794a3d', '0x2a3a69441f2bf06c45cbf302f056363e74720e68', '0x3521a6580cd58177c7fac825c4a54821938afe1d', '0x36ee0c51120c1c4c83ecc65a8a102376863488fa', '0x38ed9b9fb07060e4d8ee43dd191f65461fc9966f', '0x39513f0e303f838411aefd48a1bcc887f785ed19', '0x3d51ef2d5ec9a9ac75f16442cadf75436bb38844', '0x3f60008dfd0efc03f476d9b489d6c5b13b3ebf2c', '0x42492200015c883f24cf5e631208d1081d128666', '0x49e14a6ad7d66906f2c82120de6e2ea75cd132df', '0x4c6337b97e5d146bf2330af8ccd109ff204f2069', '0x54481f435a0ff8ab695fc7c42fb0450ef9a8eea7', '0x545baa3446c668d33f42de1d15548c2cc0388c1b', '0x57622d4c4be22ab9ad3da104dc281d738e6f5b6a', '0x5853ed4f26a3fcea565b3fbc698bb19cdf6deb85', '0x60de7f647df2448ef17b9e0123411724de6e373d', '0x61d656c068b93202ecf787a2872c58b39a277b9b', '0x677f0fb523ecfe8343560ddcaac47e1eab34409a', '0x6858afe372b3a0b3615068f4490b670be0102fc3', '0x694da39965a6a817ce47b7d3efa622b992b382f6', '0x6c99c45b39d1cddb61b272798ea1da2cdac9bcc8', '0x6f3b4096abaed2de7f08405a975d7aafe223ecbe', '0x70f9a75f0c70d44adea421facc4d4024c3198a11', '0x767a60f295aedd958932088f9cd6a4951d8739b6', '0x7e29f9311724bbf88b99e05754750ae7668ad4ba', '0x7f6f138c955e5b1017a12e4567d90c62abb00074', '0x81223bc6f424dd548401408a57190a28caf0c45d', '0x834374e98175524ffecdcc73e344a8123896d29a', '0x8665d75ff2db29355428b590856505459bb675e3', '0x8862dff8730da03dffaf7cf713e3226f98190efb', '0x8b4ea96254229f4e93538319010a17a7a5fbf864', '0x965cf7e7d50b6f38378d8e4e712f1e796c0b9d9c', '0x96dc89dbe84970ee42a2f0b35fb50599e6745ff8', '0x9b2b78003e469a342977e0a078f6aef88077acd9', '0xa4770e170d3c83f53cdc5888e4b583e4678c6727', '0xab8b5d1dd9a8e2d9ae8339aba8bcf05b5fad64af', '0xad023975a8ddcf879c34035a4ccb067127214c06', '0xb52195a516d67315a90691f36fe6520a14bf0dbb', '0xb61fd6f023e4cb04882433b812b195245deb57e5', '0xbdc42066228cb6acd80c1f34ed64c604f392b3da', '0xbdfd4f31c55ccb866ab6ff9ed2863f1a4ceac8d6', '0xbe4f974164586795a429d62cecb145163514f0cd', '0xbfb12bb98b6537b9f70fb19bbc0c468a3a1f09d3', '0xc33abd9621834ca7c6fc9f9cc3c47b9c17b03f9f', '0xc4a267b902685667c68c9731969d9844b78301e1', '0xc7d46b70f3e0ce07915df817723e96c671b4cd65', '0xcaf23340f8fe32a526b03bd07dacf0900323252d', '0xd22886236f453e9407f54cc2706b2e9c87789702', '0xd874387ebb001a6b0bea98072f8de05f8965e51e', '0xda36468efd3c09b6e52a9dc73cf7863a5e5671c4', '0xdf6c74e0387570344c4c36ff77c79fd805c5b5f7', '0xe321bd63cde8ea046b382f82964575f2a5586474', '0xe8fc9031fa2228515be485bab95c16c112d80631', '0xeb0cda1a52f9ac0bd5293bd65b52ed07168e1e8e', '0xeeaa36420519d85efab3b7120ac5afa5a5825bfb', '0xef4b7480e1472755c9c68f6914aa00ef66f8cc97', '0xf22b75ced792a59bde1021a1c34be6f131de612f', '0xf54d8716e4766e7dd0e2279d9bdeb5c503025a8a', '0xfa8568cca1ce6af4a3479b1707091a92ccef62db', '0xfb3375d76cd1c487ee721a92342f9f59ef41e028', '0xfba5c82289a969d8cc2f2fcf45b2a9e5e2a01dd4', '0xfc0c791a1c352497a069232d1c22f265737f00dd', '0xfcb060e09e452eeff142949bec214c187cdf25fa', '0xff488261a687828f2f155b6f234a90558192b9ed']
        for account in initialSettleAccounts:
            try:
                self.notional.getFreeCollateral(account)
            except:
                self.notional.settleAccount(account, {'from': self.hotWallet})


    def getAllMaturities(self, currencyId):
        markets = self.notional.getActiveMarkets(currencyId)
        maturities = []
        for market in markets:
            maturities.append(market[1])
        if len(maturities) > 2:
            maturities.append(int((maturities[2]-maturities[1])/2 + maturities[1]))
        return maturities


    def getAllAccountsPositions(self, block):
        keys = []
        for currencyId in range(1, self.notional.getMaxCurrencyId()+1):
            keys.append(str(currencyId))
        pCashBalances = {keys[i]:0 for i in range(0, len(keys))}

        keys = []
        for currencyId in range(1, self.notional.getMaxCurrencyId()+1):
            keys.append(str(currencyId))
        pCashDebtBalances = {keys[i]:0 for i in range(0, len(keys))}

        keys = []
        for currencyId in range(1, self.notional.getMaxCurrencyId()+1):
            keys.append(str(currencyId))
        nTokenBalances = {keys[i]:0 for i in range(0, len(keys))}

        keys = []
        for currencyId in range(1, self.notional.getMaxCurrencyId()+1):
            maturities = self.getAllMaturities(currencyId)
            maturities.append(1679616000)
            maturities = list(dict.fromkeys(maturities))
            for maturity in maturities:
                keys.append(str(currencyId)+str(":")+str(maturity))
        netFCashPositions = {keys[i]:0 for i in range(0, len(keys))}

        keys = []
        for currencyId in range(1, self.notional.getMaxCurrencyId()+1):
            maturities = self.getAllMaturities(currencyId)
            maturities.append(1679616000)
            maturities = list(dict.fromkeys(maturities))
            for maturity in maturities:
                keys.append(str(currencyId)+str(":")+str(maturity))
        negativeFCashPositions = {keys[i]:0 for i in range(0, len(keys))}

        accounts = self.getNotionalAccountList(block)
        vaults = self.getVaults(block)
        for vaultAddress in vaults:
            vaultAddress = vaultAddress["vaultAddress"]
            maturities = self.getVaultMaturities(block, vaultAddress)
            currencyId = self.getVaultPrimaryBorrowCurrency(block, vaultAddress)
            for maturity in maturities:
                maturity = maturity['maturity']
                if maturity == 1679616000:
                    fCash = -2679.215
                    fCashPosition = netFCashPositions[str(currencyId)+str(":")+str(maturity)]+fCash
                    netFCashPositions.update({str(currencyId)+str(":")+str(maturity): fCashPosition})

                    fCashPosition = negativeFCashPositions[str(currencyId)+str(":")+str(maturity)]+fCash
                    negativeFCashPositions.update({str(currencyId)+str(":")+str(maturity): fCashPosition})
                elif maturity == 1687392000: 
                    fCash = -1497.53280137
                    fCashPosition = netFCashPositions[str(currencyId)+str(":")+str(maturity)]+fCash
                    netFCashPositions.update({str(currencyId)+str(":")+str(maturity): fCashPosition})

                    fCashPosition = negativeFCashPositions[str(currencyId)+str(":")+str(maturity)]+fCash
                    negativeFCashPositions.update({str(currencyId)+str(":")+str(maturity): fCashPosition})
                    
                if maturity > self.chain.time() and maturity != 1687392000 and maturity != 1679616000:
                    vault = self.notional.getVaultState(vaultAddress, maturity)
                    fCashPosition = netFCashPositions[str(currencyId)+str(":")+str(maturity)]+vault["totalDebtUnderlying"]/DECIMALS_INTERNAL
                    netFCashPositions.update({str(currencyId)+str(":")+str(maturity): fCashPosition})

                    fCashPosition = negativeFCashPositions[str(currencyId)+str(":")+str(maturity)]+vault["totalDebtUnderlying"]/DECIMALS_INTERNAL
                    negativeFCashPositions.update({str(currencyId)+str(":")+str(maturity): fCashPosition})

        for account in accounts:
            for currencyId in range(1, self.notional.getMaxCurrencyId()+1):
                accountBalances = self.notional.getAccountBalance(currencyId, account)
                if accountBalances["cashBalance"] < 0:
                    pCashPosition = pCashDebtBalances[str(currencyId)]-accountBalances["cashBalance"]/DECIMALS_INTERNAL
                    pCashDebtBalances.update({str(currencyId): pCashPosition})
                else:
                    pCashPosition = pCashBalances[str(currencyId)]+accountBalances["cashBalance"]/DECIMALS_INTERNAL
                    pCashBalances.update({str(currencyId): pCashPosition})
                nTokenPosition = nTokenBalances[str(currencyId)]+accountBalances["nTokenBalance"]/DECIMALS_INTERNAL
                nTokenBalances.update({str(currencyId): nTokenPosition})
            
            portfolio = self.notional.getAccountPortfolio(account)
            for asset in portfolio:
                if asset[2] == 1:
                    fCashPosition = netFCashPositions[str(asset[0])+str(":")+str(asset[1])]+asset[3]/DECIMALS_INTERNAL
                    netFCashPositions.update({str(asset[0])+str(":")+str(asset[1]): fCashPosition})
                    if asset[3] < 0:
                        fCashPosition = negativeFCashPositions[str(asset[0])+str(":")+str(asset[1])]+asset[3]/DECIMALS_INTERNAL
                        negativeFCashPositions.update({str(asset[0])+str(":")+str(asset[1]): fCashPosition})
        return netFCashPositions, negativeFCashPositions, pCashBalances, pCashDebtBalances, nTokenBalances

def main():
    env = V3Environment(accounts)
    env.chain = Chain()
    env.hotWallet = accounts.at('0xcece1920d4dbb96baf88705ce0a6eb3203ed2eb1', force=True) 
    env.ETH_Whale = accounts.at('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', force=True)
    env.DAI_Whale = accounts.at('0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7', force=True)
    env.USDC_Whale = accounts.at('0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7', force=True)
    env.WBTC_Whale = accounts.at('0x9ff58f4fFB29fA2266Ab25e75e2A8b3503311656', force=True)
    env.USDT_Whale = accounts.at('0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7', force=True)

    env.ETH_Account1 = accounts.at('0xEe009FAF00CF54C1B4387829aF7A8Dc5f0c8C8C5', force=True)
    env.DAI_Account1 = accounts.at('0x1B7BAa734C00298b9429b518D621753Bb0f6efF2', force=True)
    env.USDC_Account1 = accounts.at('0x69498f71c6c260f7be84c4bc6b30cbc2a641d088', force=True)
    env.WBTC_Account1 = accounts.at('0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf', force=True)

    env.ETH_Account2 = accounts.at('0xcAD001c30E96765aC90307669d578219D4fb1DCe', force=True)
    env.DAI_Account2 = accounts.at('0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf', force=True)
    env.USDC_Account2 = accounts.at('0x203520F4ec42Ea39b03F62B20e20Cf17DB5fdfA7', force=True)
    env.WBTC_Account2 = accounts.at('0xBF72Da2Bd84c5170618Fbe5914B0ECA9638d5eb5', force=True)

    env.multiCurrencyAccount = accounts.at("0x8EB8a3b98659Cce290402893d0123abb75E3ab28", force=True)
    env.approveCompoundAllCurrencies(env.multiCurrencyAccount)

    env.notionalProxy = accounts.at(env.notional.address, force=True)

    # Settle all accounts before the v3 migration
    env.settleAllAccountsInitial()

    # Roll forward 0xda36468efd3c09b6e52a9dc73cf7863a5e5671c4
    settlementAccount = "0xda36468efd3c09b6e52a9dc73cf7863a5e5671c4"
    actionWBTC = get_balance_trade_action(4, "None", [{"tradeActionType": "SettleCashDebt", "counterparty": settlementAccount, "amountToSettle": 0,}, {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 1e8, "maxSlippage": 0},],)
    env.notional.batchBalanceAndTradeAction(env.hotWallet, [actionWBTC], {"from": env.hotWallet})

    # Upgrade to V3
    env.upgradeToV3()
    print(env.notional.getPrimeFactors(1, env.chain.time())["factors"])

    allAccountsPositionBeforeSettlement = env.getAllAccountsPositions(env.getBlockAtTimestamp(env.chain.time()))
    netFCashPositions = allAccountsPositionBeforeSettlement[0]
    negativeFCashPositions = allAccountsPositionBeforeSettlement[1]
    positivePCashPositions = allAccountsPositionBeforeSettlement[2]
    pCashDebtPositions = allAccountsPositionBeforeSettlement[3]

    for currencyId in range(1,5):
        print(currencyId, " pCash supply:", env.assertTotalPCashOutstanding(currencyId, positivePCashPositions))
        print(currencyId, " pCashDebt supply:", env.assertTotalPCashDebtOutstanding(currencyId, pCashDebtPositions))

    # Trade once to get rid of the Notional v2 Last Implied Rate
    env.approveNotionalAllCurrencies(env.DAI_Whale)
    env.approveNotionalAllCurrencies(env.USDC_Whale)
    env.approveNotionalAllCurrencies(env.WBTC_Whale)

    env.approveNotionalAllCurrencies(env.DAI_Account1)
    env.approveNotionalAllCurrencies(env.USDC_Account1)
    env.approveNotionalAllCurrencies(env.WBTC_Account1)

    env.approveNotionalAllCurrencies(env.DAI_Account2)
    env.approveNotionalAllCurrencies(env.USDC_Account2)
    env.approveNotionalAllCurrencies(env.WBTC_Account2)

    print("INITIAL CASH SOLVENCY ASSERTION")
    print(env.assertCashSolvency(1))
    print(env.assertCashSolvency(2))
    print(env.assertCashSolvency(3))
    print(env.assertCashSolvency(4))

    env.deposit(1, 10_000, env.ETH_Whale)
    env.deposit(2, 1_000_000, env.DAI_Whale)
    env.deposit(3, 1_000_000, env.USDC_Whale)
    env.deposit(4, 10, env.WBTC_Whale)

    env.singleMarketLend(1, 1, 1, env.ETH_Whale)
    env.singleMarketLend(1, 2, 1, env.ETH_Whale)
    
    env.singleMarketLend(2, 1, 0.01, env.DAI_Whale)
    env.singleMarketLend(2, 2, 0.01, env.DAI_Whale)
    env.singleMarketLend(2, 3, 0.01, env.DAI_Whale)

    env.singleMarketLend(3, 1, 0.01, env.USDC_Whale)
    env.singleMarketLend(3, 2, 0.01, env.USDC_Whale)
    env.singleMarketLend(3, 3, 0.01, env.USDC_Whale)  

    env.singleMarketLend(4, 1, 0.01, env.WBTC_Whale)
    env.singleMarketLend(4, 2, 0.01, env.WBTC_Whale)
    
    print(env.assertCashSolvency(1))
    print(env.assertCashSolvency(2))
    print(env.assertCashSolvency(3))
    print(env.assertCashSolvency(4))

    env.chain.snapshot()

    env.notional.updatePrimeCashCurve(1, (15, 80, 10, 24, 255, 15, 255, 15),  {'from':env.notional.owner()})
    env.notional.updatePrimeCashCurve(2, (15, 80, 10, 24, 255, 15, 255, 15),  {'from':env.notional.owner()})
    env.notional.updatePrimeCashCurve(3, (15, 80, 10, 24, 255, 15, 255, 15),  {'from':env.notional.owner()})
    env.notional.updatePrimeCashCurve(4, (15, 80, 10, 24, 255, 15, 255, 15),  {'from':env.notional.owner()})

    env.notional.updateInterestRateCurve(1, (1,2), ((15, 80, 21, 60, 120, 15, 100, 8), (15, 80, 21, 60, 120,  0, 100, 0)), {'from':env.notional.owner()})
    env.notional.updateInterestRateCurve(2, (1,2,3), ((15, 80, 21, 60, 120, 15, 100, 8), (15, 80, 26, 72, 100, 15, 100, 8), (15, 80, 32, 90, 80, 15, 100, 8)), {'from':env.notional.owner()})
    env.notional.updateInterestRateCurve(3, (1,2,3), ((15, 80, 21, 60, 120, 15, 100, 8), (15, 80, 26, 72, 100, 15, 100, 8), (15, 80, 32, 90, 80, 15, 100, 8)), {'from':env.notional.owner()})
    env.notional.updateInterestRateCurve(4, (1,2), ((15, 80, 21, 60, 120, 15, 100, 8), (15, 80, 26, 72, 100, 15, 100, 8)), {'from':env.notional.owner()})

    env.notional.updateInitializationParameters(1, (0, 0), (500000000, 720000000), {'from': env.notional.owner()})
    env.notional.updateInitializationParameters(4, (0, 0), (500000000, 500000000), {'from': env.notional.owner()})

    env.notional.updateDepositParameters(1, (50000000, 50000000), (720000000, 720000000),{"from": env.notional.owner()})

    env.chain.mine(1, 1679616000)

    # Initialize markets
    env.initialize_market(1, env.hotWallet)
    env.initialize_market(2, env.hotWallet)
    env.initialize_market(3, env.hotWallet)
    env.initialize_market(4, env.hotWallet)
    print("MARKETS INITIALIZED")


    allAccountsPositionPostSettlement = env.getAllAccountsPositions(env.getBlockAtTimestamp(env.chain.time()))
    netFCashPositions = allAccountsPositionPostSettlement[0]
    negativeFCashPositions = allAccountsPositionPostSettlement[1]
    positivePCashPositions = allAccountsPositionPostSettlement[2]
    pCashDebtPositions = allAccountsPositionPostSettlement[3]

    for currencyId in range(1,5):
        print(currencyId, " pCash supply:", env.assertTotalPCashOutstanding(currencyId, positivePCashPositions))
        print(currencyId, " pCashDebt supply:", env.assertTotalPCashDebtOutstanding(currencyId, pCashDebtPositions))

    print(env.assertCashSolvency(1))
    print(env.assertCashSolvency(2))
    print(env.assertCashSolvency(3))
    print(env.assertCashSolvency(4))
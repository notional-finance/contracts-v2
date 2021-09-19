import math
import random

from brownie import MockAggregator, MockCToken, MockValuationLib, cTokenAggregator
from brownie.convert.datatypes import HexString, Wei
from brownie.network.state import Chain
from tests.constants import (
    BASIS_POINT,
    RATE_PRECISION,
    SECONDS_IN_YEAR,
    SETTLEMENT_DATE,
    START_TIME,
)
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_eth_rate_mapping,
    get_fcash_token,
    get_market_curve,
)

chain = Chain()


class ValuationMock:
    ethRates = {1: 1e18, 2: 0.01e18, 3: 0.011e18, 4: 10e18}
    underlyingDecimals = {1: 18, 2: 18, 3: 6, 4: 8}
    cTokenRates = {
        1: Wei(200000000000000000000000000),
        2: Wei(210000000000000000000000000),
        3: Wei(220000000000000),
        4: Wei(23000000000000000),
    }
    nTokenAddress = {
        1: HexString(1, "bytes20"),
        2: HexString(2, "bytes20"),
        3: HexString(3, "bytes20"),
        4: HexString(4, "bytes20"),
    }
    nTokenTotalSupply = {
        1: Wei(10_000_000e8),
        2: Wei(20_000_000e8),
        3: Wei(30_000_000e8),
        4: Wei(40_000_000e8),
    }
    nTokenCashBalance = {
        1: Wei(50_000_000e8),
        2: Wei(60_000_000e8),
        3: Wei(70_000_000e8),
        4: Wei(80_000_000e8),
    }
    nTokenParameters = {1: (85, 90), 2: (86, 91), 3: (80, 88), 4: (75, 80)}
    bufferHaircutDiscount = {
        1: (130, 70, 105),
        2: (105, 95, 106),
        3: (110, 90, 107),
        4: (150, 50, 102),
    }

    markets = {}
    cashGroups = {}
    cTokenAdapters = {}
    ethAggregators = {}
    cTokens = {}

    def __init__(self, account, MockContract):
        MockValuationLib.deploy({"from": account})
        c = account.deploy(MockContract)
        for i in range(1, 5):
            self.cTokens[i] = account.deploy(MockCToken, 8)
            self.cTokens[i].setAnswer(self.cTokenRates[i])
            self.ethAggregators[i] = MockAggregator.deploy(18, {"from": account})
            self.cTokenAdapters[i] = cTokenAggregator.deploy(
                self.cTokens[i].address, {"from": account}
            )

            c.setAssetRateMapping(i, (self.cTokenAdapters[i].address, self.underlyingDecimals[i]))
            self.cashGroups[i] = get_cash_group_with_max_markets(3)
            c.setCashGroup(i, self.cashGroups[i])

            self.ethAggregators[i].setAnswer(self.ethRates[i])
            c.setETHRateMapping(
                i,
                get_eth_rate_mapping(
                    self.ethAggregators[i],
                    buffer=self.bufferHaircutDiscount[i][0],
                    haircut=self.bufferHaircutDiscount[i][1],
                    discount=self.bufferHaircutDiscount[i][2],
                ),
            )

            c.setNTokenValue(
                i,
                self.nTokenAddress[i],
                self.nTokenTotalSupply[i],
                self.nTokenCashBalance[i],
                self.nTokenParameters[i][0],
                self.nTokenParameters[i][1],
            )

            # TODO: change the market curve...
            self.markets[i] = get_market_curve(3, "flat")
            for m in self.markets[i]:
                c.setMarketStorage(i, SETTLEMENT_DATE, m)

        chain.mine(1, timestamp=START_TIME)

        self.mock = c

    def calculate_to_underlying(self, currency, balance):
        return math.trunc(
            (balance * self.cTokenRates[currency] * Wei(1e8))
            / (Wei(1e18) * Wei(10 ** self.underlyingDecimals[currency]))
        )

    def calculate_from_underlying(self, currency, balance):
        return math.trunc(
            (balance * Wei(1e18) * Wei(10 ** self.underlyingDecimals[currency]))
            / (self.cTokenRates[currency] * Wei(1e8))
        )

    def calculate_exchange_rate(self, base, quote):
        return math.trunc(Wei(self.ethRates[base] * 1e18) / self.ethRates[quote])

    def get_discount(self, local, collateral):
        return max(self.bufferHaircutDiscount[local][2], self.bufferHaircutDiscount[collateral][2])

    def calculate_from_eth(self, currency, underlying, rate=None):
        if rate:
            return math.trunc((underlying * Wei(1e18)) / rate)
        else:
            return math.trunc((underlying * Wei(1e18)) / self.ethRates[currency])

    def calculate_to_eth(self, currency, underlying, valueType="haircut", rate=None):
        if valueType == "haircut":
            multiple = (
                self.bufferHaircutDiscount[currency][1]
                if underlying > 0
                else self.bufferHaircutDiscount[currency][0]
            )
        elif valueType == "no-haircut":
            multiple = 100

        if rate:
            return math.trunc((underlying * rate * Wei(multiple)) / (Wei(1e18) * Wei(100)))
        else:
            return math.trunc(
                (underlying * self.ethRates[currency] * Wei(multiple)) / (Wei(1e18) * Wei(100))
            )

    def calculate_ntoken_to_asset(self, currency, nToken, valueType="haircut"):
        if valueType == "haircut":
            return math.trunc(
                (nToken * self.nTokenCashBalance[currency] * self.nTokenParameters[currency][0])
                / (self.nTokenTotalSupply[currency] * 100)
            )
        elif valueType == "no-haircut":
            return math.trunc(
                (nToken * self.nTokenCashBalance[currency]) / self.nTokenTotalSupply[currency]
            )
        elif valueType == "liquidator":
            return math.trunc(
                (nToken * self.nTokenCashBalance[currency] * self.nTokenParameters[currency][1])
                / (self.nTokenTotalSupply[currency] * 100)
            )

    def get_liquidation_factors(self, local, collateral, **kwargs):
        account = 0 if "account" not in kwargs else kwargs["account"].address
        netETHValue = 0 if "netETHValue" not in kwargs else kwargs["netETHValue"]
        localAssetAvailable = (
            0 if "localAssetAvailable" not in kwargs else kwargs["localAssetAvailable"]
        )
        collateralAssetAvailable = (
            0 if "collateralAssetAvailable" not in kwargs else kwargs["collateralAssetAvailable"]
        )
        nTokenHaircutAssetValue = (
            0 if "nTokenHaircutAssetValue" not in kwargs else kwargs["nTokenHaircutAssetValue"]
        )
        if collateral == 0:
            nTokenParameters = "0x{}0000{}00".format(
                hex(self.nTokenParameters[local][1])[2:], hex(self.nTokenParameters[local][0])[2:]
            )
        else:
            nTokenParameters = "0x{}0000{}00".format(
                hex(self.nTokenParameters[collateral][1])[2:],
                hex(self.nTokenParameters[collateral][0])[2:],
            )

        localETHRate = [1e18, self.ethRates[local]] + self.bufferHaircutDiscount[local]
        collateralETHRate = [1e18, self.ethRates[collateral]] + self.bufferHaircutDiscount[
            collateral
        ]
        localAssetRate = [
            self.cTokenAdapters[local].address,
            self.cTokenRates[local],
            10 ** self.underlyingDecimals[local],
        ]
        collateralCashGroup = [
            local if collateral == 0 else collateral,
            3,
            localAssetRate
            if collateral == 0
            else [
                self.cTokenAdapters[collateral].address,
                self.cTokenRates[collateral],
                10 ** self.underlyingDecimals[collateral],
            ],
            0,  # TODO: need to fill this in for fCash
        ]
        isCalculation = False if "isCalculation" not in kwargs else kwargs["isCalculation"]

        return [
            account,
            netETHValue,
            localAssetAvailable,
            collateralAssetAvailable,
            nTokenHaircutAssetValue,
            nTokenParameters,
            localETHRate,
            collateralETHRate,
            localAssetRate,
            collateralCashGroup,
            isCalculation,
        ]


def get_portfolio(
    assetMarketIndexes,
    targetLocalAvailable,
    markets,
    blockTime,
    fCashHaircut=150 * BASIS_POINT,
    debtBuffer=150 * BASIS_POINT,
    currencyId=1,
):
    # split targetLocalAvailable into n assets w/ x PV
    scalars = [random.randint(-1000e8, 1000e8) for i in range(0, len(assetMarketIndexes))]
    scale = targetLocalAvailable / sum(scalars)
    pvArray = [math.trunc(s * scale) for s in scalars]

    portfolio = []
    for marketIndex, pv in zip(assetMarketIndexes, pvArray):
        rate = markets[marketIndex - 1][6]
        if pv < 0:
            rate = rate + debtBuffer
        else:
            rate = 0 if rate - fCashHaircut < 0 else rate - fCashHaircut
        timeToMaturity = markets[marketIndex - 1][1] - blockTime

        # notional of each asset = PV * e ^ rt
        notional = math.trunc(
            pv * math.exp((rate / RATE_PRECISION) * (timeToMaturity / SECONDS_IN_YEAR))
        )
        portfolio.append(get_fcash_token(marketIndex, currencyId=currencyId, notional=notional))

    return portfolio

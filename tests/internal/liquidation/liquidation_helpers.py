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

    def __init__(self, account, MockContract):
        MockValuationLib.deploy({"from": account})
        c = account.deploy(MockContract)
        for i in range(1, 5):
            cToken = account.deploy(MockCToken, 8)
            cToken.setAnswer(self.cTokenRates[i])
            self.ethAggregators[i] = MockAggregator.deploy(18, {"from": account})
            self.cTokenAdapters[i] = cTokenAggregator.deploy(cToken.address, {"from": account})

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

    def calculate_to_eth(self, currency, underlying):
        multiple = (
            self.bufferHaircutDiscount[currency][1]
            if underlying > 0
            else self.bufferHaircutDiscount[currency][0]
        )
        return math.trunc(
            (underlying * self.ethRates[currency] * Wei(multiple)) / (Wei(1e18) * Wei(100))
        )

    def calculate_ntoken_to_asset(self, currency, nToken):
        return math.trunc(
            (nToken * self.nTokenCashBalance[currency] * self.nTokenParameters[currency][0])
            / (self.nTokenTotalSupply[currency] * 100)
        )


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

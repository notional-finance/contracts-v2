import math
import random

from brownie import MockAggregator, MockCToken, MockValuationLib, cTokenV2Aggregator
from brownie.convert.datatypes import HexString, Wei
from brownie.network.state import Chain
from tests.constants import (
    BASIS_POINT,
    RATE_PRECISION,
    REPO_INCENTIVE,
    SECONDS_IN_YEAR,
    SETTLEMENT_DATE,
    START_TIME,
)
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_eth_rate_mapping,
    get_fcash_token,
    get_liquidity_token,
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
            self.cTokenAdapters[i] = cTokenV2Aggregator.deploy(
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
                START_TIME,
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

    def calculate_ntoken_from_asset(self, currency, asset, valueType="haircut"):
        # asset = (nToken * cashBalance * param) / (totalSupply * 100)
        # nToken = (asset * totalSupply * 100) / (cashBalance * param)
        if valueType == "haircut":
            return math.trunc(
                (asset * self.nTokenTotalSupply[currency] * 100)
                / (self.nTokenCashBalance[currency] * self.nTokenParameters[currency][0])
            )
        elif valueType == "no-haircut":
            return math.trunc(
                (asset * self.nTokenTotalSupply[currency]) / self.nTokenCashBalance[currency]
            )
        elif valueType == "liquidator":
            return math.trunc(
                (asset * self.nTokenTotalSupply[currency] * 100)
                / (self.nTokenCashBalance[currency] * self.nTokenParameters[currency][1])
            )

    def get_adjusted_oracle_rate(self, oracleRate, currency, isPositive, valueType):
        if valueType == "haircut" and isPositive:
            adjustment = self.cashGroups[currency][5] * 5 * BASIS_POINT
            adjustedOracleRate = oracleRate + adjustment
        elif valueType == "haircut" and not isPositive:
            adjustment = self.cashGroups[currency][4] * 5 * BASIS_POINT
            adjustedOracleRate = max(oracleRate - adjustment, 0)
        elif valueType == "liquidator" and isPositive:
            adjustment = self.cashGroups[currency][7] * 5 * BASIS_POINT
            adjustedOracleRate = oracleRate + adjustment
        elif valueType == "liquidator" and not isPositive:
            adjustment = self.cashGroups[currency][8] * 5 * BASIS_POINT
            adjustedOracleRate = max(oracleRate - adjustment, 0)
        else:
            adjustedOracleRate = oracleRate

        return adjustedOracleRate

    def notional_from_pv(self, currency, pv, maturity, blockTime, valueType="haircut"):
        oracleRate = self.mock.calculateOracleRate(currency, maturity, blockTime)
        adjustedOracleRate = self.get_adjusted_oracle_rate(oracleRate, currency, pv > 0, valueType)
        expValue = math.trunc((adjustedOracleRate * (maturity - blockTime)) / SECONDS_IN_YEAR)
        return Wei(math.trunc(pv * math.exp(expValue / RATE_PRECISION)))

    def discount_to_pv(self, currency, fCash, maturity, blockTime, valueType="haircut"):
        oracleRate = self.mock.calculateOracleRate(currency, maturity, blockTime)
        adjustedOracleRate = self.get_adjusted_oracle_rate(
            oracleRate, currency, fCash > 0, valueType
        )
        return self.mock.getPresentfCashValue(fCash, maturity, blockTime, adjustedOracleRate)

    def get_fcash_portfolio(
        self, currency, presentValue, numAssets, blockTime, shares=None, maturities=None
    ):
        assets = []
        markets = self.mock.getActiveMarkets(currency)
        (maxBitNum, _) = self.mock.getBitNumFromMaturity(blockTime, markets[-1][1])

        if shares is None:
            # TODO: allow shares to be positive or negative to offset each other...
            shares = [random.randint(1, 100) for i in range(0, numAssets)]
            totalShares = sum(shares)
            shares = [s / totalShares for s in shares]

        if maturities is None:
            # Choose n random maturities
            bitNums = random.sample(range(1, maxBitNum + 1), numAssets)
            maturities = [self.mock.getMaturityFromBitNum(blockTime, b) for b in bitNums]

        for i in range(numAssets):
            pv = Wei(shares[i] * presentValue)
            fCash = self.notional_from_pv(
                currency, pv, maturities[i], blockTime, valueType="haircut"
            )
            assets.append(
                get_fcash_token(1, currencyId=currency, maturity=maturities[i], notional=fCash)
            )

        return assets

    def get_liquidity_tokens(
        self, currency, totalCashClaim, numTokens, blockTime, shares=None, matchfCash=None
    ):
        assets = []
        haircuts = self.mock.getLiquidityTokenHaircuts(currency)
        totalHaircutfCashResidual = 0
        totalfCashResidual = 0
        totalHaircutCashClaim = 0
        totalCashClaimCalculated = 0
        benefitsPerAsset = []

        if shares is None:
            shares = [random.randint(1, 100) for i in range(0, numTokens)]
            totalShares = sum(shares)
            shares = [s / totalShares for s in shares]
        if matchfCash is None:
            matchfCash = [True] * numTokens

        for i in range(numTokens):
            # cashClaim = totalCash * tokens / totalLiquidity
            # tokens = cashClaim * totalLiquidity / totalCash
            marketIndex = i + 1
            market = self.markets[currency][i]
            tokens = Wei((totalCashClaim * shares[i] * market[4]) / market[3])
            assets.append(get_liquidity_token(marketIndex, currencyId=currency, notional=tokens))

            fCash = 0
            if matchfCash[i]:
                # fCash = tokens * totalfCash / totalLiquidity
                fCash = -Wei(tokens * market[2] / market[4])
                assets.append(get_fcash_token(marketIndex, currencyId=currency, notional=fCash))

            cashClaim = Wei((tokens * market[3]) / market[4])
            haircutCashClaim = Wei(cashClaim * haircuts[i] / 100)
            totalCashClaimCalculated += cashClaim
            totalHaircutCashClaim += haircutCashClaim
            maxIncentive = Wei((cashClaim - haircutCashClaim) * REPO_INCENTIVE / 100)

            residualfCash = Wei((tokens * market[2]) / market[4]) + fCash
            haircutResidual = Wei((tokens * market[2] * haircuts[i]) / (market[4] * 100)) + fCash

            totalfCashResidual += self.calculate_from_underlying(
                currency,
                self.mock.getRiskAdjustedPresentfCashValue(
                    get_fcash_token(marketIndex, currencyId=currency, notional=residualfCash),
                    blockTime,
                ),
            )

            totalHaircutfCashResidual += self.calculate_from_underlying(
                currency,
                self.mock.getRiskAdjustedPresentfCashValue(
                    get_fcash_token(marketIndex, currencyId=currency, notional=haircutResidual),
                    blockTime,
                ),
            )

            # Calculate the max incentive per asset withdrawn
            benefitsPerAsset.append(
                {
                    "tokens": tokens,
                    "benefit": cashClaim - haircutCashClaim,
                    "maxIncentive": maxIncentive,
                    "fCashResidualPVAsset": totalfCashResidual - totalHaircutfCashResidual,
                    "totalCashClaim": cashClaim,
                    "haircutCashClaim": haircutCashClaim,
                }
            )

        return (
            assets,
            totalCashClaimCalculated,
            totalHaircutCashClaim,
            totalfCashResidual,
            totalHaircutfCashResidual,
            benefitsPerAsset,
        )

    def validate_market_changes(self, assetsBefore, assetsAfter, marketsBefore, marketsAfter):
        totalCashChange = 0
        tokensBefore = [a for a in assetsBefore if a[2] != 1]

        for t in tokensBefore:
            i = t[2] - 2
            marketTokenChange = marketsBefore[i][4] - marketsAfter[i][4]
            marketfCashChange = marketsBefore[i][2] - marketsAfter[i][2]
            totalCashChange += marketsBefore[i][3] - marketsAfter[i][3]

            # Validate token change is exact
            finalTokenAsset = list(filter(lambda x: x[0] == t[0] and x[2] == t[2], assetsAfter))
            if len(finalTokenAsset) > 0:
                assert marketTokenChange == t[3] - finalTokenAsset[0][3]
            else:
                assert marketTokenChange == t[3]

            # Validate fCash change is exact
            prefCashAsset = list(
                filter(lambda x: x[0] == t[0] and x[1] == t[1] and x[2] == 1, assetsBefore)
            )
            postfCashAsset = list(
                filter(lambda x: x[0] == t[0] and x[1] == t[1] and x[2] == 1, assetsAfter)
            )

            if len(prefCashAsset) == 0 and len(postfCashAsset) == 0:
                # This is not likely to happen, but will happen if totalfCash rounds down to zero
                # and there is no prefCashAsset
                assert marketfCashChange == 0
            elif len(prefCashAsset) == 1 and len(postfCashAsset) == 0:
                # Exact amount of fCash has been withdrawn to net off the prefCash asset
                assert marketfCashChange == -prefCashAsset[0][3]
            elif len(prefCashAsset) == 0 and len(postfCashAsset) == 1:
                # There was no pre fcash asset so the entire change goes into the fCash balance
                assert marketfCashChange == postfCashAsset[0][3]
            elif len(prefCashAsset) == 1 and len(postfCashAsset) == 1:
                # Difference is in the fCash withdrawn
                assert marketfCashChange == postfCashAsset[0][3] - prefCashAsset[0][3]

        return totalCashChange

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


# Returns initial factors to set fc to zero during collateral liquidation
def setup_collateral_liquidation(liquidation, local, localDebt):
    collateral = random.choice([c for c in range(1, 5) if c != local])
    collateralHaircut = liquidation.bufferHaircutDiscount[collateral][1]

    # This test needs to work off of changes to exchange rates, set up first such that
    # we have collateral and local in alignment at zero free collateral
    netETHRequired = liquidation.calculate_to_eth(local, localDebt)
    collateralUnderlying = Wei(
        liquidation.calculate_from_eth(collateral, -netETHRequired) * 100 / collateralHaircut
    )

    return (collateral, collateralUnderlying)


# Now we change the exchange rates to simulate undercollateralization, decreasing
# the exchange rate will also decrease the FC
def move_collateral_exchange_rate(liquidation, local, collateral, ratio):
    localBuffer = liquidation.bufferHaircutDiscount[local][0]
    collateralHaircut = liquidation.bufferHaircutDiscount[collateral][1]

    # Exchange Rates can move by by a maximum of (1 / buffer) * haircut, this is insolvency
    # If ratio > 100 then we are insolvent
    # If ratio == 0 then fc is 0
    maxPercentDecrease = (1 / localBuffer) * collateralHaircut
    exchangeRateDecrease = 100 - ((ratio * maxPercentDecrease) / 100)
    liquidationDiscount = liquidation.get_discount(local, collateral)

    if collateral != 1:
        newExchangeRate = liquidation.ethRates[collateral] * exchangeRateDecrease / 100
        liquidation.ethAggregators[collateral].setAnswer(newExchangeRate)
        discountedExchangeRate = (
            ((liquidation.ethRates[local] * 1e18) / newExchangeRate) * liquidationDiscount / 100
        )
    else:
        # The collateral currency is ETH so we have to change the local currency
        # exchange rate instead
        newExchangeRate = liquidation.ethRates[local] * 100 / exchangeRateDecrease
        liquidation.ethAggregators[local].setAnswer(newExchangeRate)
        discountedExchangeRate = (
            ((newExchangeRate * 1e18) / liquidation.ethRates[collateral])
            * liquidationDiscount
            / 100
        )

    return (newExchangeRate, discountedExchangeRate)


# Get the expected amount of collateral underlying required to complete the trade
def get_expected(
    liquidation,
    local,
    collateral,
    newExchangeRate,
    discountedExchangeRate,
    collateralUnderlying,
    fc,
):
    # Convert the free collateral amount back to the collateral currency at the
    # new exchange rate
    if collateral == 1:
        # In this case it is ETH
        collateralDenominatedFC = -fc
    else:
        collateralDenominatedFC = liquidation.calculate_from_eth(
            collateral, -fc, rate=newExchangeRate
        )

    # This is the original formula:
    # collateralDenominatedFC = localPurchased * localBuffer * exRateLocalToCollateral -
    #      collateralToSell * collateralHaircut
    # Solve for:
    # collateralToSell = collateralDenominatedFC / ((buffer / liquidationDiscount) - haircut)
    buffer = liquidation.bufferHaircutDiscount[local][0]
    haircut = liquidation.bufferHaircutDiscount[collateral][1]
    liquidationDiscount = liquidation.get_discount(local, collateral)
    denominator = math.trunc((buffer * 100 / liquidationDiscount) - haircut)
    collateralToSell = Wei((collateralDenominatedFC * 100) / denominator)

    # Apply the default liquidation buffer and cap at the total balance
    if collateralToSell < collateralUnderlying * 0.4:
        expectedCollateralTrade = collateralUnderlying * 0.4
    else:
        # Cannot go above the collateral available
        expectedCollateralTrade = min(collateralUnderlying, collateralToSell)

    expectedLocalCash = Wei(expectedCollateralTrade * 1e18 / discountedExchangeRate)

    # Apply haircuts and buffers
    if collateral == 1:
        # This is the reduction in the net ETH figure as a result of trading away this
        # amount of collateral
        collateralETHHaircutValue = liquidation.calculate_to_eth(
            collateral, expectedCollateralTrade
        )
        # This is the benefit to the haircut position
        debtETHBufferValue = liquidation.calculate_to_eth(
            local, -expectedLocalCash, rate=newExchangeRate
        )
    else:
        collateralETHHaircutValue = liquidation.calculate_to_eth(
            collateral, expectedCollateralTrade, rate=newExchangeRate
        )
        debtETHBufferValue = liquidation.calculate_to_eth(local, -expectedLocalCash)

    # expectedNetETHBenefit = -(collateralETHHaircutValue + debtETHBufferValue)

    return (
        expectedCollateralTrade,
        collateralETHHaircutValue,
        debtETHBufferValue,
        collateralToSell,
        collateralDenominatedFC,
    )


def calculate_local_debt_cash_balance(liquidation, local, ratio, benefitAsset, haircutAsset):
    # Choose a random currency for the debt to be in
    debtCurrency = random.choice([c for c in range(1, 5) if c != local])

    # Max benefit to the debt currency is going to be, we don't actually pay off any
    # debt in this liquidation type:
    # convertToETHWithHaircut(benefit) + convertToETHWithBuffer(debt)
    benefitInUnderlying = liquidation.calculate_to_underlying(
        local, Wei((benefitAsset * ratio * 1e8) / 1e10)
    )
    # Since this benefit is cross currency, apply the haircut here
    benefitInETH = liquidation.calculate_to_eth(local, benefitInUnderlying)

    # However, we need to also ensure that this account is undercollateralized, so the debt cash
    # balance needs to be lower than the value of the haircut value:
    # convertToETHWithHaircut(haircut) = convertToETHWithBuffer(debt)
    haircutInETH = liquidation.calculate_to_eth(
        local, liquidation.calculate_to_underlying(local, Wei(haircutAsset))
    )

    # This is the amount of debt post buffer we can offset with the benefit in ETH
    debtInUnderlyingBuffered = liquidation.calculate_from_eth(
        # NOTE: change here...
        debtCurrency,
        -(benefitInETH + haircutInETH),
    )
    # Undo the buffer when calculating the cash balance
    debtCashBalance = liquidation.calculate_from_underlying(
        debtCurrency,
        Wei((debtInUnderlyingBuffered * 100) / liquidation.bufferHaircutDiscount[debtCurrency][0]),
    )

    return (debtCurrency, debtCashBalance)

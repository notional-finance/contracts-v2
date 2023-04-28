import math
import random

from brownie import (
    MockAggregator,
    MockSettingsLib,
    accounts,
)
from brownie.convert.datatypes import HexString, Wei
from brownie.network.contract import Contract
from brownie.network.state import Chain
from tests.constants import (
    BASIS_POINT,
    RATE_PRECISION,
    REPO_INCENTIVE,
    SECONDS_IN_YEAR,
)
from tests.helpers import (
    get_fcash_token,
    get_liquidity_token,
    setup_internal_mock,
)

chain = Chain()


class ValuationMock:
    ethRates = {1: 1e18, 2: 0.01e18, 3: 0.011e18, 4: 10e18}
    underlyingDecimals = {1: 18, 2: 18, 3: 6, 4: 8}
    nTokenTotalSupply = {1: Wei(100_000e8), 2: Wei(100_000e8), 3: Wei(100_000e8), 4: Wei(100_000e8)}
    nTokenParameters = {1: (85, 90), 2: (86, 91), 3: (87, 92), 4: (88, 93)}

    markets = {}
    cashGroups = {}
    cTokenAdapters = {}
    ethAggregators = {}
    cTokens = {}

    def __init__(self, account, MockContract):
        settings = MockSettingsLib.deploy({"from": accounts[0]})
        mock = MockContract.deploy(settings, {"from": accounts[0]})
        mock = Contract.from_abi(
            "mock", mock.address, MockSettingsLib.abi + mock.abi, owner=accounts[0]
        )

        setup_internal_mock(mock)

        self.mock = mock

    def enableBitmapForAccount(self, account, currency, nextSettleTime):
        self.mock.setAccountContext(
            account, (nextSettleTime, "0x00", 0, currency, HexString(0, "bytes18"), False)
        )

    def calculate_to_underlying(self, currency, balance, time=chain.time() + 1):
        try:
            (pr, factors) = self.mock.buildPrimeRateView(currency, time)
        except Exception:
            (pr, factors) = self.mock.buildPrimeRateView(currency, chain.time() + 1)

        return self.mock.convertToUnderlying(pr, balance)

    def calculate_from_underlying(self, currency, balance, time=chain.time() + 1):
        (pr, _) = self.mock.buildPrimeRateView(currency, time)
        return self.mock.convertFromUnderlying(pr, balance)

    def calculate_exchange_rate(self, base, quote):
        return math.trunc(Wei(self.ethRates[base] * 1e18) / self.ethRates[quote])

    def get_discount(self, local, collateral):
        localDiscount = self.mock.getETHRate(local)["liquidationDiscount"]
        collateralDiscount = self.mock.getETHRate(collateral)["liquidationDiscount"]
        return max(localDiscount, collateralDiscount)

    def calculate_from_eth(self, currency, underlying, rate=None):
        ethRate = self.mock.getETHRate(currency)
        aggregator = Contract.from_abi("agg", ethRate[0], MockAggregator.abi, owner=accounts[0])

        if rate:
            return math.trunc((underlying * Wei(1e18)) / rate)
        else:
            return math.trunc((underlying * Wei(1e18)) / aggregator.latestAnswer())

    def calculate_to_eth(self, currency, underlying, valueType="haircut", rate=None):
        ethRate = self.mock.getETHRate(currency)
        aggregator = Contract.from_abi("agg", ethRate[0], MockAggregator.abi, owner=accounts[0])

        if valueType == "haircut":
            multiple = ethRate["haircut"] if underlying > 0 else ethRate["buffer"]
        elif valueType == "no-haircut":
            multiple = 100

        if rate:
            return math.trunc((underlying * rate * Wei(multiple)) / (Wei(1e18) * Wei(100)))
        else:
            return math.trunc(
                (underlying * aggregator.latestAnswer() * Wei(multiple)) / (Wei(1e18) * Wei(100))
            )

    def calculate_ntoken_to_asset(self, currency, nToken, time, valueType="haircut"):
        nTokenPV = self.mock.getNTokenPV(currency, time)
        if valueType == "haircut":
            return math.trunc(
                (nToken * nTokenPV * self.nTokenParameters[currency][0])
                / (self.nTokenTotalSupply[currency] * 100)
            )
        elif valueType == "no-haircut":
            return math.trunc((nToken * nTokenPV) / self.nTokenTotalSupply[currency])
        elif valueType == "liquidator":
            return math.trunc(
                (nToken * nTokenPV * self.nTokenParameters[currency][1])
                / (self.nTokenTotalSupply[currency] * 100)
            )

    def calculate_ntoken_from_asset(self, currency, asset, time, valueType="haircut"):
        nTokenPV = self.mock.getNTokenPV(currency, time)
        # asset = (nToken * cashBalance * param) / (totalSupply * 100)
        # nToken = (asset * totalSupply * 100) / (cashBalance * param)
        if valueType == "haircut":
            return math.trunc(
                (asset * self.nTokenTotalSupply[currency] * 100)
                / (nTokenPV * self.nTokenParameters[currency][0])
            )
        elif valueType == "no-haircut":
            return math.trunc((asset * self.nTokenTotalSupply[currency]) / nTokenPV)
        elif valueType == "liquidator":
            return math.trunc(
                (asset * self.nTokenTotalSupply[currency] * 100)
                / (nTokenPV * self.nTokenParameters[currency][1])
            )

    def get_adjusted_oracle_rate(self, oracleRate, currency, isPositive, valueType):
        cashGroup = self.mock.getCashGroup(currency)
        if valueType == "haircut" and isPositive:
            adjustment = cashGroup[5] * 25 * BASIS_POINT
            adjustedOracleRate = max(oracleRate + adjustment, cashGroup["minOracleRate25BPS"] * 25 * BASIS_POINT)
        elif valueType == "haircut" and not isPositive:
            adjustment = cashGroup[4] * 25 * BASIS_POINT
            adjustedOracleRate = min(max(oracleRate - adjustment, 0), cashGroup["maxOracleRate25BPS"] * 25 * BASIS_POINT)
        elif valueType == "liquidator" and isPositive:
            adjustment = cashGroup[7] * 25 * BASIS_POINT
            adjustedOracleRate = oracleRate + adjustment
        elif valueType == "liquidator" and not isPositive:
            adjustment = cashGroup[8] * 25 * BASIS_POINT
            adjustedOracleRate = max(oracleRate - adjustment, 0)
        else:
            adjustedOracleRate = oracleRate

        return adjustedOracleRate

    def notional_from_pv(self, currency, pv, maturity, blockTime, valueType="haircut"):
        oracleRate = self.mock.calculateOracleRate(currency, maturity, blockTime)
        adjustedOracleRate = self.get_adjusted_oracle_rate(oracleRate, currency, pv > 0, valueType)
        expValue = math.trunc((adjustedOracleRate * (maturity - blockTime)) / SECONDS_IN_YEAR)

        fvFactor = math.floor(math.exp(expValue / RATE_PRECISION) * RATE_PRECISION)
        cashGroup = self.mock.getCashGroup(currency)
        maxDiscountFactor = RATE_PRECISION - cashGroup["maxDiscountFactor5BPS"] * 5 * BASIS_POINT
        minFVFactor = math.floor((RATE_PRECISION * RATE_PRECISION) / maxDiscountFactor)
        fvFactor = max(fvFactor, minFVFactor)

        return Wei(math.trunc((pv * fvFactor) / RATE_PRECISION))

    def discount_to_pv(self, currency, fCash, maturity, blockTime, valueType="haircut"):
        if valueType == "haircut":
            # This is a more accurate version that includes max discount factor
            return self.mock.getRiskAdjustedPresentfCashValue((currency, maturity, 1, fCash, 0, 0), blockTime)

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

    # def get_liquidation_factors(self, local, collateral, **kwargs):
    #     account = 0 if "account" not in kwargs else kwargs["account"].address
    #     netETHValue = 0 if "netETHValue" not in kwargs else kwargs["netETHValue"]
    #     localAssetAvailable = (
    #         0 if "localAssetAvailable" not in kwargs else kwargs["localAssetAvailable"]
    #     )
    #     collateralAssetAvailable = (
    #         0 if "collateralAssetAvailable" not in kwargs else kwargs["collateralAssetAvailable"]
    #     )
    #     nTokenHaircutAssetValue = (
    #         0 if "nTokenHaircutAssetValue" not in kwargs else kwargs["nTokenHaircutAssetValue"]
    #     )
    #     if collateral == 0:
    #         nTokenParameters = "0x{}0000{}00".format(
    #             hex(self.nTokenParameters[local][1])[2:], hex(self.nTokenParameters[local][0])[2:]
    #         )
    #     else:
    #         nTokenParameters = "0x{}0000{}00".format(
    #             hex(self.nTokenParameters[collateral][1])[2:],
    #             hex(self.nTokenParameters[collateral][0])[2:],
    #         )

    #     localETHRate = [1e18, self.ethRates[local]] + self.bufferHaircutDiscount[local]
    #     collateralETHRate = [1e18, self.ethRates[collateral]] + self.bufferHaircutDiscount[
    #         collateral
    #     ]
    #     localAssetRate = [
    #         self.cTokenAdapters[local].address,
    #         self.cTokenRates[local],
    #         10 ** self.underlyingDecimals[local],
    #     ]
    #     collateralCashGroup = [
    #         local if collateral == 0 else collateral,
    #         3,
    #         localAssetRate
    #         if collateral == 0
    #         else [
    #             self.cTokenAdapters[collateral].address,
    #             self.cTokenRates[collateral],
    #             10 ** self.underlyingDecimals[collateral],
    #         ],
    #         0,  # TODO: need to fill this in for fCash
    #     ]
    #     isCalculation = False if "isCalculation" not in kwargs else kwargs["isCalculation"]

    #     return [
    #         account,
    #         netETHValue,
    #         localAssetAvailable,
    #         collateralAssetAvailable,
    #         nTokenHaircutAssetValue,
    #         nTokenParameters,
    #         localETHRate,
    #         collateralETHRate,
    #         localAssetRate,
    #         collateralCashGroup,
    #         isCalculation,
    #     ]


# Returns initial factors to set fc to zero during collateral liquidation
def setup_collateral_liquidation(liquidation, local, localDebt):
    collateral = random.choice([c for c in range(1, 5) if c != local])
    collateralEthRate = liquidation.mock.getETHRate(collateral)
    collateralHaircut = collateralEthRate["haircut"]

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
    localEthRate = liquidation.mock.getETHRate(local)
    collateralEthRate = liquidation.mock.getETHRate(collateral)

    localBuffer = localEthRate["buffer"]
    collateralHaircut = collateralEthRate["haircut"]

    # Exchange Rates can move by by a maximum of (1 / buffer) * haircut, this is insolvency
    # If ratio > 100 then we are insolvent
    # If ratio == 0 then fc is 0
    maxPercentDecrease = (1 / localBuffer) * collateralHaircut
    exchangeRateDecrease = 100 - ((ratio * maxPercentDecrease) / 100)
    liquidationDiscount = max(
        localEthRate["liquidationDiscount"], collateralEthRate["liquidationDiscount"]
    )

    if collateral != 1:
        aggregator = Contract.from_abi(
            "agg", collateralEthRate[0], MockAggregator.abi, owner=accounts[0]
        )
        newExchangeRate = aggregator.latestAnswer() * exchangeRateDecrease / 100
        aggregator.setAnswer(newExchangeRate)
        discountedExchangeRate = (
            ((liquidation.ethRates[local] * 1e18) / newExchangeRate) * liquidationDiscount / 100
        )
    else:
        # The collateral currency is ETH so we have to change the local currency
        # exchange rate instead
        aggregator = Contract.from_abi(
            "agg", liquidation.mock.getETHRate(local)[0], MockAggregator.abi, owner=accounts[0]
        )
        newExchangeRate = aggregator.latestAnswer() * 100 / exchangeRateDecrease
        aggregator.setAnswer(newExchangeRate)
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
    localETHRate = liquidation.mock.getETHRate(local)
    collateralETHRate = liquidation.mock.getETHRate(collateral)
    buffer = localETHRate["buffer"]
    haircut = collateralETHRate["haircut"]
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


def calculate_local_debt_cash_balance(
    liquidation, local, ratio, benefitAsset, haircutAsset, blockTime
):
    # Choose a random currency for the debt to be in
    debtCurrency = random.choice([c for c in range(1, 5) if c != local])

    # Max benefit to the debt currency is going to be, we don't actually pay off any
    # debt in this liquidation type:
    # convertToETHWithHaircut(benefit) + convertToETHWithBuffer(debt)
    benefitInUnderlying = liquidation.calculate_to_underlying(
        local, Wei((benefitAsset * ratio * 1e8) / 1e10), blockTime
    )
    # Since this benefit is cross currency, apply the haircut here
    benefitInETH = liquidation.calculate_to_eth(local, benefitInUnderlying)

    # However, we need to also ensure that this account is undercollateralized, so the debt cash
    # balance needs to be lower than the value of the haircut value:
    # convertToETHWithHaircut(haircut) = convertToETHWithBuffer(debt)
    haircutInETH = liquidation.calculate_to_eth(
        local, liquidation.calculate_to_underlying(local, Wei(haircutAsset), blockTime)
    )

    # This is the amount of debt post buffer we can offset with the benefit in ETH
    debtInUnderlyingBuffered = liquidation.calculate_from_eth(
        # NOTE: change here...
        debtCurrency,
        -(benefitInETH + haircutInETH),
    )
    # Undo the buffer when calculating the cash balance
    debtBuffer = liquidation.mock.getETHRate(debtCurrency)["buffer"]
    debtCashBalance = liquidation.calculate_from_underlying(
        debtCurrency, Wei((debtInUnderlyingBuffered * 100) / debtBuffer), blockTime
    )

    return (debtCurrency, debtCashBalance)

import itertools
import random

from brownie.convert.datatypes import Wei
from brownie.test import strategy
from tests.constants import (
    CASH_GROUP_PARAMETERS,
    CURVE_SHAPES,
    MARKETS,
    RATE_PRECISION,
    SECONDS_IN_DAY,
    START_TIME,
)

timeToMaturityStrategy = strategy("uint", min_value=90, max_value=7200)
impliedRateStrategy = strategy(
    "uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION
)


def get_eth_rate_mapping(rateOracle, decimalPlaces=18, buffer=140, haircut=100, discount=105):
    return (rateOracle.address, decimalPlaces, False, buffer, haircut, discount)


def get_cash_group_with_max_markets(maxMarketIndex):
    cg = list(CASH_GROUP_PARAMETERS)
    cg[0] = maxMarketIndex
    cg[7] = cg[7][0:maxMarketIndex]
    cg[8] = cg[8][0:maxMarketIndex]

    return cg


def get_market_curve(maxMarketIndex, curveShape):
    markets = []

    if type(curveShape) == str and curveShape in CURVE_SHAPES.keys():
        curveShape = CURVE_SHAPES[curveShape]

    for i in range(0, maxMarketIndex):
        markets.append(
            get_market_state(
                MARKETS[i],
                proportion=curveShape["proportion"],
                lastImpliedRate=curveShape["rates"][i],
                oracleRate=curveShape["rates"][i],
                previousTradeTime=START_TIME,
            )
        )

    return markets


def get_tref(blockTime):
    return blockTime - blockTime % (90 * SECONDS_IN_DAY)


def get_market_state(maturity, **kwargs):
    totalLiquidity = 1e18 if "totalLiquidity" not in kwargs else kwargs["totalLiquidity"]
    if "proportion" in kwargs:
        proportion = kwargs["proportion"]
        totalfCash = totalLiquidity * (1 - proportion)
        totalCurrentCash = totalLiquidity * proportion
    else:
        totalfCash = 1e18 if "totalfCash" not in kwargs else kwargs["totalfCash"]
        totalCurrentCash = 1e18 if "totalCurrentCash" not in kwargs else kwargs["totalCurrentCash"]

    lastImpliedRate = 0.1e9 if "lastImpliedRate" not in kwargs else kwargs["lastImpliedRate"]
    oracleRate = 0.1e9 if "oracleRate" not in kwargs else kwargs["oracleRate"]
    previousTradeTime = 0 if "previousTradeTime" not in kwargs else kwargs["previousTradeTime"]
    storageSlot = "0x0" if "storageSlot" not in kwargs else kwargs["storageSlot"]
    storageState = "0x00"

    return (
        storageSlot,
        maturity,
        Wei(totalfCash),
        Wei(totalCurrentCash),
        Wei(totalLiquidity),
        lastImpliedRate,
        oracleRate,
        previousTradeTime,
        storageState,
    )


def get_liquidity_token(marketIndex, **kwargs):
    currencyId = 1 if "currencyId" not in kwargs else kwargs["currencyId"]
    maturity = MARKETS[marketIndex - 1] if "maturity" not in kwargs else kwargs["maturity"]
    assetType = marketIndex + 1
    notional = 1e18 if "notional" not in kwargs else kwargs["notional"]
    storageState = 0 if "storageState" not in kwargs else kwargs["storageState"]

    return (currencyId, maturity, assetType, Wei(notional), storageState)


def get_fcash_token(marketIndex, **kwargs):
    currencyId = 1 if "currencyId" not in kwargs else kwargs["currencyId"]
    maturity = MARKETS[marketIndex - 1] if "maturity" not in kwargs else kwargs["maturity"]
    assetType = 1
    notional = 1e18 if "notional" not in kwargs else kwargs["notional"]
    storageState = 0 if "storageState" not in kwargs else kwargs["storageState"]

    return (currencyId, maturity, assetType, Wei(notional), storageState)


def get_portfolio_array(length, cashGroups, **kwargs):
    portfolio = []
    while len(portfolio) < length:
        isLiquidity = random.randint(0, 1)
        cashGroup = random.choice(cashGroups)
        marketIndex = random.randint(1, cashGroup[1])

        if any(
            a[0] == cashGroup[0] and a[1] == MARKETS[marketIndex - 1] and a[2] == marketIndex + 1
            if isLiquidity
            else 1
            for a in portfolio
        ):
            # No duplciate assets
            continue

        if isLiquidity:
            lt = get_liquidity_token(marketIndex, currencyId=cashGroup[0])
            portfolio.append(lt)
            if random.random() > 0.75:
                portfolio.append(
                    get_fcash_token(marketIndex, currencyId=cashGroup[0], notional=-lt[3])
                )
        else:
            asset = get_fcash_token(marketIndex, currencyId=cashGroup[0])
            portfolio.append(asset)

    if "sorted" in kwargs and kwargs["sorted"]:
        return sorted(portfolio, key=lambda x: (x[0], x[1], x[2]))

    return portfolio


def generate_asset_array(numAssets, numCurrencies):
    assets = []
    nextMaturingAsset = 2 ** 40
    assetsChoice = random.sample(
        list(itertools.product(range(1, numCurrencies), MARKETS)), numAssets
    )

    for a in assetsChoice:
        notional = random.randint(-1e18, 1e18)
        # isfCash = random.randint(0, 1)
        isfCash = 0
        if isfCash:
            assets.append((a[0], a[1], 1, notional))
        else:
            index = MARKETS.index(a[1])
            assets.append((a[0], a[1], index + 2, abs(notional)))
            # Offsetting fCash asset
            assets.append((a[0], a[1], 1, -abs(notional)))

        nextMaturingAsset = min(a[1], nextMaturingAsset)

    random.shuffle(assets)
    return (assets, nextMaturingAsset)


def get_bitstring_from_bitmap(bitmap):
    if bitmap.hex() == "":
        return []

    num_bits = str(len(bitmap) * 8)
    bitstring = ("{:0>" + num_bits + "b}").format(int(bitmap.hex(), 16))

    return bitstring


def random_asset_bitmap(numAssets, maxBit=254):
    # Choose K bits to set
    bitmapList = ["0"] * 256
    setBits = random.choices(range(0, maxBit), k=numAssets)
    for b in setBits:
        bitmapList[b] = "1"
    bitmap = "0x{:0{}x}".format(int("".join(bitmapList), 2), 64)

    return (bitmap, bitmapList)

import random

from brownie.convert import to_bytes, to_uint
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import strategy
from eth_abi.packed import encode_abi_packed
from scripts.config import CurrencyDefaults, nTokenDefaults
from scripts.deployment import TestEnvironment
from tests.constants import (
    BALANCE_FLAG_INT,
    CASH_GROUP_PARAMETERS,
    CURVE_SHAPES,
    DEPOSIT_ACTION_TYPE,
    MARKET_LENGTH,
    MARKETS,
    PORTFOLIO_FLAG_INT,
    RATE_PRECISION,
    SECONDS_IN_DAY,
    SECONDS_IN_QUARTER,
    START_TIME,
    TRADE_ACTION_TYPE,
)

chain = Chain()
timeToMaturityStrategy = strategy("uint", min_value=90, max_value=7200)
impliedRateStrategy = strategy(
    "uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION
)


def get_balance_state(currencyId, **kwargs):
    storedCashBalance = 0 if "storedCashBalance" not in kwargs else kwargs["storedCashBalance"]
    netCashChange = 0 if "netCashChange" not in kwargs else kwargs["netCashChange"]
    storedNTokenBalance = (
        0 if "storedNTokenBalance" not in kwargs else kwargs["storedNTokenBalance"]
    )
    netAssetTransferInternalPrecision = (
        0
        if "netAssetTransferInternalPrecision" not in kwargs
        else kwargs["netAssetTransferInternalPrecision"]
    )
    netNTokenTransfer = 0 if "netNTokenTransfer" not in kwargs else kwargs["netNTokenTransfer"]
    netNTokenSupplyChange = (
        0 if "netNTokenSupplyChange" not in kwargs else kwargs["netNTokenSupplyChange"]
    )
    lastClaimTime = 0 if "lastClaimTime" not in kwargs else kwargs["lastClaimTime"]
    lastClaimSupply = 0 if "lastClaimSupply" not in kwargs else kwargs["lastClaimSupply"]

    return (
        currencyId,
        storedCashBalance,
        storedNTokenBalance,
        netCashChange,
        netAssetTransferInternalPrecision,
        netNTokenTransfer,
        netNTokenSupplyChange,
        lastClaimTime,
        lastClaimSupply,
    )


def get_eth_rate_mapping(rateOracle, decimalPlaces=18, buffer=140, haircut=100, discount=105):
    return (rateOracle.address, decimalPlaces, False, buffer, haircut, discount)


def get_cash_group_with_max_markets(maxMarketIndex):
    cg = list(CASH_GROUP_PARAMETERS)
    cg[0] = maxMarketIndex
    cg[9] = cg[9][0:maxMarketIndex]
    cg[10] = cg[10][0:maxMarketIndex]

    return cg


def get_market_curve(maxMarketIndex, curveShape, previousTradeTime=START_TIME, assetRate=1):
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
                previousTradeTime=previousTradeTime,
                assetRate=assetRate,
            )
        )

    return markets


def get_tref(blockTime):
    return blockTime - blockTime % (90 * SECONDS_IN_DAY)


def get_market_state(maturity, **kwargs):
    totalLiquidity = 1e18 if "totalLiquidity" not in kwargs else kwargs["totalLiquidity"]
    if "proportion" in kwargs:
        assetRate = 1 if "assetRate" not in kwargs else kwargs["assetRate"]
        # proportion = totalfCash / (totalfCash + totalAssetCash)
        # totalfCash * p + totalAssetCash * p = totalfCash
        # totalfCash * (1 - p) / p = totalAssetCash
        totalfCash = 1e18
        totalAssetCash = (
            Wei(totalfCash * (1 - kwargs["proportion"]) / kwargs["proportion"]) * assetRate
        )
    else:
        totalfCash = 1e18 if "totalfCash" not in kwargs else kwargs["totalfCash"]
        totalAssetCash = 1e18 if "totalAssetCash" not in kwargs else kwargs["totalAssetCash"]

    lastImpliedRate = 0.1e9 if "lastImpliedRate" not in kwargs else kwargs["lastImpliedRate"]
    oracleRate = 0.1e9 if "oracleRate" not in kwargs else kwargs["oracleRate"]
    previousTradeTime = 0 if "previousTradeTime" not in kwargs else kwargs["previousTradeTime"]
    storageSlot = "0x0" if "storageSlot" not in kwargs else kwargs["storageSlot"]

    return (
        storageSlot,
        maturity,
        Wei(totalfCash),
        Wei(totalAssetCash),
        Wei(totalLiquidity),
        lastImpliedRate,
        oracleRate,
        previousTradeTime,
    )


def get_liquidity_token(marketIndex, **kwargs):
    currencyId = 1 if "currencyId" not in kwargs else kwargs["currencyId"]
    maturity = MARKETS[marketIndex - 1] if "maturity" not in kwargs else kwargs["maturity"]
    assetType = marketIndex + 1
    notional = 1e18 if "notional" not in kwargs else kwargs["notional"]
    storageSlot = 0 if "storageSlot" not in kwargs else kwargs["storageSlot"]
    storageState = 0 if "storageState" not in kwargs else kwargs["storageState"]

    return (currencyId, maturity, assetType, Wei(notional), storageSlot, storageState)


def get_fcash_token(marketIndex, **kwargs):
    currencyId = 1 if "currencyId" not in kwargs else kwargs["currencyId"]
    maturity = MARKETS[marketIndex - 1] if "maturity" not in kwargs else kwargs["maturity"]
    assetType = 1
    notional = 1e18 if "notional" not in kwargs else kwargs["notional"]
    storageSlot = 0 if "storageSlot" not in kwargs else kwargs["storageSlot"]
    storageState = 0 if "storageState" not in kwargs else kwargs["storageState"]

    return (currencyId, maturity, assetType, Wei(notional), storageSlot, storageState)


def get_settlement_date(asset, blockTime):
    if asset[2] == 1:
        return asset[1]
    else:
        return asset[1] - MARKET_LENGTH[asset[2] - 2] + 90 * SECONDS_IN_DAY


def get_portfolio_array(length, cashGroups, **kwargs):
    portfolio = []
    attempts = 0
    while len(portfolio) < length and attempts < 50:
        attempts += 1
        isLiquidity = random.randint(0, 1)
        cashGroup = random.choice(cashGroups)
        marketIndex = random.randint(1, cashGroup[0])

        duplicate = False
        assetType = marketIndex + 1 if isLiquidity else 1
        for a in portfolio:
            if a[0] == cashGroup[0] and a[1] == MARKETS[marketIndex - 1] and a[2] == assetType:
                duplicate = True

        if duplicate:
            # No duplicate assets
            continue
        elif isLiquidity:
            lt = get_liquidity_token(marketIndex, currencyId=cashGroup[0])
            portfolio.append(lt)
            if len(portfolio) < length and random.random() > 0.75:
                portfolio.append(
                    get_fcash_token(marketIndex, currencyId=cashGroup[0], notional=-lt[3])
                )
        else:
            asset = get_fcash_token(marketIndex, currencyId=cashGroup[0])
            portfolio.append(asset)

    if "sorted" in kwargs and kwargs["sorted"]:
        return sorted(portfolio, key=lambda x: (x[0], x[1], x[2]))

    return portfolio


def get_bitstring_from_bitmap(bitmap):
    if bitmap.hex() == "":
        return []

    num_bits = str(len(bitmap) * 8)
    bitstring = ("{:0>" + num_bits + "b}").format(int(bitmap.hex(), 16))

    return bitstring


def get_bitmap_from_bitlist(bitmapList):
    return "0x{:0{}x}".format(int("".join(bitmapList), 2), 64)


def random_asset_bitmap(numAssets, maxBit=254):
    # Choose K bits to set
    bitmapList = ["0"] * 256
    setBits = random.choices(range(0, maxBit), k=numAssets)
    for b in setBits:
        bitmapList[b] = "1"
    bitmap = get_bitmap_from_bitlist(bitmapList)

    return (bitmap, bitmapList)


def currencies_list_to_active_currency_bytes(currenciesList):
    if len(currenciesList) == 0:
        return to_bytes(0, "bytes18")

    if len(currenciesList) > 9:
        raise Exception("Currency list too long")

    result = bytearray()
    for (cid, portfolioActive, balanceActive) in currenciesList:
        if cid < 0 or cid > 2 ** 14:
            raise Exception("Invalid currency id")

        if portfolioActive:
            cid = cid | PORTFOLIO_FLAG_INT

        if balanceActive:
            cid = cid | BALANCE_FLAG_INT

        result.extend(to_bytes(cid, "bytes2"))

    if len(result) < 18:
        # Pad this out to 18 bytes
        result.extend(to_bytes(0, "bytes1") * (18 - len(result)))

    return bytes(result)


def active_currencies_to_list(activeCurrencies):
    ba = bytearray(activeCurrencies)

    currencies_list = []
    byteLen = len(activeCurrencies)
    for i in range(0, byteLen, 2):
        cid = to_uint(bytes(ba[i : i + 2]), "uint16")
        if cid == b"\x00\x00":
            break

        currencyId = cid
        if currencyId > PORTFOLIO_FLAG_INT:
            currencyId = currencyId - PORTFOLIO_FLAG_INT
        if currencyId > BALANCE_FLAG_INT:
            currencyId = currencyId - BALANCE_FLAG_INT

        currencies_list.append(
            (
                currencyId,
                cid & (1 << 15) != 0,  # portfolio active
                cid & (1 << 14) != 0,  # currency active
            )
        )

    return currencies_list


def get_balance_action(currencyId, depositActionType, **kwargs):
    depositActionAmount = (
        0 if "depositActionAmount" not in kwargs else kwargs["depositActionAmount"]
    )
    withdrawAmountInternalPrecision = (
        0
        if "withdrawAmountInternalPrecision" not in kwargs
        else kwargs["withdrawAmountInternalPrecision"]
    )
    withdrawEntireCashBalance = (
        False if "withdrawEntireCashBalance" not in kwargs else kwargs["withdrawEntireCashBalance"]
    )
    redeemToUnderlying = (
        False if "redeemToUnderlying" not in kwargs else kwargs["redeemToUnderlying"]
    )

    return (
        DEPOSIT_ACTION_TYPE[depositActionType],
        currencyId,
        int(depositActionAmount),
        int(withdrawAmountInternalPrecision),
        withdrawEntireCashBalance,
        redeemToUnderlying,
    )


def get_balance_trade_action(currencyId, depositActionType, tradeActionData, **kwargs):
    tradeActions = [get_trade_action(**t) for t in tradeActionData]
    balanceAction = list(get_balance_action(currencyId, depositActionType, **kwargs))
    balanceAction.append(tradeActions)

    return tuple(balanceAction)


def get_lend_action(currencyId, tradeActionData, depositUnderlying):
    tradeActions = [get_trade_action(**t) for t in tradeActionData]
    return (currencyId, depositUnderlying, tradeActions)


def get_trade_action(**kwargs):
    tradeActionType = kwargs["tradeActionType"]

    if tradeActionType == "Lend":
        return encode_abi_packed(
            ["uint8", "uint8", "uint88", "uint32", "uint120"],
            [
                TRADE_ACTION_TYPE[tradeActionType],
                kwargs["marketIndex"],
                int(kwargs["notional"]),
                int(kwargs["minSlippage"]),
                0,
            ],
        )
    elif tradeActionType == "Borrow":
        return encode_abi_packed(
            ["uint8", "uint8", "uint88", "uint32", "uint120"],
            [
                TRADE_ACTION_TYPE[tradeActionType],
                kwargs["marketIndex"],
                int(kwargs["notional"]),
                int(kwargs["maxSlippage"]),
                0,
            ],
        )
    elif tradeActionType == "AddLiquidity":
        return encode_abi_packed(
            ["uint8", "uint8", "uint88", "uint32", "uint32", "uint88"],
            [
                TRADE_ACTION_TYPE[tradeActionType],
                kwargs["marketIndex"],
                int(kwargs["notional"]),
                int(kwargs["minSlippage"]),
                int(kwargs["maxSlippage"]),
                0,
            ],
        )
    elif tradeActionType == "RemoveLiquidity":
        return encode_abi_packed(
            ["uint8", "uint8", "uint88", "uint32", "uint32", "uint88"],
            [
                TRADE_ACTION_TYPE[tradeActionType],
                kwargs["marketIndex"],
                int(kwargs["notional"]),
                int(kwargs["minSlippage"]),
                int(kwargs["maxSlippage"]),
                0,
            ],
        )
    elif tradeActionType == "PurchaseNTokenResidual":
        return encode_abi_packed(
            ["uint8", "uint32", "int88", "uint128"],
            [
                TRADE_ACTION_TYPE[tradeActionType],
                kwargs["maturity"],
                int(kwargs["fCashAmountToPurchase"]),
                0,
            ],
        )
    elif tradeActionType == "SettleCashDebt":
        return encode_abi_packed(
            ["uint8", "address", "uint88"],
            [
                TRADE_ACTION_TYPE[tradeActionType],
                kwargs["counterparty"],
                int(kwargs["amountToSettle"]),
            ],
        )


def _enable_cash_group(currencyId, env, accounts, initialCash=50000000e8):
    env.notional.updateDepositParameters(currencyId, *(nTokenDefaults["Deposit"]))
    env.notional.updateInitializationParameters(currencyId, *(nTokenDefaults["Initialization"]))
    env.notional.updateTokenCollateralParameters(currencyId, *(nTokenDefaults["Collateral"]))
    env.notional.updateIncentiveEmissionRate(currencyId, CurrencyDefaults["incentiveEmissionRate"])

    env.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId, "DepositAssetAndMintNToken", depositActionAmount=initialCash
            )
        ],
        {"from": accounts[0]},
    )
    env.notional.initializeMarkets(currencyId, True)


def initialize_environment(accounts):
    chain = Chain()
    env = TestEnvironment(accounts[0])
    env.enableCurrency("DAI", CurrencyDefaults)
    env.enableCurrency("USDC", CurrencyDefaults)
    env.enableCurrency("WBTC", CurrencyDefaults)

    cToken = env.cToken["ETH"]
    cToken.mint({"from": accounts[0], "value": 10000e18})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    cToken = env.cToken["DAI"]
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["DAI"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(100000000e18, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    env.token["DAI"].transfer(accounts[1], 100000e18, {"from": accounts[0]})
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    cToken.transfer(accounts[1], 500000e8, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})

    cToken = env.cToken["USDC"]
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["USDC"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(100000000e6, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    env.token["USDC"].transfer(accounts[1], 100000e6, {"from": accounts[0]})
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    cToken.transfer(accounts[1], 500000e8, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})

    # Set the blocktime to the beginning of the next tRef otherwise the rates will blow up
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    _enable_cash_group(1, env, accounts, initialCash=40000e8)
    _enable_cash_group(2, env, accounts)
    _enable_cash_group(3, env, accounts)

    return env


# Sets up a residual environment given the parameters:
# - residualType: 0 = no residuals, 1 = positive, or 2=negative ifCash residuals
# - marketResiduals: true if there are residuals in the fCash markets
# - canSellResiduals: true if the residuals can be sold
def setup_residual_environment(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the one year market
    cashGroup[0] = 3
    cashGroup[9] = CurrencyDefaults["tokenHaircut"][0:3]
    cashGroup[10] = CurrencyDefaults["rateScalar"][0:3]
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInitializationParameters(
        currencyId, [0.01e9, 0.021e9, 0.07e9], [0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    if residualType == 0:
        # No Residuals
        pass
    elif residualType == 1:
        # Do some trading to leave some ntoken residual, this will be a negative residual
        action = get_balance_trade_action(
            2,
            "DepositUnderlying",
            [{"tradeActionType": "Lend", "marketIndex": 3, "notional": 100e8, "minSlippage": 0}],
            depositActionAmount=100e18,
            withdrawEntireCashBalance=True,
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )
    elif residualType == 2:
        # Do some trading to leave some ntoken residual, this will be a positive residual
        action = get_balance_trade_action(
            2,
            "DepositUnderlying",
            [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
            depositActionAmount=200e18,
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    # Now settle the markets, should be some residual
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    # Creates fCash residuals that require selling fCash
    if marketResiduals:
        action = get_balance_trade_action(
            2,
            "DepositUnderlying",
            [
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 1,
                    "notional": 10_000e8,
                    "minSlippage": 0,
                },
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 2,
                    "notional": 10_000e8,
                    "minSlippage": 0,
                },
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 3,
                    "notional": 10_000e8,
                    "minSlippage": 0,
                },
            ],
            depositActionAmount=50_000e18,
            withdrawEntireCashBalance=True,
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    if not canSellResiduals:
        # Redeem the vast majority of the nTokens
        environment.notional.nTokenRedeem(
            accounts[0].address, currencyId, 44_100_000e8, True, False, {"from": accounts[0]}
        )

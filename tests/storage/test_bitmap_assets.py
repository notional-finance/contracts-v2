import random

import brownie
import pytest
from brownie.test import given, strategy
from tests.constants import MARKETS, RATE_PRECISION, START_TIME, START_TIME_TREF
from tests.helpers import (
    get_bitstring_from_bitmap,
    get_cash_group_with_max_markets,
    get_market_state,
    random_asset_bitmap,
)


@pytest.fixture(scope="module", autouse=True)
def bitmapAssets(MockBitmapAssetsHandler, accounts):
    handler = MockBitmapAssetsHandler.deploy({"from": accounts[0]})
    return handler


@pytest.fixture(scope="module", autouse=True)
def mockAssetRate(MockCToken, cTokenAggregator, accounts):
    # Deploy 8 different aggregators for each currency
    mockToken = MockCToken.deploy(8, {"from": accounts[0]})
    mockAggregator = cTokenAggregator.deploy(mockToken.address, {"from": accounts[0]})
    # Set the settlement rate to be set
    mockToken.setSupplyRate(0.01e18)
    mockToken.setAnswer(0.01e18)

    return mockAggregator


@given(bitmap=strategy("bytes32"), currencyId=strategy("uint8"))
def test_get_and_set_bitmap(bitmapAssets, bitmap, currencyId, accounts):
    bitmapAssets.setAssetsBitmap(accounts[0], currencyId, bitmap)
    storedValue = bitmapAssets.getAssetsBitmap(accounts[0], currencyId)
    bmHex = brownie.convert.datatypes.HexString(bitmap.hex().ljust(64, "0"), "bytes32")

    assert bmHex == storedValue


@given(bitmap=strategy("bytes32"), bitNum=strategy("uint", min_value=1, max_value=256))
def test_set_ifcash_asset(bitmapAssets, bitmap, bitNum, accounts):
    maturity = bitmapAssets.getMaturityFromBitNum(START_TIME, bitNum)
    notional = random.randint(-1e18, 1e18)

    txn = bitmapAssets.setifCashAsset(accounts[0], 1, maturity, START_TIME, notional, bitmap)
    newBitmap = txn.return_value

    setValue = bitmapAssets.getifCashAsset(accounts[0], 1, maturity)
    newBitlist = list(get_bitstring_from_bitmap(newBitmap))

    assert setValue == notional
    assert newBitlist[bitNum - 1] == "1"

    # This should net off the value
    txn = bitmapAssets.setifCashAsset(accounts[0], 1, maturity, START_TIME, -notional, newBitmap)
    newBitmap = txn.return_value

    setValue = bitmapAssets.getifCashAsset(accounts[0], 1, maturity)
    newBitlist = list(get_bitstring_from_bitmap(newBitmap))

    assert setValue == 0
    assert newBitlist[bitNum - 1] == "0"


def test_get_ifcash_array(bitmapAssets, accounts):
    currencyId = 1
    (bitmap, bitmapList) = random_asset_bitmap(10)

    bitIndexes = list(filter(lambda x: x[1] == "1", enumerate(bitmapList)))
    maturities = []
    for (bitNum, _) in bitIndexes:
        maturity = bitmapAssets.getMaturityFromBitNum(START_TIME, bitNum + 1)
        maturities.append(maturity)
        notional = 1e8
        bitmapAssets.setifCashAsset(accounts[0], currencyId, maturity, START_TIME, notional, "")

    bitmapAssets.setAssetsBitmap(accounts[0], currencyId, bitmap)
    portfolio = bitmapAssets.getifCashArray(accounts[0], currencyId, START_TIME)

    assert len(portfolio) == len(bitIndexes)
    for (i, asset) in enumerate(portfolio):
        assert asset[0] == 1
        assert asset[1] == maturities[i]
        assert asset[2] == 1
        assert asset[3] == 1e8


def test_ifcash_npv(bitmapAssets, mockAssetRate, accounts):
    cg = get_cash_group_with_max_markets(9)
    bitmapAssets.setAssetRateMapping(1, (mockAssetRate.address, 18))
    bitmapAssets.setCashGroup(1, cg)

    (cashGroup, _) = bitmapAssets.buildCashGroupView(1)

    markets = [
        get_market_state(MARKETS[0], oracleRate=0.01 * RATE_PRECISION, storageSlot="0x01"),
        get_market_state(MARKETS[1], oracleRate=0.02 * RATE_PRECISION, storageSlot="0x01"),
        get_market_state(MARKETS[2], oracleRate=0.03 * RATE_PRECISION, storageSlot="0x01"),
        get_market_state(MARKETS[3], oracleRate=0.04 * RATE_PRECISION, storageSlot="0x01"),
        get_market_state(MARKETS[4], oracleRate=0.05 * RATE_PRECISION, storageSlot="0x01"),
        get_market_state(MARKETS[5], oracleRate=0.06 * RATE_PRECISION, storageSlot="0x01"),
        get_market_state(MARKETS[6], oracleRate=0.07 * RATE_PRECISION, storageSlot="0x01"),
        get_market_state(MARKETS[7], oracleRate=0.08 * RATE_PRECISION, storageSlot="0x01"),
        get_market_state(MARKETS[8], oracleRate=0.09 * RATE_PRECISION, storageSlot="0x01"),
    ]

    # TODO: test a random negative offset to next maturing asset to simulate an unsettled
    # perpetual token
    nextSettleTime = START_TIME_TREF
    # Get the max bit given the time offset
    (maxBit, isExact) = bitmapAssets.getBitNumFromMaturity(nextSettleTime, markets[-1][1])
    (assetsBitmap, assetsBitmapList) = random_asset_bitmap(10, maxBit)
    computedPV = 0
    computedRiskPV = 0

    # Set each ifCash slot
    for i, b in enumerate(assetsBitmapList):
        if b == "1":
            notional = random.randint(-1e12, 1e12)
            maturity = bitmapAssets.getMaturityFromBitNum(nextSettleTime, i + 1)

            bitmapAssets.setifCashAsset(
                accounts[0],
                1,
                maturity,
                nextSettleTime,
                notional,
                "0x00",  # bitmap doesnt matter here
            )

            if maturity <= START_TIME:
                computedPV += notional
                computedRiskPV += notional
            else:
                pv = bitmapAssets.getPresentValue(
                    cashGroup, markets, notional, maturity, START_TIME
                )
                riskPv = bitmapAssets.getRiskAdjustedPresentValue(
                    cashGroup, markets, notional, maturity, START_TIME
                )
                computedPV += pv
                computedRiskPV += riskPv

    pv = bitmapAssets.getifCashNetPresentValue(
        accounts[0],
        1,
        nextSettleTime,
        START_TIME,
        assetsBitmap,
        cashGroup,
        markets,
        False,  # non risk adjusted
    )

    riskPv = bitmapAssets.getifCashNetPresentValue(
        accounts[0],
        1,
        nextSettleTime,
        START_TIME,
        assetsBitmap,
        cashGroup,
        markets,
        True,  # risk adjusted
    )

    assert computedPV == pv
    assert riskPv == computedRiskPV

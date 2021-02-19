import random

import brownie
import pytest
from brownie.test import given, strategy
from tests.common.params import (
    BASE_CASH_GROUP,
    MARKETS,
    RATE_PRECISION,
    START_TIME,
    START_TIME_TREF,
    get_bitstring_from_bitmap,
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


@given(bitmap=strategy("bytes", min_size=0, max_size=32), currencyId=strategy("uint8"))
def test_get_and_set_bitmap(bitmapAssets, bitmap, currencyId, accounts):
    bitmapAssets.setAssetsBitmap(accounts[0], currencyId, bitmap)
    storedValue = bitmapAssets.getAssetsBitmap(accounts[0], currencyId)
    bmHex = brownie.convert.datatypes.HexString(bitmap.hex().ljust(64, "0"), "bytes32")

    assert bmHex == storedValue


@given(
    bitmap=strategy("bytes", min_size=0, max_size=32),
    bitNum=strategy("uint", min_value=1, max_value=256),
)
def test_set_ifcash_asset(bitmapAssets, bitmap, bitNum, accounts):
    maturity = bitmapAssets.getMaturityFromBitNum(START_TIME, bitNum)
    notional = random.randint(-1e18, 1e18)

    txn = bitmapAssets.setifCashAsset(accounts[0], 1, maturity, START_TIME, notional, bitmap)
    newBitmap = txn.return_value

    setValue = bitmapAssets.ifCashMapping(accounts[0], 1, maturity)
    newBitlist = list(get_bitstring_from_bitmap(newBitmap))

    assert setValue == notional
    assert newBitlist[bitNum - 1] == "1"

    # This should net off the value
    txn = bitmapAssets.setifCashAsset(accounts[0], 1, maturity, START_TIME, -notional, newBitmap)
    newBitmap = txn.return_value

    setValue = bitmapAssets.ifCashMapping(accounts[0], 1, maturity)
    newBitlist = list(get_bitstring_from_bitmap(newBitmap))

    assert setValue == 0
    assert newBitlist[bitNum - 1] == "0"


def test_ifcash_npv(bitmapAssets, mockAssetRate, accounts):
    cg = BASE_CASH_GROUP
    # TODO: need to set supply rate
    cg[2] = (mockAssetRate.address, 0.01e18, 18)
    bitmapAssets.setAssetRateMapping(1, (mockAssetRate.address, 18))

    markets = [
        (1, MARKETS[0], 0, 0, 0, 0, 0.01 * RATE_PRECISION, 0, False),
        (1, MARKETS[1], 0, 0, 0, 0, 0.02 * RATE_PRECISION, 0, False),
        (1, MARKETS[2], 0, 0, 0, 0, 0.03 * RATE_PRECISION, 0, False),
        (1, MARKETS[3], 0, 0, 0, 0, 0.04 * RATE_PRECISION, 0, False),
        (1, MARKETS[4], 0, 0, 0, 0, 0.05 * RATE_PRECISION, 0, False),
        (1, MARKETS[5], 0, 0, 0, 0, 0.06 * RATE_PRECISION, 0, False),
        (1, MARKETS[6], 0, 0, 0, 0, 0.07 * RATE_PRECISION, 0, False),
        (1, MARKETS[7], 0, 0, 0, 0, 0.08 * RATE_PRECISION, 0, False),
        (1, MARKETS[8], 0, 0, 0, 0, 0.09 * RATE_PRECISION, 0, False),
    ]

    # TODO: test a random negative offset to next maturing asset to simulate an unsettled
    # perpetual token
    nextMaturingAsset = START_TIME_TREF
    # Get the max bit given the time offset
    (maxBit, isExact) = bitmapAssets.getBitNumFromMaturity(nextMaturingAsset, markets[-1][1])
    (assetsBitmap, assetsBitmapList) = random_asset_bitmap(10, maxBit)
    computedPV = 0
    computedRiskPV = 0

    # Set each ifCash slot
    for i, b in enumerate(assetsBitmapList):
        if b == "1":
            notional = random.randint(-1e12, 1e12)
            maturity = bitmapAssets.getMaturityFromBitNum(nextMaturingAsset, i + 1)

            bitmapAssets.setifCashAsset(
                accounts[0],
                1,
                maturity,
                nextMaturingAsset,
                notional,
                "0x00",  # bitmap doesnt matter here
            )

            if maturity <= START_TIME:
                computedPV += notional
                computedRiskPV += notional
            else:
                pv = bitmapAssets.getPresentValue(cg, markets, notional, maturity, START_TIME)
                riskPv = bitmapAssets.getRiskAdjustedPresentValue(
                    cg, markets, notional, maturity, START_TIME
                )
                computedPV += pv
                computedRiskPV += riskPv

    pv = bitmapAssets.getifCashNetPresentValue(
        accounts[0],
        1,
        nextMaturingAsset,
        START_TIME,
        assetsBitmap,
        cg,
        markets,
        False,  # non risk adjusted
    )

    riskPv = bitmapAssets.getifCashNetPresentValue(
        accounts[0],
        1,
        nextMaturingAsset,
        START_TIME,
        assetsBitmap,
        cg,
        markets,
        True,  # risk adjusted
    )

    assert computedPV == pv
    assert riskPv == computedRiskPV

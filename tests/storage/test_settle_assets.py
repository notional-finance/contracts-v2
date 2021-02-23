import itertools
import random

import pytest
from brownie.test import given, strategy
from hypothesis import settings
from tests.common.params import (
    MARKETS,
    SECONDS_IN_DAY,
    SECONDS_IN_YEAR,
    SETTLEMENT_DATE,
    START_TIME,
)

NUM_CURRENCIES = 8
SETTLEMENT_RATE = [
    (18, MARKETS[0], 0.01e18),
    (18, MARKETS[1], 0.02e18),
    (18, MARKETS[2], 0.03e18),
    (18, MARKETS[3], 0.04e18),
    (18, MARKETS[4], 0.05e18),
    (18, MARKETS[5], 0.06e18),
    (18, MARKETS[6], 0.07e18),
    (18, MARKETS[7], 0.08e18),
    (18, MARKETS[8], 0.09e18),
]

SETTLED_RATE = 0.01e18


@pytest.fixture(scope="module", autouse=True)
def mockAggregators(MockCToken, cTokenAggregator, accounts):
    # Deploy 8 different aggregators for each currency
    aggregators = []
    for i in range(0, NUM_CURRENCIES):
        mockToken = MockCToken.deploy(8, {"from": accounts[0]})
        mock = cTokenAggregator.deploy(mockToken.address, {"from": accounts[0]})
        # Set the settlement rate to be set
        mockToken.setAnswer(0.01e18 * (i + 1))
        aggregators.append(mock)

    return aggregators


@pytest.fixture(scope="module", autouse=True)
def mockSettleAssets(MockSettleAssets, mockAggregators, accounts):
    contract = MockSettleAssets.deploy({"from": accounts[0]})

    # Set the mock aggregators
    contract.setMaxCurrencyId(NUM_CURRENCIES)
    for i, a in enumerate(mockAggregators):
        contract.setAssetRateMapping(i + 1, (a.address, 18))

        # Set market state
        for m in MARKETS:
            contract.setMarketState((i + 1, m, 1e18, 1e18, 1e18, 0, 0, 0, True), SETTLEMENT_DATE)

            # Set settlement rates for markets 0, 1
            if m == MARKETS[0]:
                contract.setSettlementRate(i + 1, m, SETTLEMENT_RATE[0])
            elif m == MARKETS[1]:
                contract.setSettlementRate(i + 1, m, SETTLEMENT_RATE[1])

    return contract


def generate_asset_array(numAssets):
    assets = []
    nextMaturingAsset = 2 ** 40 - 1
    assetsChoice = random.sample(
        list(itertools.product(range(1, NUM_CURRENCIES), MARKETS)), numAssets
    )

    for a in assetsChoice:
        notional = random.randint(-1e18, 1e18)
        isfCash = random.randint(0, 1)
        if isfCash:
            assets.append((a[0], a[1], 1, notional))
        else:
            index = MARKETS.index(a[1])
            assets.append((a[0], a[1], index + 2, abs(notional)))
            # Offsetting fCash asset
            assets.append((a[0], a[1], 1, -abs(notional)))

        nextMaturingAsset = min(get_settle_date(assets[-1]), nextMaturingAsset)

    random.shuffle(assets)
    return (assets, nextMaturingAsset)


def assert_rates_settled(mockSettleAssets, assetArray, blockTime):
    for a in assetArray:
        if a[1] < blockTime and a[1] not in (MARKETS[0], MARKETS[1]):
            value = mockSettleAssets.assetToUnderlyingSettlementRateMapping(a[0], a[1])
            assert value == (18, blockTime, SETTLED_RATE * a[0])


def assert_markets_updated(mockSettleAssets, assetArray):
    for a in assetArray:
        # is liquidity token
        if a[2] > 1:
            maturity = MARKETS[a[2] - 2]
            value = mockSettleAssets.getSettlementMarket(a[0], maturity, SETTLEMENT_DATE)
            assert value[0:3] == (int(1e18) - a[3], int(1e18) - a[3], int(1e18) - a[3])


def get_settle_date(asset):
    if asset[2] <= 3:
        return asset[1]

    marketLength = MARKETS[asset[2] - 2] - START_TIME
    return asset[1] - marketLength + SECONDS_IN_DAY * 90


def get_settle_rate(currencyId, maturity):
    if maturity == MARKETS[0]:
        rate = SETTLEMENT_RATE[0][2]
    elif maturity == MARKETS[1]:
        rate = SETTLEMENT_RATE[1][2]
    else:
        rate = SETTLED_RATE * currencyId
    return rate


def settled_balance_context(assetArray, blockTime):
    assetsSorted = sorted(assetArray)
    settledBalances = []
    for a in assetsSorted:
        # fcash asset type
        if a[2] == 1 and a[1] < blockTime:
            rate = get_settle_rate(a[0], a[1])
            cashClaim = a[3] * 1e18 / rate
            settledBalances.append((a[0], cashClaim))
        elif get_settle_date(a) < blockTime:
            # Cash claims do not need to get converted
            cashClaim = a[3]
            settledBalances.append((a[0], cashClaim))

            if a[1] < blockTime:
                rate = get_settle_rate(a[0], a[1])
                fCashClaim = a[3] * 1e18 / rate
                settledBalances.append((a[0], fCashClaim))

    # Group by currency id and sum settled values
    return [
        (key, sum(int(num) for _, num in value))
        for key, value in itertools.groupby(settledBalances, lambda x: x[0])
    ]


def remaining_assets(assetArray, blockTime):
    assetsSorted = sorted(assetArray)
    remaining = []
    for a in assetsSorted:
        if a[1] < blockTime:
            continue

        if a[2] > 1 and get_settle_date(a) < blockTime:
            # Switch asset to fcash
            remaining.append((a[0], a[1], 1, a[3]))
        else:
            remaining.append(a)

    return remaining


@given(numAssets=strategy("uint", min_value=0, max_value=10))
def test_settle_assets(mockSettleAssets, mockAggregators, accounts, numAssets):
    # SETUP TEST
    blockTime = random.choice(MARKETS[2:]) + random.randint(0, 6000)
    (assetArray, nextMaturingAsset) = generate_asset_array(numAssets)
    accountContext = (nextMaturingAsset, 0, False, False, False, "0x88")

    # Set state
    mockSettleAssets.setAssetArray(accounts[1], assetArray)
    mockSettleAssets.setAccountContext(accounts[1], accountContext)

    # Run this beforehand, debug trace crashes if trying to get return values via stateful call
    (bs, _) = mockSettleAssets._getSettleAssetContextView(accounts[1], blockTime)

    # Assert that net balance change are equal
    computedBs = settled_balance_context(assetArray, blockTime)
    assert len(bs) == len(computedBs)
    for i, b in enumerate(bs):
        assert b[0] == computedBs[i][0]
        assert pytest.approx(b[3], rel=1e-12) == computedBs[i][1]

    # This will assert the values from the view match the values from the stateful method
    mockSettleAssets.testSettleAssetArray(accounts[1], blockTime)

    # Assert that the rate is set after
    assert_rates_settled(mockSettleAssets, assetArray, blockTime)

    # Assert that markets have been updated
    assert_markets_updated(mockSettleAssets, assetArray)

    # Assert that remaining assets are ok
    assets = mockSettleAssets.getAssetArray(accounts[1])
    assert sorted(assets) == remaining_assets(assetArray, blockTime)


@given(
    nextMaturingAsset=strategy(
        "uint", min_value=START_TIME, max_value=START_TIME + (40 * SECONDS_IN_YEAR)
    )
)
@settings(max_examples=5)
def test_settle_ifcash_bitmap(mockSettleAssets, accounts, nextMaturingAsset):
    # Simulate that block time can be arbitrarily far into the future
    currencyId = 1
    blockTime = nextMaturingAsset + random.randint(0, SECONDS_IN_YEAR)
    # Make sure that this references UTC0 of the first bit
    nextMaturingAsset = nextMaturingAsset - nextMaturingAsset % SECONDS_IN_DAY
    # Choose K bits to set
    bitmapList = ["0"] * 256
    setBits = random.choices(range(0, 255), k=10)
    for b in setBits:
        bitmapList[b] = "1"
    bitmap = "0x{:0{}x}".format(int("".join(bitmapList), 2), 64)

    activeMaturities = []
    computedTotalAssetCash = 0

    for i, b in enumerate(bitmapList):
        if b == "1":
            notional = random.randint(-1e18, 1e18)
            maturity = mockSettleAssets.getMaturityFromBitNum(nextMaturingAsset, i + 1)
            (bitNum, isValid) = mockSettleAssets.getBitNumFromMaturity(nextMaturingAsset, maturity)
            assert isValid
            assert (i + 1) == bitNum

            activeMaturities.append((maturity, bitNum))
            mockSettleAssets.setifCash(accounts[0], currencyId, maturity, notional)

            if maturity < blockTime:
                computedTotalAssetCash += int(
                    notional * 1e18 / get_settle_rate(currencyId, maturity)
                )

    # Compute the new bitmap
    blockTimeUTC0 = blockTime - blockTime % SECONDS_IN_DAY
    (lastSettleBit, _) = mockSettleAssets.getBitNumFromMaturity(nextMaturingAsset, blockTimeUTC0)
    computedNewBitmap = ["0"] * 256
    for a in activeMaturities:
        if a[0] > blockTimeUTC0:
            (newBit, _) = mockSettleAssets.getBitNumFromMaturity(blockTimeUTC0, a[0])
            computedNewBitmap[newBit - 1] = "1"

    joinedNewBitmap = "0x{:0{}x}".format(int("".join(computedNewBitmap), 2), 64)

    mockSettleAssets._settleBitmappedCashGroup(
        accounts[0], currencyId, bitmap, nextMaturingAsset, blockTime
    )

    newBitmap = mockSettleAssets.newBitmapStorage()
    totalAssetCash = mockSettleAssets.totalAssetCash()
    assert pytest.approx(computedTotalAssetCash, rel=1e-12) == totalAssetCash
    newBitmapList = list("{:0256b}".format(int(newBitmap.hex(), 16)))
    # For testing:
    # inputOnes = list(filter(lambda x: x[1] == "1", enumerate(bitmapList)))
    # ones = list(filter(lambda x: x[1] == "1", enumerate(newBitmapList)))
    # computedOnes = list(filter(lambda x: x[1] == "1", enumerate(computedNewBitmap)))
    assert newBitmap == joinedNewBitmap

    # Ensure that the bitmap covers every location where there is ifCash
    for i, b in enumerate(newBitmapList):
        maturity = mockSettleAssets.getMaturityFromBitNum(blockTimeUTC0, i + 1)
        ifCash = mockSettleAssets.getifCashAsset(accounts[0], currencyId, maturity)

        if b == "1":
            assert ifCash != 0
        else:
            assert ifCash == 0

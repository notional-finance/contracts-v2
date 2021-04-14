import itertools
import random

import pytest
from brownie.test import given, strategy
from hypothesis import settings
from tests.constants import MARKETS, SECONDS_IN_DAY, SECONDS_IN_YEAR, SETTLEMENT_DATE, START_TIME
from tests.helpers import get_market_state, get_portfolio_array

NUM_CURRENCIES = 3
SETTLEMENT_RATE = [
    (18, MARKETS[0], 0.01e18),
    (18, MARKETS[1], 0.02e18),
    (18, MARKETS[2], 0.03e18),
    (18, MARKETS[3], 0.04e18),
    (18, MARKETS[4], 0.05e18),
    (18, MARKETS[5], 0.06e18),
    (18, MARKETS[6], 0.07e18),
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
        currencyId = i + 1
        contract.setAssetRateMapping(currencyId, (a.address, 8))

        # Set market state
        for m in MARKETS:
            marketState = get_market_state(m)
            contract.setMarketState(currencyId, SETTLEMENT_DATE, m, marketState)

            # Set settlement rates for markets 0, 1
            if m == MARKETS[0]:
                contract.setSettlementRate(i + 1, m, SETTLEMENT_RATE[0][2], 8)
            elif m == MARKETS[1]:
                contract.setSettlementRate(i + 1, m, SETTLEMENT_RATE[1][2], 8)

    return contract


def generate_asset_array(numAssets):
    cashGroups = [(i, 7) for i in range(1, NUM_CURRENCIES)]
    assets = get_portfolio_array(numAssets, cashGroups)
    if len(assets) == 0:
        return (assets, 0)

    nextSettleTime = min([a[1] for a in assets])

    random.shuffle(assets)
    return (assets, nextSettleTime)


def assert_rates_settled(mockSettleAssets, assetArray, blockTime):
    for a in assetArray:
        if a[1] < blockTime and a[1] not in (MARKETS[0], MARKETS[1]):
            (_, rate, _) = mockSettleAssets.getSettlementRate(a[0], a[1])
            assert rate == (SETTLED_RATE * a[0])


def assert_markets_updated(mockSettleAssets, assetArray):
    for a in assetArray:
        # is liquidity token
        if a[2] > 1:
            maturity = MARKETS[a[2] - 2]
            value = mockSettleAssets.getSettlementMarket(a[0], maturity, SETTLEMENT_DATE)
            assert value[1:4] == (int(1e18) - a[3], int(1e18) - a[3], int(1e18) - a[3])


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
    remainingAssets = []

    for a in assetsSorted:
        # fcash asset type
        if a[2] == 1 and a[1] < blockTime:
            rate = get_settle_rate(a[0], a[1])
            cashClaim = a[3] * 1e18 / rate
            settledBalances.append((a[0], cashClaim))
        elif a[2] > 1 and a[1] < blockTime:
            # Settle both cash and fCash claims
            cashClaim = a[3]
            settledBalances.append((a[0], cashClaim))

            rate = get_settle_rate(a[0], a[1])
            fCashClaim = a[3] * 1e18 / rate
            settledBalances.append((a[0], fCashClaim))
        elif a[2] > 1 and SETTLEMENT_DATE < blockTime:
            # Settle cash claim, leave behind fCash
            cashClaim = a[3]
            settledBalances.append((a[0], cashClaim))

            fCashClaim = a[3]
            remainingAssets.append((a[0], a[1], 1, fCashClaim))
        else:
            remainingAssets.append(a)

    # Group by currency id and sum settled values
    return (
        [
            (key, sum(int(num) for _, num in value))
            for key, value in itertools.groupby(settledBalances, lambda x: x[0])
        ],
        list(
            filter(
                lambda x: x[3] != 0,
                [
                    (key[0], key[1], key[2], sum(int(a[3]) for a in value))
                    for key, value in itertools.groupby(
                        remainingAssets, lambda x: (x[0], x[1], x[2])
                    )
                ],
            )
        ),
    )


@given(numAssets=strategy("uint", min_value=0, max_value=4))
def test_settle_assets(mockSettleAssets, mockAggregators, accounts, numAssets):
    # SETUP TEST
    blockTime = random.choice(MARKETS[0:3]) + random.randint(0, 6000)
    (assetArray, nextSettleTime) = generate_asset_array(numAssets)

    # Set state
    mockSettleAssets.setAssetArray(accounts[1], assetArray)

    # This will assert the values from the view match the values from the stateful method
    settleAmounts = mockSettleAssets.settlePortfolio(accounts[1], blockTime).return_value
    assets = mockSettleAssets.getAssetArray(accounts[1])

    # Assert that net balance change are equal
    (computedSettleAmounts, remainingAssets) = settled_balance_context(assetArray, blockTime)
    assert len(settleAmounts) == len(computedSettleAmounts)
    for i, sa in enumerate(settleAmounts):
        assert sa[0] == computedSettleAmounts[i][0]
        assert pytest.approx(sa[1], rel=1e-12) == computedSettleAmounts[i][1]

    # Assert that the rate is set after
    assert_rates_settled(mockSettleAssets, assetArray, blockTime)

    # Assert that markets have been updated
    assert_markets_updated(mockSettleAssets, assetArray)

    # Assert that remaining assets are ok
    assets = [(a[0], a[1], a[2], a[3]) for a in assets]
    assert sorted(assets) == sorted(remainingAssets)


@given(
    nextSettleTime=strategy(
        "uint", min_value=START_TIME, max_value=START_TIME + (40 * SECONDS_IN_YEAR)
    )
)
@settings(max_examples=5)
def test_settle_ifcash_bitmap(mockSettleAssets, accounts, nextSettleTime):
    # Simulate that block time can be arbitrarily far into the future
    currencyId = 1
    blockTime = nextSettleTime + random.randint(0, SECONDS_IN_YEAR)
    # Make sure that this references UTC0 of the first bit
    nextSettleTime = nextSettleTime - nextSettleTime % SECONDS_IN_DAY
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
            maturity = mockSettleAssets.getMaturityFromBitNum(nextSettleTime, i + 1)
            (bitNum, isValid) = mockSettleAssets.getBitNumFromMaturity(nextSettleTime, maturity)
            assert isValid
            assert (i + 1) == bitNum

            activeMaturities.append((maturity, bitNum))
            mockSettleAssets.setifCash(accounts[0], currencyId, maturity, notional, nextSettleTime)

            if maturity < blockTime:
                computedTotalAssetCash += int(
                    notional * 1e18 / get_settle_rate(currencyId, maturity)
                )

    # Compute the new bitmap
    blockTimeUTC0 = blockTime - blockTime % SECONDS_IN_DAY
    (lastSettleBit, _) = mockSettleAssets.getBitNumFromMaturity(nextSettleTime, blockTimeUTC0)
    computedNewBitmap = ["0"] * 256
    for a in activeMaturities:
        if a[0] > blockTimeUTC0:
            (newBit, _) = mockSettleAssets.getBitNumFromMaturity(blockTimeUTC0, a[0])
            computedNewBitmap[newBit - 1] = "1"

    joinedNewBitmap = "0x{:0{}x}".format(int("".join(computedNewBitmap), 2), 64)

    mockSettleAssets._settleBitmappedCashGroup(
        accounts[0], currencyId, bitmap, nextSettleTime, blockTime
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

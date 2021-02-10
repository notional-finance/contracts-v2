import itertools
import random

import pytest
# import math
# import secrets
# import brownie
# from brownie.test import given, strategy
from tests.common.params import MARKETS, SECONDS_IN_DAY, START_TIME

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
        contract.setAssetRateMapping(i + 1, (a.address, 18, False, 0, 0, 8, 8))

        # Set market state
        for m in MARKETS:
            contract.setMarketState(i + 1, m, (1e18, 1e18, 0, 0, 0), 1e18)

            # Set settlement rates for markets 0, 1
            if m == MARKETS[0]:
                contract.setSettlementRate(i + 1, m, SETTLEMENT_RATE[0])
            elif m == MARKETS[1]:
                contract.setSettlementRate(i + 1, m, SETTLEMENT_RATE[1])

    return contract


def generate_asset_array(numAssets):
    assets = []
    nextMaturingAsset = 2 ** 40
    assetsChoice = random.sample(
        list(itertools.product(range(1, NUM_CURRENCIES), MARKETS)), numAssets
    )

    for a in assetsChoice:
        notional = random.randint(-1e18, 1e18)
        assets.append((a[0], a[1], 1, notional))

        nextMaturingAsset = min(a[1], nextMaturingAsset)

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
            maturity = MARKETS[a[2] - 1]
            value = mockSettleAssets.marketStateMapping(a[0], maturity)
            assert value == (1e18 - a[3], 1e18 - a[3], 0, 0, 0)
            liquidity = mockSettleAssets.marketTotalLiquidityMapping(a[0], maturity)
            assert liquidity == 1e18 - a[3]


def get_settle_date(asset):
    if asset[2] <= 2:
        return asset[1]

    marketLength = MARKETS[asset[2] - 1] - START_TIME
    return asset[1] - marketLength + SECONDS_IN_DAY * 90


def settled_balance_context(assetArray, blockTime):
    assetsSorted = sorted(assetArray)
    settledBalances = []
    for a in assetsSorted:
        rate = 0
        if a[1] == MARKETS[0]:
            rate = SETTLEMENT_RATE[0][2]
        elif a[1] == MARKETS[1]:
            rate = SETTLEMENT_RATE[1][2]
        else:
            rate = SETTLED_RATE * a[0]

        # fcash asset type
        if a[2] == 1 and a[1] < blockTime:
            cashClaim = a[3] * 1e18 / rate
            settledBalances.append((a[0], cashClaim))
        elif get_settle_date(a) < blockTime:
            cashClaim = a[3] * 1e18 / rate
            settledBalances.append((a[0], cashClaim))

            if a[1] < blockTime:
                fCashClaim = a[3] * 1e18 / rate
                settledBalances.append((a[0], fCashClaim))

    # Group by currency id and sum settled values
    return [
        (key, sum(num for _, num in value))
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


def test_settle_assets(mockSettleAssets, mockAggregators, accounts):
    # SETUP TEST
    blockTime = random.choice(MARKETS[2:]) + random.randint(0, 6000)
    (assetArray, nextMaturingAsset) = generate_asset_array(5)
    accountContext = (nextMaturingAsset, False, False, "0x88")

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
        assert pytest.approx(b[3], rel=1e-16) == computedBs[i][1]

    # This will assert the values from the view match the values from the stateful method
    mockSettleAssets.testSettleAssetArray(accounts[1], blockTime)

    # Assert that the rate is set after
    assert_rates_settled(mockSettleAssets, assetArray, blockTime)

    # Assert that markets have been updated
    assert_markets_updated(mockSettleAssets, assetArray)

    # Assert that remaining assets are ok
    assets = mockSettleAssets.getAssetArray(accounts[1])
    assert sorted(assets) == remaining_assets(assetArray, blockTime)

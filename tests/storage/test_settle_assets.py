import pytest

# import math
# import secrets
# import brownie
# from brownie.test import given, strategy
# from tests.common.params import *

BLOCK_TIME = 7000
MARKETS = [1000, 2000, 5000, 10000]
NUM_CURRENCIES = 8


@pytest.fixture(scope="module", autouse=True)
def mockAggregators(MockAggregator, accounts):
    # Deploy 8 different aggregators
    aggregators = [
        MockAggregator.deploy(18, {"from": accounts[0]}) for i in range(0, NUM_CURRENCIES)
    ]
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

            # Set settlement rates
            if m == MARKETS[0]:
                contract.setSettlementRate(i + 1, m, (18, m, 0.01e18))
            elif m == MARKETS[1]:
                contract.setSettlementRate(i + 1, m, (18, m, 0.02e18))

    return contract


def test_settle_assets(mockSettleAssets, mockAggregators, accounts):
    accountContext = (1000, False, False, "0x88")
    mockAggregators[1].setAnswer(0.05e18)

    assetArray = [
        (1, 1000, 2, 0.2e18),
        (1, 2000, 1, 1e18),
        (2, 2000, 1, 1e18),
        (2, 5000, 1, 1e18),  # This settlement rate is unset
        (5, 2000, 1, 1e18),
        (10, 10000, 1, 1e18),  # This will remain unsettled
    ]

    mockSettleAssets.setAssetArray(accounts[1], assetArray)
    mockSettleAssets.setAccountContext(accounts[1], accountContext)

    # unset settlement rate before
    value = mockSettleAssets.assetToUnderlyingSettlementRateMapping(2, 5000)
    assert value == (0, 0, 0)

    # Run this beforehand, debug trace crashes if trying to get return values via stateful call
    (bc, account) = mockSettleAssets._getSettleAssetContextView(accounts[1], BLOCK_TIME)

    # TODO: replicate the settle assets calc in python so we can fuzz this
    # assert bc[0] == (1, )

    # This will assert the values from the view match the values from the stateful method
    mockSettleAssets.testSettleAssetArray(accounts[1], BLOCK_TIME)

    # Assert that the rate is set after
    value = mockSettleAssets.assetToUnderlyingSettlementRateMapping(2, 5000)
    assert value == (18, BLOCK_TIME, 0.05e18)

    # Assert that markets have been updated
    value = mockSettleAssets.marketStateMapping(1, 1000)
    liquidity = mockSettleAssets.marketTotalLiquidityMapping(1, 1000)
    assert value == (0.8e18, 0.8e18, 0, 0, 0)
    assert liquidity == 0.8e18

    remainingAssets = list(filter(lambda x: x[1] > BLOCK_TIME, assetArray))
    assets = mockSettleAssets.getAssetArray(accounts[1])
    assert sorted(assets) == sorted(remainingAssets)

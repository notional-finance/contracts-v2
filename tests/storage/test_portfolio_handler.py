import random

import pytest
from brownie.test import given, strategy
from tests.constants import *


@pytest.fixture(scope="module", autouse=True)
def portfolioHandler(MockPortfolioHandler, accounts):
    handler = MockPortfolioHandler.deploy({"from": accounts[0]})
    return handler


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def generate_random_asset():
    currencyId = random.randint(1, 5)
    assetType = random.randint(1, 2)
    maturity = random.randrange(0, 360 * SECONDS_IN_DAY, 10)

    if assetType == 1:
        notional = random.randint(-1e18, 1e18)
    else:
        notional = random.randint(0.1e18, 1e18)

    return (currencyId, maturity, assetType, notional)


@given(num_assets=strategy("uint", min_value=0, max_value=40))
def test_portfolio_sorting(portfolioHandler, accounts, num_assets):
    storedPortfolio = [generate_random_asset() for i in range(0, num_assets)]
    portfolioHandler.setAssetArray(accounts[1], storedPortfolio)
    state = portfolioHandler.buildPortfolioState(accounts[1], 0)

    sortedIndexes = portfolioHandler.calculateSortedIndex(state)

    pythonSorted = sorted(storedPortfolio)
    computedSort = tuple([state[0][i][0:3] for i in sortedIndexes])

    assert computedSort == tuple([p[0:3] for p in pythonSorted])


@given(num_assets=strategy("uint", min_value=0, max_value=40))
def test_portfolio_handler(portfolioHandler, accounts, num_assets):
    storedPortfolio = [generate_random_asset() for i in range(0, num_assets)]

    portfolioHandler.setAssetArray(accounts[1], storedPortfolio)
    state = portfolioHandler.buildPortfolioState(accounts[1], 0)

    # deletes will always come before adds
    num_deletes = random.randint(0, len(storedPortfolio))
    delete_indexes = sorted(random.sample(range(0, len(storedPortfolio)), num_deletes))
    # settling will result in indexes being deleted in order
    for d in delete_indexes:
        state = portfolioHandler.deleteAsset(state, d)
        # Assert that asset has been marked as removed
        assert state[0][d][4] == 2

    newAssets = sorted([generate_random_asset() for i in range(0, 5)])
    # do 5 random add asset operations
    for i in range(0, 5):
        action = random.randint(0, 2)
        activeIndexes = [i for i, x in enumerate(state[0]) if x[4] != 2]
        if len(activeIndexes) == 0:
            action = 0

        if action == 0:
            # insert a new asset
            newAsset = newAssets[i]

            state = portfolioHandler.addAsset(
                state,
                newAsset[0],  # currency id
                newAsset[1],  # maturity
                newAsset[2],  # asset type
                newAsset[3],  # notional
                False,
            )

            assert state[1][-1] == tuple(list(newAsset) + [0])

        elif action == 1:
            # update an asset
            index = random.sample(activeIndexes, 1)[0]
            asset = state[0][index]
            if asset[2] == 2:
                notional = random.randint(-asset[3], 1e18)
            else:
                notional = random.randint(-1e18, 1e18)

            state = portfolioHandler.addAsset(
                state,
                asset[0],  # currency id
                asset[1],  # maturity
                asset[2],  # asset type
                notional,
                False,
            )

            assert state[0][index][4] == 1
            assert state[0][index][3] == asset[3] + notional

        elif action == 2:
            # net off an asset
            index = random.sample(activeIndexes, 1)[0]
            asset = state[0][index]
            notional = asset[3] * -1

            state = portfolioHandler.addAsset(
                state,
                asset[0],  # currency id
                asset[1],  # maturity
                asset[2],  # asset type
                notional,
                False,
            )

            assert state[0][index][4] == 1
            assert state[0][index][3] == asset[3] + notional

    # Test merged array
    mergedArray = portfolioHandler.getMergedArray(state)
    activeStored = [(x[0], x[1], x[2], x[3]) for x in filter(lambda x: x[4] != 2, state[0])]
    newAsset = [(x[0], x[1], x[2], x[3]) for x in state[1]]
    assert [x[0:4] for x in mergedArray] == sorted(activeStored + newAsset)

    portfolioHandler.storeAssets(accounts[1], state)
    finalStored = portfolioHandler.getAssetArray(accounts[1])
    # Filter out the active assets with zero notional
    finalComputed = tuple(list(filter(lambda x: x[3] != 0, activeStored)) + newAsset)

    # Remove final from array
    assert sorted(finalStored) == sorted(finalComputed)

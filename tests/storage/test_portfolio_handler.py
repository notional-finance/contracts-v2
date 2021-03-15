import random

import pytest
from brownie.convert.datatypes import HexString
from brownie.test import given, strategy
from tests.constants import *
from tests.helpers import active_currencies_to_list


@pytest.fixture(scope="module", autouse=True)
def portfolioHandler(MockPortfolioHandler, accounts):
    handler = MockPortfolioHandler.deploy({"from": accounts[0]})
    return handler


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def generate_random_asset():
    currencyId = random.randint(1, 5)
    assetType = random.randint(1, 7)
    maturity = random.randrange(0, 360 * SECONDS_IN_DAY, 10)

    if assetType == 1:
        notional = random.randint(-1e18, 1e18)
    else:
        notional = random.randint(0.1e18, 1e18)

    return (currencyId, maturity, assetType, notional, 0)


@given(num_assets=strategy("uint", min_value=0, max_value=9))
def test_portfolio_sorting(portfolioHandler, accounts, num_assets):
    newAssets = [generate_random_asset() for i in range(0, num_assets)]
    portfolioHandler.storeAssets(accounts[1], ([], newAssets, num_assets, 0, []))
    state = portfolioHandler.buildPortfolioState(accounts[1], 0)

    sortedIndexes = portfolioHandler.calculateSortedIndex(state)

    pythonSorted = sorted(newAssets)
    computedSort = tuple([state[0][i][0:3] for i in sortedIndexes])

    assert computedSort == tuple([p[0:3] for p in pythonSorted])

    sortedArray = portfolioHandler.getAssetArray(accounts[1])
    assert computedSort == tuple([s[0:3] for s in sortedArray])


@given(num_assets=strategy("uint", min_value=0, max_value=9))
def test_add_delete_assets(portfolioHandler, accounts, num_assets):
    startingAssets = [generate_random_asset() for i in range(0, num_assets)]

    portfolioHandler.storeAssets(accounts[1], ([], startingAssets, len(startingAssets), 0, []))
    state = portfolioHandler.buildPortfolioState(accounts[1], 0)

    # deletes will always come before adds
    num_deletes = random.randint(0, len(startingAssets))
    delete_indexes = sorted(random.sample(range(0, len(startingAssets)), num_deletes))

    # settling will result in indexes being deleted in order
    for d in delete_indexes:
        state = portfolioHandler.deleteAsset(state, d)
        # Assert that asset has been marked as removed
        assert state[0][d][4] == 2
        tmp = list(startingAssets[d])
        tmp[3] = 0  # mark notional as zero
        startingAssets[d] = tuple(tmp)

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

            assert state[1][-1] == newAsset
            startingAssets.append(newAsset)

        elif action == 1:
            # update an asset
            index = random.sample(activeIndexes, 1)[0]
            asset = state[0][index]
            if asset[2] >= 2:
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
            tmp = list(startingAssets[index])
            tmp[3] += notional
            startingAssets[index] = tuple(tmp)

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
            tmp = list(startingAssets[index])
            tmp[3] = 0  # mark notional as zero
            startingAssets[index] = tuple(tmp)

    txn = portfolioHandler.storeAssets(accounts[1], state)
    (hasDebt, activeCurrencies) = txn.return_value
    finalStored = portfolioHandler.getAssetArray(accounts[1])
    # Filter out the active assets with zero notional from the computed list
    finalComputed = tuple(list(filter(lambda x: x[3] != 0, startingAssets)))

    context = portfolioHandler.getAccountContext(accounts[1])
    assert context[2] == len(finalComputed)  # assert length is correct

    # assert nextMaturingAsset is correct
    if len(finalComputed) == 0:
        assert context[0] == 0
    else:
        assert context[0] == min([x[1] for x in finalComputed])

    # assert that hasDebt is correct
    if len(finalComputed) == 0:
        assert not hasDebt
    else:
        assert hasDebt == ((min([x[3] for x in finalComputed])) < 0)

    # assert that active currencies has all the currencies
    if len(finalComputed) == 0:
        assert activeCurrencies == HexString("0x00", "bytes32")
    else:
        activeCurrencyList = list(
            filter(lambda x: x != 0, sorted(active_currencies_to_list(activeCurrencies)))
        )
        currencies = [x[0] for x in sorted(finalComputed)]
        assert activeCurrencyList == currencies

    assert sorted(finalStored) == sorted(finalComputed)

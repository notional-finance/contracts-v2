import random

import brownie
import pytest
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import START_TIME
from tests.helpers import active_currencies_to_list, get_portfolio_array, get_settlement_date

chain = Chain()

AssetStorageState = {"NoChange": 0, "Update": 1, "Delete": 2, "RevertIfStored": 3}


def generate_asset_array(num_assets):
    cashGroups = [(1, 7), (2, 7), (3, 7)]
    return get_portfolio_array(num_assets, cashGroups)


@pytest.mark.portfolio
class TestPortfolioHandler:
    @pytest.fixture(scope="module", autouse=True)
    def portfolioHandler(self, MockPortfolioHandler, accounts):
        handler = MockPortfolioHandler.deploy({"from": accounts[0]})
        chain.mine(1, timestamp=START_TIME)

        return handler

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_store_asset_reverts_on_tainted_asset(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        assets = [(2, maturity, 1, 100e8, 1, AssetStorageState["RevertIfStored"])]
        with brownie.reverts():
            portfolioHandler.storeAssets(accounts[1], (assets, [], 0, 1))

        with brownie.reverts():
            portfolioHandler.storeAssets(accounts[1], ([], assets, 1, 0))

    def test_add_delete_asset_reverts_on_tainted_asset(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        assets = [(2, maturity, 1, 100e8, 1, 1)]
        portfolioHandler.storeAssets(accounts[1], ([], assets, 1, 0))
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = list(portfolioHandler.buildPortfolioState(accounts[1], 0))
        state[0] = list(state[0])
        state[0][0] = list(state[0][0])
        state[0][0][5] = AssetStorageState["RevertIfStored"]

        with brownie.reverts():
            portfolioHandler.addAsset(state, 2, maturity, 1, 100e8)

        with brownie.reverts():
            portfolioHandler.deleteAsset(state, 0)

    def test_delete_asset_reverts_on_deleted_asset(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        assets = [(2, maturity, 1, 100e8, 1, AssetStorageState["Update"])]
        portfolioHandler.storeAssets(accounts[1], ([], assets, 1, 0))
        state = list(portfolioHandler.buildPortfolioState(accounts[1], 0))
        state[0] = list(state[0])
        state[0][0] = list(state[0][0])
        state[0][0][5] = AssetStorageState["Delete"]

        with brownie.reverts():
            portfolioHandler.deleteAsset(state, 0)

    @given(num_assets=strategy("uint", min_value=0, max_value=7))
    def test_portfolio_sorting(self, portfolioHandler, accounts, num_assets):
        newAssets = generate_asset_array(num_assets)
        portfolioHandler.storeAssets(accounts[1], ([], newAssets, num_assets, 0))

        computedSort = tuple([p[0:3] for p in sorted(newAssets)])
        sortedArray = portfolioHandler.getAssetArray(accounts[1])
        assert computedSort == tuple([s[0:3] for s in sortedArray])

    def test_new_assets_merge(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, 100e8)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, -300e8)
        assert len(state["newAssets"]) == 1
        assert state["newAssets"][0][3] == -200e8
        assert state["newAssets"][0][5] == AssetStorageState["Update"]

        self.context_invariants(portfolioHandler, state, accounts)

    def test_new_assets_append(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, 100e8)
        state = portfolioHandler.addAsset(state, 2, maturity, 1, 100e8)
        assert len(state["newAssets"]) == 2
        assert state["newAssets"][0][0] == 1
        assert state["newAssets"][0][5] == AssetStorageState["NoChange"]
        assert state["newAssets"][1][0] == 2
        assert state["newAssets"][1][5] == AssetStorageState["NoChange"]

        self.context_invariants(portfolioHandler, state, accounts)

    def test_new_assets_net_off(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, 100e8)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, -100e8)
        assert len(state["newAssets"]) == 1
        assert state["newAssets"][0][3] == 0
        assert state["newAssets"][0][5] == AssetStorageState["Update"]

        self.context_invariants(portfolioHandler, state, accounts)

    @given(isDebt=strategy("bool"))
    def test_stored_assets_merge(self, portfolioHandler, accounts, isDebt):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, 100e8)
        portfolioHandler.storeAssets(accounts[1], state)

        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, -200e8 if isDebt else 100e8)
        assert len(state["newAssets"]) == 0
        if isDebt:
            assert state["storedAssets"][0][3] == -100e8
        else:
            assert state["storedAssets"][0][3] == 200e8
        assert state["storedAssets"][0][5] == AssetStorageState["Update"]

        self.context_invariants(portfolioHandler, state, accounts)

    @given(isFirstDebt=strategy("bool"), isSecondDebt=strategy("bool"))
    def test_stored_assets_append(self, portfolioHandler, accounts, isFirstDebt, isSecondDebt):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, -100e8 if isFirstDebt else 100e8)
        portfolioHandler.storeAssets(accounts[1], state)

        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 2, maturity, 1, -100e8 if isSecondDebt else 100e8)
        assert len(state["storedAssets"]) == 1
        assert len(state["newAssets"]) == 1
        assert state["newAssets"][0][0] == 2
        assert state["newAssets"][0][3] == -100e8 if isSecondDebt else 100e8
        assert state["newAssets"][0][5] == AssetStorageState["NoChange"]

        self.context_invariants(portfolioHandler, state, accounts)

    def test_stored_assets_insert_between(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, 100e8)
        state = portfolioHandler.addAsset(state, 1, maturity + 1000, 1, 100e8)
        portfolioHandler.storeAssets(accounts[1], state)

        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity + 500, 1, -100e8)
        self.context_invariants(portfolioHandler, state, accounts)

    def test_stored_assets_delete_between(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, 100e8)
        state = portfolioHandler.addAsset(state, 1, maturity + 500, 1, -100e8)
        state = portfolioHandler.addAsset(state, 1, maturity + 1000, 1, 100e8)
        portfolioHandler.storeAssets(accounts[1], state)

        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity + 500, 1, 100e8)
        self.context_invariants(portfolioHandler, state, accounts)

    def test_stored_assets_net_off(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, 100e8)
        portfolioHandler.storeAssets(accounts[1], state)

        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, -100e8)
        assert len(state["storedAssets"]) == 1
        assert state["storedAssets"][0][3] == 0
        assert state["storedAssets"][0][5] == AssetStorageState["Update"]

        self.context_invariants(portfolioHandler, state, accounts)

    def test_stored_assets_delete(self, portfolioHandler, accounts):
        maturity = chain.time() + 1000
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, maturity, 1, 100e8)
        state = portfolioHandler.addAsset(state, 2, maturity, 1, -100e8)
        portfolioHandler.storeAssets(accounts[1], state)

        stateBefore = portfolioHandler.buildPortfolioState(accounts[1], 0)

        # Delete the first index
        stateAfter = portfolioHandler.deleteAsset(stateBefore, 0)
        assert stateAfter["storedAssetLength"] == 1
        assert stateAfter["storedAssets"][0][5] == AssetStorageState["Delete"]
        # storage slots are swapped
        assert stateAfter["storedAssets"][0][4] == stateBefore["storedAssets"][1][4]
        assert stateAfter["storedAssets"][1][4] == stateBefore["storedAssets"][0][4]

        self.context_invariants(portfolioHandler, stateAfter, accounts)

        chain.undo()
        # Delete the second index
        stateAfter = portfolioHandler.deleteAsset(stateBefore, 1)
        assert stateAfter["storedAssetLength"] == 1
        assert stateAfter["storedAssets"][1][5] == AssetStorageState["Delete"]
        # storage slot does not change
        assert stateAfter["storedAssets"][1][4] == stateBefore["storedAssets"][1][4]

        self.context_invariants(portfolioHandler, stateAfter, accounts)

    def test_cannot_store_matured_assets(self, portfolioHandler, accounts):
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        state = portfolioHandler.addAsset(state, 1, chain.time() - 100, 1, 100e8)
        with brownie.reverts("dev: cannot store matured assets"):
            portfolioHandler.storeAssets(accounts[1], state)

    def test_can_store_empty_array(self, portfolioHandler, accounts):
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        self.context_invariants(portfolioHandler, state, accounts)

    @given(num_assets=strategy("uint", min_value=0, max_value=7))
    def test_add_delete_assets(self, portfolioHandler, accounts, num_assets):
        assetArray = generate_asset_array(num_assets + 5)
        startingAssets = assetArray[0:num_assets]
        newAssets = assetArray[num_assets:]

        portfolioHandler.storeAssets(accounts[1], ([], startingAssets, len(startingAssets), 0))
        state = portfolioHandler.buildPortfolioState(accounts[1], 0)
        # build portfolio state returns a sorted list
        startingAssets = list(state[0])

        # deletes will always come before adds
        num_deletes = random.randint(0, len(startingAssets))
        delete_indexes = sorted(random.sample(range(0, len(startingAssets)), num_deletes))

        # settling will result in indexes being deleted in order
        for d in delete_indexes:
            state = portfolioHandler.deleteAsset(state, d)
            # Assert that asset has been marked as removed
            assert state[0][d][5] == 2
            assert state[-1] == len([x for x in state[0] if x[5] != 2])
            tmp = list(startingAssets[d])
            tmp[3] = 0  # mark notional as zero
            startingAssets[d] = tuple(tmp)

        # do 5 random add asset operations
        for i in range(0, 5):
            action = random.randint(0, 2)
            activeIndexes = [i for i, x in enumerate(state[0]) if x[5] != 2]
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
                )

                # search backwards from the end for the new asset
                index = -1
                while state[1][index][0] == 0:
                    index -= 1

                assert state[1][index] == newAsset
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
                )

                assert state[0][index][5] == 1
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
                )

                assert state[0][index][5] == 1
                assert state[0][index][3] == asset[3] + notional
                tmp = list(startingAssets[index])
                tmp[3] = 0  # mark notional as zero
                startingAssets[index] = tuple(tmp)

        self.context_invariants(portfolioHandler, state, accounts)

    def context_invariants(self, portfolioHandler, state, accounts):
        assetsStart = portfolioHandler.getAssetArray(accounts[1])
        assetsFinal = state["storedAssets"] + state["newAssets"]

        txn = portfolioHandler.storeAssets(accounts[1], state)
        (context) = txn.return_value
        finalStored = portfolioHandler.getAssetArray(accounts[1])

        # Filter out the active assets with zero notional from the computed list
        finalComputed = tuple(
            list(filter(lambda x: x[3] != 0 and x[5] != AssetStorageState["Delete"], assetsFinal))
        )

        assert sorted([x[0:4] for x in finalStored]) == sorted([(x[0:4]) for x in finalComputed])

        # assert length is correct
        assert context[2] == len(finalComputed)

        # assert nextSettleTime is correct
        if len(finalComputed) == 0:
            assert context[0] == 0
        else:
            assert context[0] == min([get_settlement_date(x, chain.time()) for x in finalComputed])

        # assert that hasDebt is correct
        if len(finalComputed) == 0:
            assert context[1] == "0x00"
        else:
            hasDebt = (min([x[3] for x in finalComputed])) < 0
            if hasDebt:
                assert context[1] != "0x00"
            else:
                assert context[1] == "0x00"

        # assert that active currencies has all the currencies
        if len(finalComputed) == 0:
            assert context[4] == HexString("0x00", "bytes18")
        else:
            activeCurrencyList = list(
                filter(lambda x: x != 0, sorted(active_currencies_to_list(context[4])))
            )
            currencies = list(sorted(set([(x[0], True, False) for x in finalComputed])))
            assert activeCurrencyList == currencies

        # Create assetsStart and assetsFinal by matching keys
        matchingfCash = {}
        for a in assetsStart:
            if a[2] != 1:
                continue
            matchingfCash[a[0:2]] = (a[3], 0)

        for a in finalStored:
            if a[2] != 1:
                continue
            key = a[0:2]
            if key in matchingfCash:
                matchingfCash[key] = (matchingfCash[key][0], a[3])
            else:
                matchingfCash[key] = (0, a[3])

        debtEvents = []
        if 'TransferBatch' in txn.events:
            for t in txn.events['TransferBatch']:
                (currencyId, maturity, isfCashDebt) = portfolioHandler.decodefCashId(t['ids'][1])
                if not isfCashDebt:
                    continue

                debtEvents.append({
                    'netDebtChange': -t['values'][1] if t['from'] == brownie.ZERO_ADDRESS else t['values'][1],
                    'currencyId': currencyId,
                    'maturity': maturity
                })

        for ((currencyId, maturity), (before, after)) in matchingfCash.items():
            event = list(
                filter(
                    lambda x: x["currencyId"] == currencyId and x["maturity"] == maturity,
                    debtEvents,
                )
            )
            negChange = portfolioHandler.negChange(before, after)

            if negChange == 0:
                assert len(event) == 0
            else:
                assert len(event) == 1
                assert event[0]["netDebtChange"] == -negChange

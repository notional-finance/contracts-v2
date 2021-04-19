import random

import pytest
from brownie.convert.datatypes import HexString
from brownie.test import given, strategy
from hypothesis import settings
from tests.constants import MARKETS, SECONDS_IN_DAY, SECONDS_IN_YEAR, SETTLEMENT_DATE, START_TIME
from tests.helpers import get_bitstring_from_bitmap, get_market_state
from tests.internal.settlement.test_settle_assets import (
    NUM_CURRENCIES,
    SETTLEMENT_RATE,
    get_settle_rate,
)


@pytest.mark.settlement
class TestSettleBitmap:
    @pytest.fixture(scope="module", autouse=True)
    def mockAggregators(self, MockCToken, cTokenAggregator, accounts):
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
    def mockSettleAssets(self, MockSettleAssets, mockAggregators, accounts):
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

    @given(
        nextSettleTime=strategy(
            "uint", min_value=START_TIME, max_value=START_TIME + (40 * SECONDS_IN_YEAR)
        )
    )
    @settings(max_examples=20)
    @pytest.mark.no_call_coverage
    def test_settle_ifcash_bitmap(self, mockSettleAssets, accounts, nextSettleTime):
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
                mockSettleAssets.setifCash(
                    accounts[0], currencyId, maturity, notional, nextSettleTime
                )

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

    @given(daysOffset=strategy("uint", min_value=1, max_value=89))
    @pytest.mark.skip_coverage
    def test_settle_and_remap(self, mockSettleAssets, accounts, daysOffset):
        nextSettleTime = START_TIME - START_TIME % SECONDS_IN_DAY
        blockTime = nextSettleTime + daysOffset * SECONDS_IN_DAY

        # TODO: this test only works for the first 90 days because otherwise it requires subsequent
        # bits to get shifted down
        dayBits = HexString(int("".ljust(256, "0"), 2), "bytes32")
        weekBits = HexString(
            int("".join([str(random.randint(0, 1)) for i in range(0, 45)]).ljust(256, "0"), 2),
            "bytes32",
        )
        monthBits = HexString(
            int("".join([str(random.randint(0, 1)) for i in range(0, 60)]).ljust(256, "0"), 2),
            "bytes32",
        )
        quarterBits = HexString(
            int("".join([str(random.randint(0, 1)) for i in range(0, 61)]).ljust(256, "0"), 2),
            "bytes32",
        )
        splitBitmap = (dayBits, weekBits, monthBits, quarterBits)

        newSplitBitmap = mockSettleAssets._remapBitmap(splitBitmap, nextSettleTime, blockTime)

        prevCombinedBitmap = mockSettleAssets._combineBitmap(splitBitmap)
        newCombinedBitmap = mockSettleAssets._combineBitmap(newSplitBitmap)

        # test that all the bits in the newSplitBitmap correspond to maturities in the
        # previous split bitmap
        prevSetBits = list(
            filter(
                lambda x: x[1] == "1",
                enumerate(list(get_bitstring_from_bitmap(prevCombinedBitmap))),
            )
        )
        newSetBits = list(
            filter(
                lambda x: x[1] == "1", enumerate(list(get_bitstring_from_bitmap(newCombinedBitmap)))
            )
        )

        prevMaturities = [
            mockSettleAssets.getMaturityFromBitNum(nextSettleTime, i + 1) for (i, _) in prevSetBits
        ]
        newMaturities = [
            mockSettleAssets.getMaturityFromBitNum(blockTime, i + 1) for (i, _) in newSetBits
        ]

        count = 0
        for m in prevMaturities:
            if m > blockTime:
                assert m in newMaturities
                count += 1

        assert len(newMaturities) == count

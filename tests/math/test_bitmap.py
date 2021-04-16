import random

import pytest
from brownie.test import given, strategy


@pytest.mark.math
class TestBitmap:
    @pytest.fixture(scope="module", autouse=True)
    def mockBitmap(self, MockBitmap, accounts):
        return accounts[0].deploy(MockBitmap)

    @given(bitmap=strategy("bytes32"))
    def test_is_bit_set(self, mockBitmap, bitmap):
        index = random.randint(1, 256)
        bitmask = list("".zfill(256))
        bitmask[index - 1] = "1"
        bitmask = "".join(bitmask)

        result = mockBitmap.isBitSet(bitmap, index)
        computedResult = (int(bitmask, 2) & int(bitmap.hex(), 16)) != 0
        assert result == computedResult

    @given(bitmap=strategy("bytes32"))
    def test_set_bit_on(self, mockBitmap, bitmap):
        index = random.randint(1, 256)
        newBitmap = mockBitmap.setBit(bitmap, index, True)
        assert mockBitmap.isBitSet(newBitmap, index)

    @given(bitmap=strategy("bytes32"))
    def test_set_bit_off(self, mockBitmap, bitmap):
        index = random.randint(1, 256)
        newBitmap = mockBitmap.setBit(bitmap, index, False)
        assert not mockBitmap.isBitSet(newBitmap, index)

    @given(bitmap=strategy("bytes32"))
    def test_total_bits_set(self, mockBitmap, bitmap):
        total = mockBitmap.totalBitsSet(bitmap)
        bitstring = "{:08b}".format(int(bitmap.hex(), 16))
        computedTotal = len([x for x in filter(lambda x: x == "1", list(bitstring))])

        assert total == computedTotal

    def test_fcash_bitmap_max_range(self, mockBitmap):
        zeroBits = hex(int("".ljust(256, "0"), 2))
        dayBits = hex(int("".join(["1" for i in range(0, 90)]).ljust(256, "0"), 2))
        weekBits = zeroBits
        monthBits = zeroBits
        quarterBits = zeroBits

        bitmap = mockBitmap.combineAssetBitmap((dayBits, weekBits, monthBits, quarterBits))
        (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitAssetBitmap(bitmap)

        assert daysOut == dayBits
        assert weeksOut == weekBits
        assert monthsOut == monthBits
        assert quartersOut == quarterBits

        dayBits = zeroBits
        weekBits = hex(int("".join(["1" for i in range(0, 45)]).ljust(256, "0"), 2))

        bitmap = mockBitmap.combineAssetBitmap((dayBits, weekBits, monthBits, quarterBits))
        (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitAssetBitmap(bitmap)

        assert daysOut == dayBits
        assert weeksOut == weekBits
        assert monthsOut == monthBits
        assert quartersOut == quarterBits

        weekBits = zeroBits
        monthBits = hex(int("".join(["1" for i in range(0, 60)]).ljust(256, "0"), 2))

        bitmap = mockBitmap.combineAssetBitmap((dayBits, weekBits, monthBits, quarterBits))
        (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitAssetBitmap(bitmap)

        assert daysOut == dayBits
        assert weeksOut == weekBits
        assert monthsOut == monthBits
        assert quartersOut == quarterBits

        monthBits = zeroBits
        quarterBits = hex(int("".join(["1" for i in range(0, 61)]).ljust(256, "0"), 2))

        bitmap = mockBitmap.combineAssetBitmap((dayBits, weekBits, monthBits, quarterBits))
        (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitAssetBitmap(bitmap)

        assert daysOut == dayBits
        assert weeksOut == weekBits
        assert monthsOut == monthBits
        assert quartersOut == quarterBits

    def test_fcash_bitmap_random_range(self, mockBitmap):
        for _ in range(0, 50):
            dayBits = hex(
                int("".join([str(random.randint(0, 1)) for i in range(0, 90)]).ljust(256, "0"), 2)
            )
            weekBits = hex(
                int("".join([str(random.randint(0, 1)) for i in range(0, 45)]).ljust(256, "0"), 2)
            )
            monthBits = hex(
                int("".join([str(random.randint(0, 1)) for i in range(0, 60)]).ljust(256, "0"), 2)
            )
            quarterBits = hex(
                int("".join([str(random.randint(0, 1)) for i in range(0, 61)]).ljust(256, "0"), 2)
            )

            bitmap = mockBitmap.combineAssetBitmap((dayBits, weekBits, monthBits, quarterBits))
            (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitAssetBitmap(bitmap)

            assert daysOut == dayBits
            assert weeksOut == weekBits
            assert monthsOut == monthBits
            assert quartersOut == quarterBits

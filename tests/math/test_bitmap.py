import random

import pytest
from brownie.test import given, strategy


@pytest.fixture(scope="module", autouse=True)
def mockBitmap(MockBitmap, accounts):
    return accounts[0].deploy(MockBitmap)


@given(bitmap=strategy("bytes"))
def test_is_bit_set(mockBitmap, bitmap):
    print(bitmap)
    index = random.randint(1, len(bitmap) * 8)
    bitmask = list("".zfill(len(bitmap) * 8))
    bitmask[index - 1] = "1"
    bitmask = "".join(bitmask)

    print("index", index)
    print("bitmask", bitmask)
    print("bitmap {:08b}".format(int(bitmap.hex(), 16)))

    result = mockBitmap.isBitSet(bitmap, index)
    print(result)
    computedResult = (int(bitmask, 2) & int(bitmap.hex(), 16)) != 0
    assert result == computedResult


@given(bitmap=strategy("bytes"))
def test_set_bit_on(mockBitmap, bitmap):
    index = random.randint(1, len(bitmap) * 64)
    newBitmap = mockBitmap.setBit(bitmap, index, True)
    assert mockBitmap.isBitSet(newBitmap, index)


@given(bitmap=strategy("bytes"))
def test_set_bit_off(mockBitmap, bitmap):
    index = random.randint(1, len(bitmap) * 64)
    newBitmap = mockBitmap.setBit(bitmap, index, False)
    assert not mockBitmap.isBitSet(newBitmap, index)


@given(bitmap=strategy("bytes"))
def test_total_bits_set(mockBitmap, bitmap):
    total = mockBitmap.totalBitsSet(bitmap)
    bitstring = "{:08b}".format(int(bitmap.hex(), 16))
    computedTotal = len([x for x in filter(lambda x: x == "1", list(bitstring))])

    assert total == computedTotal


def test_fcash_bitmap_max_range(mockBitmap):
    zeroBits = hex(int("".ljust(256, "0"), 2))
    dayBits = hex(int("".join(["1" for i in range(0, 90)]).ljust(256, "0"), 2))
    weekBits = zeroBits
    monthBits = zeroBits
    quarterBits = zeroBits

    bitmap = mockBitmap.combinefCashBitmap((dayBits, weekBits, monthBits, quarterBits))
    (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitfCashBitmap(bitmap)

    assert daysOut == dayBits
    assert weeksOut == weekBits
    assert monthsOut == monthBits
    assert quartersOut == quarterBits

    dayBits = zeroBits
    weekBits = hex(int("".join(["1" for i in range(0, 45)]).ljust(256, "0"), 2))

    bitmap = mockBitmap.combinefCashBitmap((dayBits, weekBits, monthBits, quarterBits))
    (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitfCashBitmap(bitmap)

    assert daysOut == dayBits
    assert weeksOut == weekBits
    assert monthsOut == monthBits
    assert quartersOut == quarterBits

    weekBits = zeroBits
    monthBits = hex(int("".join(["1" for i in range(0, 60)]).ljust(256, "0"), 2))

    bitmap = mockBitmap.combinefCashBitmap((dayBits, weekBits, monthBits, quarterBits))
    (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitfCashBitmap(bitmap)

    assert daysOut == dayBits
    assert weeksOut == weekBits
    assert monthsOut == monthBits
    assert quartersOut == quarterBits

    monthBits = zeroBits
    quarterBits = hex(int("".join(["1" for i in range(0, 61)]).ljust(256, "0"), 2))

    bitmap = mockBitmap.combinefCashBitmap((dayBits, weekBits, monthBits, quarterBits))
    (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitfCashBitmap(bitmap)

    assert daysOut == dayBits
    assert weeksOut == weekBits
    assert monthsOut == monthBits
    assert quartersOut == quarterBits


def test_fcash_bitmap_random_range(mockBitmap):
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

        bitmap = mockBitmap.combinefCashBitmap((dayBits, weekBits, monthBits, quarterBits))
        (daysOut, weeksOut, monthsOut, quartersOut) = mockBitmap.splitfCashBitmap(bitmap)

        assert daysOut == dayBits
        assert weeksOut == weekBits
        assert monthsOut == monthBits
        assert quartersOut == quarterBits

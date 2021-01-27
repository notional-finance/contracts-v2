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

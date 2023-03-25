import pytest
from brownie.test import given, strategy


class TestFloatingPoint:
    @pytest.fixture(scope="module", autouse=True)
    def floatingPoint(self, accounts, MockFloatingPoint):
        return accounts[0].deploy(MockFloatingPoint)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @given(value=strategy("uint128"))
    def test_floating_point_56(self, floatingPoint, value):
        (packed, unpacked) = floatingPoint.testPackingUnpacking56(value)

        bitsShifted = int(packed.hex()[-2:], 16)
        # This is the max bit shift
        assert bitsShifted <= (128 - 47)
        # Assert packed is always less than 56 bits, means that the
        # top 50 values (256 - 56 = 200 bits) and 4 bits per character
        # equals 50 values
        assert str(packed.hex())[0:50] == "0" * 50
        # Assert unpacked is always approximately value
        if value < (2 ** 48 - 1):
            assert bitsShifted == 0
            assert unpacked == value
        else:
            maxPrecisionLoss = 2 ** bitsShifted
            assert value - unpacked < maxPrecisionLoss
            assert (value >> bitsShifted) == (unpacked >> bitsShifted)

    @given(value=strategy("uint128"))
    def test_floating_point_32(self, floatingPoint, value):
        (packed, unpacked) = floatingPoint.testPackingUnpacking32(value)

        bitsShifted = int(packed.hex()[-2:], 16)
        # This is the max bit shift
        assert bitsShifted <= (128 - 23)
        # Assert packed is always less than 32 bits, means that the
        # top 56 values (256 - 32 = 224 bits) and 4 bits per character
        # equals 56 values
        assert str(packed.hex())[0:56] == "0" * 56
        # Assert unpacked is always approximately value
        if value < (2 ** 24 - 1):
            assert bitsShifted == 0
            assert unpacked == value
        else:
            maxPrecisionLoss = 2 ** bitsShifted
            assert value - unpacked < maxPrecisionLoss
            assert (value >> bitsShifted) == (unpacked >> bitsShifted)

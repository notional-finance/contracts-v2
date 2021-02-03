import pytest
from brownie.test import given, strategy


@pytest.fixture(scope="module", autouse=True)
def storageLayout(MockStorageUtils, accounts):
    layout = MockStorageUtils.deploy({"from": accounts[0]})
    return layout


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@given(
    currencyId=strategy("uint16"),
    maturity=strategy("uint40"),
    rand32=strategy("uint32"),
    rand80=strategy("uint80"),
)
def test_market_storage(storageLayout, currencyId, maturity, rand32, rand80):
    storedMarket = (rand80, rand80 + 1, rand32, rand32 + 1, rand32 + 2)
    storageLayout.setMarketStorage(currencyId, maturity, storedMarket)
    storageLayout.setTotalLiquidity(currencyId, maturity, rand80 + 3)
    market = storageLayout._getMarketStorage(currencyId, maturity)
    liquidity = storageLayout._getTotalLiquidity(currencyId, maturity)
    assert market == storedMarket
    assert liquidity == rand80 + 3

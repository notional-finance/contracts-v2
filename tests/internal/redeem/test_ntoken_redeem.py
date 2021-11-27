import random

import pytest
from brownie.test import given, strategy
from tests.constants import SECONDS_IN_DAY, SECONDS_IN_QUARTER, SETTLEMENT_DATE, START_TIME_TREF
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_fcash_token,
    get_liquidity_token,
    get_market_curve,
    random_asset_bitmap,
)

currencyId = 1
tokenAddress = None


@pytest.fixture(scope="module", autouse=True)
def nTokenRedeem(MockNTokenRedeem, MockCToken, cTokenAggregator, accounts):
    global tokenAddress
    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})
    cToken.setAnswer(200000000000000000000000000, {"from": accounts[0]})
    tokenAddress = accounts[9]

    mock = MockNTokenRedeem.deploy({"from": accounts[0]})
    # set cash group and asset rate mapping
    cashGroup = get_cash_group_with_max_markets(3)
    mock.setCashGroup(currencyId, cashGroup, (aggregator.address, 18))
    # set markets
    marketStates = get_market_curve(3, "flat")
    for m in marketStates:
        mock.setMarketStorage(1, SETTLEMENT_DATE, m)
        # set matching fCash assets
        mock.setfCash(
            currencyId,
            tokenAddress,
            m[1],  # maturity
            START_TIME_TREF,
            m[2],  # fCash, TODO may need to vary this
        )

    # set nToken portfolio
    tokens = [get_liquidity_token(1), get_liquidity_token(2), get_liquidity_token(3)]

    mock.setNToken(
        1,
        tokenAddress,
        ([], tokens, 3, 0),
        1e18,
        1000e8,  # TODO: vary this cash balance a bit
        START_TIME_TREF,
    )

    return mock


@pytest.fixture(scope="module", autouse=True)
def nTokenRedeemPure(MockNTokenRedeemPure, accounts):
    return MockNTokenRedeemPure.deploy({"from": accounts[0]})


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@given(initalizedTimeOffset=strategy("uint32", min_value=0, max_value=89))
def test_get_ifCash_bits(nTokenRedeemPure, accounts, initalizedTimeOffset):
    (bitmap, _) = random_asset_bitmap(15)
    lastInitializedTime = START_TIME_TREF + initalizedTimeOffset * SECONDS_IN_DAY
    # add random ifcash assets at various maturities
    # test that the bits returned are always ifcash
    nTokenRedeemPure.setAssetsBitmap(tokenAddress, currencyId, bitmap)
    blockTime = START_TIME_TREF + random.randint(0, (SECONDS_IN_QUARTER - initalizedTimeOffset))

    # This should not revert
    nTokenRedeemPure.test_getifCashBits(tokenAddress, currencyId, lastInitializedTime, blockTime, 7)


@pytest.mark.only
def test_add_residuals_to_assets(nTokenRedeemPure, accounts):
    ifCash = [get_fcash_token(0, maturity=(START_TIME_TREF + 3 * SECONDS_IN_QUARTER))]

    liquidityTokens = [get_liquidity_token(1), get_liquidity_token(2), get_liquidity_token(3)]

    finalAssets = nTokenRedeemPure.addResidualsToAssets(liquidityTokens, ifCash, [0, 100e8, 0])
    assert len(finalAssets) == 2
    assert ifCash[0] in finalAssets
    assert list(filter(lambda a: a[1] == liquidityTokens[1][1], finalAssets))[0][3] == 100e8


def test_reduce_ifcash_assets_proportional(nTokenRedeemPure, accounts):
    pass


# END PURE METHODS


def test_ntoken_market_value(nTokenRedeem, accounts):
    pass


def test_get_liquidity_token_withdraw_proportional(nTokenRedeem, accounts):
    pass


def test_get_liquidity_token_withdraw_with_residual(nTokenRedeem, accounts):
    pass


def test_redeem_no_residual_sell_assets(nTokenRedeem, accounts):
    pass


def test_redeem_no_residual_sell_assets_fail(nTokenRedeem, accounts):
    pass


def test_redeem_no_residual_keep_assets(nTokenRedeem, accounts):
    pass


def test_redeem_residual_sell_assets(nTokenRedeem, accounts):
    pass


def test_redeem_residual_sell_assets_fail(nTokenRedeem, accounts):
    pass


def test_redeem_residual_keep_assets(nTokenRedeem, accounts):
    pass

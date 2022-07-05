import math
import random

import pytest
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from tests.constants import (
    RATE_PRECISION,
    SECONDS_IN_DAY,
    SECONDS_IN_QUARTER,
    SECONDS_IN_YEAR,
    SETTLEMENT_DATE,
    START_TIME_TREF,
)
from tests.helpers import (
    get_bitmap_from_bitlist,
    get_cash_group_with_max_markets,
    get_fcash_token,
    get_liquidity_token,
    get_market_curve,
    random_asset_bitmap,
)

currencyId = 1
tokenAddress = None
marketStates = []


def setup_fixture(mock, aggregator):
    global marketStates
    # set cash group and asset rate mapping
    cashGroup = get_cash_group_with_max_markets(3)
    # Turn off fees
    cashGroup[2] = 0
    mock.setCashGroup(currencyId, cashGroup, (aggregator.address, 18))
    # set markets
    marketStates = get_market_curve(3, "flat", assetRate=50)
    for m in marketStates:
        mock.setMarketStorage(1, SETTLEMENT_DATE, m)
        # set matching fCash assets
        mock.setfCash(currencyId, tokenAddress, m[1], START_TIME_TREF, -m[2])  # maturity  # fCash

    # set nToken portfolio
    tokens = [get_liquidity_token(1), get_liquidity_token(2), get_liquidity_token(3)]

    mock.setNToken(
        1,
        tokenAddress,
        ([], tokens, 0, 0),
        1e18,
        1000e8,  # TODO: vary this cash balance a bit
        START_TIME_TREF,
    )

    return mock


@pytest.fixture(scope="module", autouse=True)
def nTokenRedeem1(MockNTokenRedeem1, MockCToken, cTokenV2Aggregator, accounts):
    global tokenAddress
    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenV2Aggregator.deploy(cToken.address, {"from": accounts[0]})
    cToken.setAnswer(200000000000000000000000000, {"from": accounts[0]})
    tokenAddress = accounts[9]

    mock = MockNTokenRedeem1.deploy({"from": accounts[0]})
    return setup_fixture(mock, aggregator)


@pytest.fixture(scope="module", autouse=True)
def nTokenRedeem2(MockNTokenRedeem2, MockCToken, cTokenV2Aggregator, accounts):
    global tokenAddress
    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenV2Aggregator.deploy(cToken.address, {"from": accounts[0]})
    cToken.setAnswer(200000000000000000000000000, {"from": accounts[0]})
    tokenAddress = accounts[9]

    mock = MockNTokenRedeem2.deploy({"from": accounts[0]})
    return setup_fixture(mock, aggregator)


@pytest.fixture(scope="module", autouse=True)
def nTokenRedeemPure(MockNTokenRedeemPure, accounts):
    return MockNTokenRedeemPure.deploy({"from": accounts[0]})


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@given(initalizedTimeOffset=strategy("uint32", min_value=0, max_value=89))
def test_get_ifCash_bits(nTokenRedeemPure, accounts, initalizedTimeOffset):
    (_, bitmapList) = random_asset_bitmap(15)
    lastInitializedTime = START_TIME_TREF + initalizedTimeOffset * SECONDS_IN_DAY
    for m in marketStates:
        (bitNum, exact) = nTokenRedeemPure.getBitNumFromMaturity(lastInitializedTime, m[1])
        assert exact
        bitmapList[bitNum - 1] = "1"

    bitmap = get_bitmap_from_bitlist(bitmapList)

    # add random ifcash assets at various maturities
    # test that the bits returned are always ifcash
    nTokenRedeemPure.setAssetsBitmap(tokenAddress, currencyId, bitmap)
    blockTime = START_TIME_TREF + random.randint(0, (SECONDS_IN_QUARTER - initalizedTimeOffset))

    # This should not revert
    nTokenRedeemPure.test_getNTokenifCashBits(
        tokenAddress, currencyId, lastInitializedTime, blockTime, 7
    )


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


@given(
    lt1=strategy("uint256", min_value=0.1e18, max_value=1e18),
    lt2=strategy("uint256", min_value=0.1e18, max_value=1e18),
    lt3=strategy("uint256", min_value=0.1e18, max_value=1e18),
)
def test_ntoken_market_value(nTokenRedeem1, accounts, lt1, lt2, lt3):
    ltNotional = [lt1, lt2, lt3]
    tokens = [
        get_liquidity_token(1, notional=ltNotional[0]),
        get_liquidity_token(2, notional=ltNotional[1]),
        get_liquidity_token(3, notional=ltNotional[2]),
    ]

    nTokenRedeem1.setNToken(
        1,
        tokenAddress,
        ([], tokens, 0, 0),
        1e18,
        1000e8,  # NOTE: cash balance irrelevant here
        START_TIME_TREF,
    )

    nToken = nTokenRedeem1.getNToken(1)
    (totalAssetValue, netfCash) = nTokenRedeem1.getNTokenMarketValue(nToken, START_TIME_TREF)

    netAssetValue = 0
    for (i, m) in enumerate(marketStates):
        # netfCash is claim - what is in portfolio (set to the market fCash here)
        fCash = Wei(Wei(m[2] * ltNotional[i]) / 1e18 - Wei(m[2]))
        assert pytest.approx(fCash, rel=1e-9) == netfCash[i]

        timeToMaturity = m[1] - START_TIME_TREF
        # Discount fCash to PV
        fCashPV = fCash / math.exp(m[6] * (timeToMaturity / SECONDS_IN_YEAR) / RATE_PRECISION)
        netAssetValue += Wei(m[3] * ltNotional[i]) / 1e18 + Wei(fCashPV * 50)

    assert pytest.approx(totalAssetValue, rel=1e-6) == netAssetValue


@given(tokensToRedeem=strategy("uint256", min_value=0.1e18, max_value=0.99e18))
def test_get_liquidity_token_withdraw_proportional(nTokenRedeem1, accounts, tokensToRedeem):
    nToken = nTokenRedeem1.getNToken(1)
    (tokensToWithdraw, netfCash) = nTokenRedeem1.getLiquidityTokenWithdraw(
        nToken, tokensToRedeem, START_TIME_TREF, 0
    )

    assert len(tokensToWithdraw) == len(netfCash)
    for i in range(0, len(tokensToWithdraw)):
        assert tokensToWithdraw[i] == tokensToRedeem
        # netfCash is always zero in this branch
        assert netfCash[i] == 0


@given(
    ifCashNotional=strategy("uint256", min_value=0.01e18, max_value=0.50e18),
    nTokensToRedeem=strategy("uint256", min_value=0.1e18, max_value=0.99e18),
)
def test_get_liquidity_token_withdraw_with_residual(
    nTokenRedeem1, ifCashNotional, nTokensToRedeem, accounts
):
    nineMonth = START_TIME_TREF + 3 * SECONDS_IN_QUARTER

    # Set ifCash asset
    nTokenRedeem1.setfCash(
        currencyId, tokenAddress, nineMonth, START_TIME_TREF, ifCashNotional  # maturity  # fCash
    )
    bitmapList = ["0"] * 256
    bitmapList[119] = "1"  # Set the nine month to 1
    bitmap = get_bitmap_from_bitlist(bitmapList)

    nTokenRedeem1.setfCash(
        currencyId,
        tokenAddress,
        marketStates[0][1],  # 3 mo maturity
        START_TIME_TREF,
        0.25e18,  # fCash
    )

    nToken = nTokenRedeem1.getNToken(1)
    if ifCashNotional > 0:
        oracleRate = (marketStates[1][6] + marketStates[2][6]) / 2 + (0.015e9)
    else:
        oracleRate = (marketStates[1][6] + marketStates[2][6]) / 2 - (0.015e9)

    ifCashAssetValue = (ifCashNotional / math.exp(oracleRate * 0.75 / RATE_PRECISION)) * 50

    (tokensToWithdraw, netfCash) = nTokenRedeem1.getLiquidityTokenWithdraw(
        nToken, nTokensToRedeem, START_TIME_TREF, bitmap
    )

    (totalAssetValueInMarkets, totalNetfCash) = nTokenRedeem1.getNTokenMarketValue(
        nToken, START_TIME_TREF
    )

    scalar = totalAssetValueInMarkets / (ifCashAssetValue + totalAssetValueInMarkets)

    for (i, t) in enumerate(tokensToWithdraw):
        # Test that fCash share is correct
        if netfCash[i] != 0:
            assert pytest.approx((netfCash[i] / totalNetfCash[i]) * 1e18, rel=1e-9) == t
        assert pytest.approx(t * scalar, rel=1e-9) == nTokensToRedeem


@given(
    tokensToRedeem=strategy("uint256", min_value=0.01e18, max_value=0.30e18),
    setResidual=strategy("bool"),
)
def test_redeem_sell_assets(nTokenRedeem2, tokensToRedeem, accounts, setResidual):
    ifCash = []
    for (i, m) in enumerate(marketStates):
        residual = m[2] * 0.1
        if i == 2:
            # Negative residual for the second market
            residual = -residual

        # Add some fCash residual for selling back to markets
        nTokenRedeem2.setfCash(currencyId, tokenAddress, m[1], START_TIME_TREF, residual)
        ifCash.append(-m[2] + residual)

    if setResidual:
        # Set a residual asset
        nineMonth = START_TIME_TREF + 3 * SECONDS_IN_QUARTER
        nTokenRedeem2.setfCash(currencyId, tokenAddress, nineMonth, START_TIME_TREF, 0.01e18)

    nToken = nTokenRedeem2.getNToken(currencyId)
    txn = nTokenRedeem2.redeem(currencyId, tokensToRedeem, True, False, START_TIME_TREF)
    (hasResidual, assets) = inspect_results(nTokenRedeem2, txn, ifCash, tokensToRedeem, nToken[3])

    assert not hasResidual
    assert assets == ()


@given(setResidual=strategy("bool"))
def test_redeem_sell_assets_fail(nTokenRedeem2, accounts, setResidual):
    tokensToRedeem = 0.5e18
    ifCash = []
    for (i, m) in enumerate(marketStates):
        residual = m[2] * 0.1
        if i == 2:
            # Put a large residual in the 1 year market to fail the selling
            residual = m[2] * 3

        # Add some fCash residual for selling back to markets
        nTokenRedeem2.setfCash(currencyId, tokenAddress, m[1], START_TIME_TREF, residual)
        ifCash.append(-m[2] + residual)

    if setResidual:
        # Set a residual asset
        nineMonth = START_TIME_TREF + 3 * SECONDS_IN_QUARTER
        nTokenRedeem2.setfCash(currencyId, tokenAddress, nineMonth, START_TIME_TREF, 0.01e18)

    nToken = nTokenRedeem2.getNToken(currencyId)

    # TODO: ganache fails here
    # with brownie.reverts():
    #     nTokenRedeem2.redeem(currencyId, tokensToRedeem, True, False, START_TIME_TREF)

    txn = nTokenRedeem2.redeem(currencyId, tokensToRedeem, True, True, START_TIME_TREF)
    (hasResidual, assets) = inspect_results(nTokenRedeem2, txn, ifCash, tokensToRedeem, nToken[3])

    # Assert that if selling the fCash fails, the redeem method will return the fcash asset to
    # either place into the portfolio or revert
    assert hasResidual
    if setResidual:
        assert len(assets) == 2
        assert assets[1][1] == marketStates[2][1]
    else:
        assert len(assets) == 1
        assert assets[0][1] == marketStates[2][1]


@given(setResidual=strategy("bool"))
def test_redeem_keep_assets(nTokenRedeem2, accounts, setResidual):
    tokensToRedeem = 0.5e18
    ifCash = []
    for (i, m) in enumerate(marketStates):
        residual = m[2] * 0.1
        # Add some fCash residual for selling back to markets
        nTokenRedeem2.setfCash(currencyId, tokenAddress, m[1], START_TIME_TREF, residual)
        ifCash.append(-m[2] + residual)

    if setResidual:
        # Set a residual asset
        nineMonth = START_TIME_TREF + 3 * SECONDS_IN_QUARTER
        nTokenRedeem2.setfCash(currencyId, tokenAddress, nineMonth, START_TIME_TREF, 0.01e18)

    nToken = nTokenRedeem2.getNToken(currencyId)
    txn = nTokenRedeem2.redeem(currencyId, tokensToRedeem, False, True, START_TIME_TREF)
    (hasResidual, assets) = inspect_results(nTokenRedeem2, txn, ifCash, tokensToRedeem, nToken[3])

    # In this case we are keeping all the residuals
    assert hasResidual
    if setResidual:
        assert len(assets) == 4
    else:
        assert len(assets) == 3


def inspect_results(nTokenRedeem2, txn, ifCash, tokensToRedeem, cashBalanceBefore):
    assetCash = txn.events["Redeem"]["assetCash"]
    hasResidual = txn.events["Redeem"]["hasResidual"]
    assets = txn.events["Redeem"]["assets"]

    # Cash balance share
    calculatedAssetCash = cashBalanceBefore * tokensToRedeem / 1e18
    for (i, m) in enumerate(marketStates):
        newMarketState = nTokenRedeem2.getMarket(
            currencyId, m[1], START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF
        )

        postRedeemfCash = nTokenRedeem2.getfCashNotional(tokenAddress, currencyId, m[1])

        netAssetCash = m[3] - newMarketState[3]
        netMarketfCash = newMarketState[2] - m[2]
        # netAssetCash will include any fCash sold to the market, must net off with what is coming
        # back to the account
        calculatedAssetCash += netAssetCash

        # Assert that all fCash taken from the nToken has been sold into the market. fCash must
        # net off between the market, account and nToken account
        matchingfCash = list(filter(lambda a: a[1] == m[1], assets))
        netfCash = ifCash[i] - postRedeemfCash
        if matchingfCash:
            netfCash -= matchingfCash[0][3]
        assert pytest.approx(netMarketfCash, abs=100) == netfCash

    assert pytest.approx(calculatedAssetCash, rel=1e-15) == assetCash

    return (hasResidual, assets)

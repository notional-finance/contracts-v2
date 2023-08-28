import math
import random

import brownie
import pytest
from brownie.convert.datatypes import HexString, Wei
from brownie.network import Chain
from brownie.network.contract import Contract
from brownie.test import given, strategy
from tests.constants import (
    MARKETS,
    RATE_PRECISION,
    SECONDS_IN_DAY,
    SECONDS_IN_QUARTER,
    SECONDS_IN_YEAR,
    SETTLEMENT_DATE,
    START_TIME_TREF,
)
from tests.helpers import (
    get_bitmap_from_bitlist,
    get_fcash_token,
    get_interest_rate_curve,
    get_liquidity_token,
    random_asset_bitmap,
    setup_internal_mock,
)

chain = Chain()
currencyId = 1
tokenAddress = None
marketStates = None
nineMonth = START_TIME_TREF + 3 * SECONDS_IN_QUARTER


@pytest.fixture(scope="module", autouse=True)
def nTokenRedeem(MockNTokenRedeem, MockSettingsLib, accounts):
    global tokenAddress
    global marketStates
    settings = MockSettingsLib.deploy({"from": accounts[0]})
    mock = MockNTokenRedeem.deploy(settings, {"from": accounts[0]})
    mock = Contract.from_abi(
        "mock", mock.address, MockSettingsLib.abi + mock.abi, owner=accounts[0]
    )
    tokenAddress = accounts[10]
    setup_internal_mock(mock)

    # Turn off fees
    mock.setInterestRateParameters(
        currencyId, 1, get_interest_rate_curve(minFeeRateBPS=0, maxFeeRateBPS=1, feeRatePercent=0)
    )
    mock.setInterestRateParameters(
        currencyId, 2, get_interest_rate_curve(minFeeRateBPS=0, maxFeeRateBPS=1, feeRatePercent=0)
    )
    mock.setInterestRateParameters(
        currencyId, 3, get_interest_rate_curve(minFeeRateBPS=0, maxFeeRateBPS=1, feeRatePercent=0)
    )

    marketStates = [
        mock.getMarket(1, MARKETS[0], SETTLEMENT_DATE),
        mock.getMarket(1, MARKETS[1], SETTLEMENT_DATE),
        mock.getMarket(1, MARKETS[2], SETTLEMENT_DATE),
    ]

    # Set this so that bitmap assets can be set
    mock.setAccountContext(
        tokenAddress, (START_TIME_TREF, "0x00", 0, currencyId, HexString(0, "bytes18"), False)
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


@given(hasifCash=strategy("bool"))
def test_add_residuals_to_assets(nTokenRedeemPure, accounts, hasifCash):
    if hasifCash:
        # 9 month fCash
        ifCash = [
            get_fcash_token(0, maturity=(START_TIME_TREF + 3 * SECONDS_IN_QUARTER), notional=200e8)
        ]
    else:
        ifCash = []

    liquidityTokens = [get_liquidity_token(1), get_liquidity_token(2), get_liquidity_token(3)]

    # Has no net fCash
    finalAssets = nTokenRedeemPure.addResidualsToAssets(liquidityTokens, ifCash, [0, 0, 0])
    assert len(finalAssets) == (1 if hasifCash else 0)
    if hasifCash:
        assert ifCash[0] in finalAssets

    # Has single net fCash
    finalAssets = nTokenRedeemPure.addResidualsToAssets(liquidityTokens, ifCash, [0, 100e8, 0])
    assert len(finalAssets) == (2 if hasifCash else 1)
    if hasifCash:
        assert ifCash[0] in finalAssets

    # Has two net fCash
    finalAssets = nTokenRedeemPure.addResidualsToAssets(liquidityTokens, ifCash, [-100e8, 100e8, 0])
    assert len(finalAssets) == (3 if hasifCash else 2)
    if hasifCash:
        assert ifCash[0] in finalAssets

    # Has three net fCash
    finalAssets = nTokenRedeemPure.addResidualsToAssets(
        liquidityTokens, ifCash, [-100e8, 100e8, 150e8]
    )
    assert len(finalAssets) == (4 if hasifCash else 3)
    if hasifCash:
        assert ifCash[0] in finalAssets


# END PURE METHODS


def test_reduce_ifcash_assets_proportional(nTokenRedeem, accounts):
    totalDebtBefore = [
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[0]),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[1]),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, nineMonth),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[2]),
    ]

    # reduce proportional to total supply
    txn = nTokenRedeem.reduceifCashAssetsProportional(
        tokenAddress, currencyId, START_TIME_TREF, 50_000e8, 100_000e8
    )
    assets = txn.return_value
    # check that total debt outstanding is reduced
    totalDebtInterim = [
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[0]),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[1]),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, nineMonth),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[2]),
    ]

    # write into a clean account, check that total debt outstanding increases again
    state = list(nTokenRedeem.buildPortfolioState(accounts[1]))
    state[1] = assets
    nTokenRedeem.setPortfolio(accounts[1], state)
    totalDebtAfter = [
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[0]),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[1]),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, nineMonth),
        nTokenRedeem.getTotalfCashDebtOutstanding(currencyId, MARKETS[2]),
    ]

    # check total debt outstanding after
    assert totalDebtBefore == totalDebtAfter
    assert totalDebtInterim == [-50_000e8, -50_000e8, 0, -50_000e8]


@given(
    lt1=strategy("uint256", min_value=1000e8, max_value=100_000e8),
    lt2=strategy("uint256", min_value=1000e8, max_value=100_000e8),
    lt3=strategy("uint256", min_value=1000e8, max_value=100_000e8),
)
def test_ntoken_market_value(nTokenRedeem, accounts, lt1, lt2, lt3):
    ltNotional = [lt1, lt2, lt3]
    tokens = [
        get_liquidity_token(1, notional=ltNotional[0]),
        get_liquidity_token(2, notional=ltNotional[1]),
        get_liquidity_token(3, notional=ltNotional[2]),
    ]

    nTokenRedeem.setNToken(
        1,
        tokenAddress,
        tokens,
        [],
        100_000e8,
        0,  # cash balance irrelevant
        START_TIME_TREF,
        85,
        90,  # valuation irrelevant
    )

    nToken = nTokenRedeem.getNToken(1)
    (totalAssetValue, netfCash) = nTokenRedeem.getNTokenMarketValue(nToken, START_TIME_TREF)
    (pr, _) = nTokenRedeem.buildPrimeRateView(1, chain.time())

    netAssetValue = 0
    for (i, m) in enumerate(marketStates):
        # netfCash is claim - what is in portfolio (set to the market fCash here)
        fCash = Wei(
            Wei(m["totalfCash"] * ltNotional[i]) / m["totalLiquidity"] - Wei(m["totalfCash"])
        )
        assert pytest.approx(fCash, rel=1e-9) == netfCash[i]

        timeToMaturity = m["maturity"] - START_TIME_TREF
        # Discount fCash to PV
        fCashPV = fCash / math.exp(
            m["oracleRate"] * (timeToMaturity / SECONDS_IN_YEAR) / RATE_PRECISION
        )
        netAssetValue += Wei(m["totalPrimeCash"] * ltNotional[i]) / m["totalLiquidity"]
        # Convert fCash to prime cash
        netAssetValue += nTokenRedeem.convertFromUnderlying(pr, fCashPV)

    assert pytest.approx(totalAssetValue, rel=1e-6) == netAssetValue


@given(tokensToRedeem=strategy("uint256", min_value=1_000e8, max_value=99_000e8))
def test_get_liquidity_token_withdraw_proportional(nTokenRedeem, accounts, tokensToRedeem):
    nToken = nTokenRedeem.getNToken(1)
    (tokensToWithdraw, netfCash) = nTokenRedeem.getLiquidityTokenWithdraw(
        nToken, tokensToRedeem, START_TIME_TREF, 0
    )

    assert len(tokensToWithdraw) == len(netfCash)
    for i in range(0, len(tokensToWithdraw)):
        assert tokensToWithdraw[i] == tokensToRedeem
        # netfCash is always zero in this branch
        assert netfCash[i] == 0


@given(
    ifCashNotional=strategy("int256", min_value=-50_000e8, max_value=50_000e8),
    nTokensToRedeem=strategy("uint256", min_value=1_000e8, max_value=99_000e8),
)
def test_get_liquidity_token_withdraw_with_residual(
    nTokenRedeem, ifCashNotional, nTokensToRedeem, accounts
):
    # Set ifCash asset
    nTokenRedeem.setBitmapAssets(
        tokenAddress, [get_fcash_token(currencyId, maturity=nineMonth, notional=ifCashNotional)]
    )
    bitmapList = ["0"] * 256
    bitmapList[119] = "1"  # Set the nine month to 1
    bitmap = get_bitmap_from_bitlist(bitmapList)

    nToken = nTokenRedeem.getNToken(1)
    if ifCashNotional > 0:
        # 0.015e9 is the penalty rate
        oracleRate = (marketStates[1]["oracleRate"] + marketStates[2]["oracleRate"]) / 2 + (0.015e9)
    else:
        oracleRate = (marketStates[1]["oracleRate"] + marketStates[2]["oracleRate"]) / 2 - (0.015e9)

    (pr, _) = nTokenRedeem.buildPrimeRateView(1, chain.time())
    (tokensToWithdraw, netfCash) = nTokenRedeem.getLiquidityTokenWithdraw(
        nToken, nTokensToRedeem, START_TIME_TREF, bitmap
    )

    (totalPrimeValueInMarkets, totalNetfCash) = nTokenRedeem.getNTokenMarketValue(
        nToken, START_TIME_TREF
    )

    ifCashPV = ifCashNotional / math.exp(oracleRate * 0.75 / RATE_PRECISION)
    ifCashPrimeValue = nTokenRedeem.convertFromUnderlying(pr, ifCashPV)
    scalar = totalPrimeValueInMarkets / (ifCashPrimeValue + totalPrimeValueInMarkets)

    for (i, t) in enumerate(tokensToWithdraw):
        # Test that fCash share is correct
        if netfCash[i] != 0:
            assert pytest.approx((netfCash[i] / totalNetfCash[i]) * 1e18, rel=1e-9) == t
        assert pytest.approx(t * scalar, rel=1e-9) == nTokensToRedeem

@pytest.mark.only
@given(
    tokensToRedeem=strategy("uint256", min_value=1000e8, max_value=90_000e8),
    setResidual=strategy("bool"),
)
def test_redeem_sell_assets(nTokenRedeem, tokensToRedeem, setResidual):
    netfCashAssets = [
        get_fcash_token(1, currencyId=currencyId, notional=10_000e8),
        get_fcash_token(2, currencyId=currencyId, notional=-10_000e8),
        get_fcash_token(3, currencyId=currencyId, notional=10_000e8),
    ]
    ifCash = []

    if setResidual:
        # Set a residual asset
        ifCash.append(
            get_fcash_token(0, maturity=nineMonth, currencyId=currencyId, notional=10_000e8)
        )

    nTokenRedeem.setBitmapAssets(tokenAddress, netfCashAssets + ifCash)
    nToken = nTokenRedeem.getNToken(currencyId)
    chain.mine(1, timestamp=START_TIME_TREF + 30)
    txn = nTokenRedeem.redeem(currencyId, tokensToRedeem, True, False)
    (hasResidual, assets) = inspect_results(
        nTokenRedeem, txn, netfCashAssets, tokensToRedeem, nToken[3]
    )

    assert not hasResidual
    assert assets == ()


@pytest.mark.only
@given(setResidual=strategy("bool"))
def test_redeem_sell_assets_fail(nTokenRedeem, setResidual):
    tokensToRedeem = 99_000e8
    netfCashAssets = [
        get_fcash_token(1, currencyId=currencyId, notional=0),
        get_fcash_token(2, currencyId=currencyId, notional=-10_000e8),
        get_fcash_token(3, currencyId=currencyId, notional=0),
    ]
    ifCash = []

    if setResidual:
        # Set a residual asset
        ifCash.append(
            get_fcash_token(0, maturity=nineMonth, currencyId=currencyId, notional=1_000e8)
        )

    nTokenRedeem.setBitmapAssets(tokenAddress, netfCashAssets + ifCash)
    nToken = nTokenRedeem.getNToken(currencyId)
    chain.mine(1, timestamp=START_TIME_TREF + 30)
    with brownie.reverts("Residuals"):
        # Transaction reverts because there is a residual
        nTokenRedeem.redeem.call(currencyId, tokensToRedeem, True, False)

    txn = nTokenRedeem.redeem(currencyId, tokensToRedeem, True, True)
    (hasResidual, assets) = inspect_results(
        nTokenRedeem, txn, netfCashAssets, tokensToRedeem, nToken[3]
    )

    # Assert that if selling the fCash fails, the redeem method will return the fcash asset to
    # either place into the portfolio or revert
    assert hasResidual
    if setResidual:
        assert len(assets) == 2
        assert assets[0][1] == nineMonth
        assert assets[1][1] == marketStates[1][1]
    else:
        assert len(assets) == 1
        assert assets[0][1] == marketStates[1][1]

@pytest.mark.only
@given(setResidual=strategy("bool"))
def test_redeem_keep_assets(nTokenRedeem, accounts, setResidual):
    tokensToRedeem = 50_000e8
    netfCashAssets = [
        get_fcash_token(1, currencyId=currencyId, notional=10_000e8),
        get_fcash_token(2, currencyId=currencyId, notional=-10_000e8),
        get_fcash_token(3, currencyId=currencyId, notional=10_000e8),
    ]
    ifCash = []

    if setResidual:
        # Set a residual asset
        ifCash.append(
            get_fcash_token(0, maturity=nineMonth, currencyId=currencyId, notional=10_000e8)
        )

    nTokenRedeem.setBitmapAssets(tokenAddress, netfCashAssets + ifCash)
    nToken = nTokenRedeem.getNToken(currencyId)
    chain.mine(1, timestamp=START_TIME_TREF)
    txn = nTokenRedeem.redeem(currencyId, tokensToRedeem, False, True)
    (hasResidual, assets) = inspect_results(
        nTokenRedeem, txn, netfCashAssets, tokensToRedeem, nToken[3]
    )

    # In this case we are keeping all the residuals
    assert hasResidual
    if setResidual:
        assert len(assets) == 4
    else:
        assert len(assets) == 3


def inspect_results(nTokenRedeem, txn, ifCash, tokensToRedeem, cashBalanceBefore):
    assetCash = txn.events["Redeem"]["primeCash"]
    hasResidual = txn.events["Redeem"]["hasResidual"]
    assets = txn.events["Redeem"]["assets"]

    # Cash balance share
    calculatedAssetCash = cashBalanceBefore * tokensToRedeem / 100_000e8
    portfolio = nTokenRedeem.getBitmapAssets(tokenAddress)

    for (i, m) in enumerate(marketStates):
        newMarketState = nTokenRedeem.getMarket(currencyId, m["maturity"], SETTLEMENT_DATE)
        postRedeemfCash = list(filter(lambda a: a[1] == m["maturity"], portfolio))[0]

        netAssetCash = m["totalPrimeCash"] - newMarketState["totalPrimeCash"]
        netMarketfCash = newMarketState["totalfCash"] - m["totalfCash"]
        # netAssetCash will include any fCash sold to the market, must net off with what is coming
        # back to the account
        calculatedAssetCash += netAssetCash

        # Assert that all fCash taken from the nToken has been sold into the market. fCash must
        # net off between the market, account and nToken account
        matchingfCash = list(filter(lambda a: a[1] == m[1], assets))
        # 100_000e8 is the starting balance of the fCash
        netfCash = ifCash[i][3] - (postRedeemfCash[3] + 100_000e8)
        if matchingfCash:
            netfCash -= matchingfCash[0][3]
        assert pytest.approx(netMarketfCash, abs=100) == netfCash

    assert pytest.approx(calculatedAssetCash, rel=1e-15) == assetCash

    return (hasResidual, assets)

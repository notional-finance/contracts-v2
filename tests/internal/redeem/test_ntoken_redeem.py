import pytest
from tests.constants import SECONDS_IN_QUARTER, SETTLEMENT_DATE
from tests.helpers import get_cash_group_with_max_markets, get_liquidity_token, get_market_curve

currencyId = 1
tokenAddress = None
lastInitializedTime = None


@pytest.fixture(scope="module", autouse=True)
def nTokenRedeem(MockNTokenRedeem, MockCToken, cTokenAggregator, accounts):
    global tokenAddress
    global lastInitializedTime
    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})
    cToken.setAnswer(200000000000000000000000000, {"from": accounts[0]})
    tokenAddress = accounts[9]

    mock = MockNTokenRedeem.deploy({"from": accounts[0]})
    # set cash group and asset rate mapping
    cashGroup = get_cash_group_with_max_markets(3)
    mock.setCashGroup(currencyId, cashGroup, (aggregator.address, 18))
    # set markets
    lastInitializedTime = SETTLEMENT_DATE - SECONDS_IN_QUARTER  # TODO: vary this a bit?
    marketStates = get_market_curve(3, "flat")
    for m in marketStates:
        mock.setMarketStorage(1, SETTLEMENT_DATE, m)
        # set matching fCash assets
        mock.setfCash(
            currencyId,
            tokenAddress,
            m[1],  # maturity
            lastInitializedTime,
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
        lastInitializedTime,
    )

    return mock


@pytest.fixture(scope="module", autouse=True)
def nTokenRedeemPure(MockNTokenRedeemPure, accounts):
    return MockNTokenRedeemPure.deploy({"from": accounts[0]})


@pytest.mark.only
def test_get_ifCash_bits(nTokenRedeemPure, accounts):
    # add random ifcash assets at various maturities
    # test that the bits returned are always ifcash
    nToken = nTokenRedeemPure.getNToken(currencyId)
    print(nToken)


def test_add_residuals_to_assets(nTokenRedeemPure, accounts):
    pass


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

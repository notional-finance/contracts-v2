import pytest
from brownie.network.state import Chain
from tests.constants import SETTLEMENT_DATE, START_TIME
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_eth_rate_mapping,
    get_fcash_token,
    get_market_curve,
)

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def ethAggregators(MockAggregator, accounts):
    return [
        MockAggregator.deploy(18, {"from": accounts[0]}),
        MockAggregator.deploy(18, {"from": accounts[0]}),
        MockAggregator.deploy(18, {"from": accounts[0]}),
    ]


@pytest.fixture(scope="module", autouse=True)
def freeCollateral(
    MockFreeCollateral,
    MockCToken,
    cTokenAggregator,
    FreeCollateralExternal,
    ethAggregators,
    accounts,
):
    FreeCollateralExternal.deploy({"from": accounts[0]})
    fc = accounts[0].deploy(MockFreeCollateral)
    ctoken = accounts[0].deploy(MockCToken, 8)
    # This is the identity rate
    ctoken.setAnswer(1e18)
    aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})

    rateStorage = (aggregator.address, 8)
    fc.setAssetRateMapping(1, rateStorage)
    cg = get_cash_group_with_max_markets(3)
    fc.setCashGroup(1, cg)
    ethAggregators[0].setAnswer(1e18)
    fc.setETHRateMapping(1, get_eth_rate_mapping(ethAggregators[0]))

    fc.setAssetRateMapping(2, rateStorage)
    fc.setCashGroup(2, cg)
    ethAggregators[1].setAnswer(1e18)
    fc.setETHRateMapping(2, get_eth_rate_mapping(ethAggregators[1], haircut=80))

    fc.setAssetRateMapping(3, rateStorage)
    fc.setCashGroup(3, cg)
    ethAggregators[2].setAnswer(1e18)
    fc.setETHRateMapping(3, get_eth_rate_mapping(ethAggregators[2], haircut=0))

    chain.mine(1, timestamp=START_TIME)

    return fc


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_cash_balance_no_haircut(freeCollateral, accounts):
    freeCollateral.setBalance(accounts[0], 1, 100e8, 0)
    fc = freeCollateral.getFreeCollateralView(accounts[0])
    assert fc == 100e8


def test_cash_balance_haircut(freeCollateral, accounts):
    freeCollateral.setBalance(accounts[0], 2, 100e8, 0)
    fc = freeCollateral.getFreeCollateralView(accounts[0])
    assert fc == 80e8


def test_cash_balance_full_haircut(freeCollateral, accounts):
    freeCollateral.setBalance(accounts[0], 3, 100e8, 0)
    fc = freeCollateral.getFreeCollateralView(accounts[0])
    assert fc == 0


def test_cash_balance_debt(freeCollateral, accounts):
    freeCollateral.setBalance(accounts[0], 1, -100e8, 0)
    fc = freeCollateral.getFreeCollateralView(accounts[0])
    assert fc == -140e8


def test_portfolio_fCash_no_haircut(freeCollateral, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        freeCollateral.setMarketStorage(1, SETTLEMENT_DATE, m)

    freeCollateral.setPortfolio(accounts[0], [get_fcash_token(1, notional=100e8)])
    fc = freeCollateral.getFreeCollateralView(accounts[0])
    assert fc > 0 and fc < 100e8


def test_portfolio_fCash_haircut(freeCollateral, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        freeCollateral.setMarketStorage(2, SETTLEMENT_DATE, m)

    freeCollateral.setPortfolio(accounts[0], [get_fcash_token(1, currencyId=2, notional=100e8)])
    fc = freeCollateral.getFreeCollateralView(accounts[0])
    assert fc > 0 and fc < 80e8


def test_portfolio_fCash_full_haircut(freeCollateral, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        freeCollateral.setMarketStorage(3, SETTLEMENT_DATE, m)

    freeCollateral.setPortfolio(accounts[0], [get_fcash_token(1, currencyId=3, notional=100e8)])
    fc = freeCollateral.getFreeCollateralView(accounts[0])
    assert fc == 0


def test_portfolio_debt(freeCollateral, accounts):
    markets = get_market_curve(3, "flat")
    for m in markets:
        freeCollateral.setMarketStorage(3, SETTLEMENT_DATE, m)

    freeCollateral.setPortfolio(accounts[0], [get_fcash_token(1, currencyId=3, notional=-100e8)])
    fc = freeCollateral.getFreeCollateralView(accounts[0])
    assert fc < 0 and fc > -140e8


# def test_free_collateral_perp_token_value(freeCollateral, accounts):
# def test_free_collateral_combined(freeCollateral):
# def test_free_collateral_multiple_cash_groups()

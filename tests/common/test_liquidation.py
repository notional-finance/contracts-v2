import brownie
import pytest
from tests.common.params import (
    CASH_GROUP_PARAMETERS,
    IDENTITY_ASSET_RATE,
    MARKETS,
    SETTLEMENT_DATE,
    START_TIME,
    get_cash_group_hex,
)

NUM_CURRENCIES = 8
LIQUIDATION_BUFFER = 1.01e18


@pytest.fixture(scope="module", autouse=True)
def liquidation(MockLiquidation, accounts):
    return accounts[0].deploy(MockLiquidation)


@pytest.fixture(scope="module", autouse=True)
def ethAggregators(MockAggregator, liquidation, accounts):
    aggregators = []
    for i in range(0, NUM_CURRENCIES):
        mock = MockAggregator.deploy(18, {"from": accounts[0]})
        # mock.setAnswer(0.01e18 * (i + 1))
        mock.setAnswer(1e18)
        buffer = 100 + (i + 1) * 10
        haircut = 100 - (i + 1) * 10
        liquidation.setETHRateMapping(i + 1, (mock.address, 18, False, buffer, haircut, 105, 18))
        aggregators.append(mock)

    return aggregators


@pytest.fixture(scope="module", autouse=True)
def assetRateAggregator(MockCToken, cTokenAggregator, liquidation, accounts):
    mockToken = MockCToken.deploy(8, {"from": accounts[0]})
    mock = cTokenAggregator.deploy(mockToken.address, {"from": accounts[0]})
    mockToken.setAnswer(1e18)
    for i in range(0, NUM_CURRENCIES):
        liquidation.setAssetRateMapping(i + 1, (mock.address, 18))

    return mock


def setup_markets(liquidation):
    for i in range(0, NUM_CURRENCIES):
        for m in MARKETS:
            liquidation.setMarketState((i + 1, m, 1e18, 1e18, 1e18, 0, 0, 0, True), SETTLEMENT_DATE)


def get_buffer(currencyId, value):
    return value * (100 + currencyId * 10) / 100


def get_haircut(currencyId, value):
    return value * (100 - currencyId * 10) / 100


def get_cash_group(currencyId, maxMarkets, liquidityTokenHaircut=97):
    params = list(CASH_GROUP_PARAMETERS)
    params[0] = maxMarkets
    params[3] = liquidityTokenHaircut
    cgHex = get_cash_group_hex(params)

    cg = (currencyId, maxMarkets, IDENTITY_ASSET_RATE, cgHex)

    return (cg, [(0, 0, 0, 0, 0, 0, 0, 0, False) * maxMarkets])


def get_cash_groups_and_market_states(configs):
    cashGroups = []
    marketStates = []

    for c in configs:
        (cg, ms) = get_cash_group(c[0], c[1], c[2])
        cashGroups.append(cg)
        marketStates.append(ms)

    return (cashGroups, marketStates)


# TESTS START HERE #


def test_sufficient_collateral(liquidation, accounts):
    config = ((1, 1, 97), (2, 1, 97))
    (cashGroups, marketStates) = get_cash_groups_and_market_states(config)

    # TODO: fuzz this a bit but ensure that FC >= 0
    balanceStates = ((1, 0, 0, 0, 0, 0), (2, 0, 0, 0, 0, 0))
    netPortfolioValue = [1e18, 0]

    with brownie.reverts("L: sufficient free collateral"):
        liquidation.getLiquidationFactors(
            1, 2, balanceStates, tuple(cashGroups), tuple(marketStates), tuple(netPortfolioValue)
        )


def test_get_liquidation_factors(liquidation, accounts):
    config = ((1, 1, 97), (2, 1, 97))
    (cashGroups, marketStates) = get_cash_groups_and_market_states(config)

    # TODO: fuzz this some more, ensure fc < 0
    balanceStates = ((1, 0, 0, 0, 0, 0), (2, 0.7e18, 0, 0, 0, 0))

    netPortfolioValue = [-1e18, 0]

    factors = liquidation.getLiquidationFactors(
        1, 2, balanceStates, tuple(cashGroups), tuple(marketStates), tuple(netPortfolioValue)
    )

    # local asset required
    assert pytest.approx(factors[0], rel=1e-12) == -(
        (get_buffer(1, -1e18) + get_haircut(2, 0.7e18)) * LIQUIDATION_BUFFER / 1e18
    )
    # local available
    assert factors[1] == -1e18
    # collateral available
    assert factors[2] == 0.7e18
    # perpetual token value
    assert factors[3] == 0
    # liquidation discount
    assert factors[4] == 105
    # has collateral
    assert factors[11]


def test_liquidate_tokens(liquidation, ethAggregators, assetRateAggregator, accounts):
    setup_markets(liquidation)
    config = ((1, 1, 90), (2, 1, 90))
    (cashGroups, marketStates) = get_cash_groups_and_market_states(config)

    # This should be a function #
    balanceStates = ((1, 0, 0, 0, 0, 0), (2, 0.7e18, 0, 0, 0, 0))
    netPortfolioValue = [-1e18, 0]
    factors = liquidation.getLiquidationFactors(
        1, 2, balanceStates, tuple(cashGroups), tuple(marketStates), tuple(netPortfolioValue)
    )
    # This should be a function #

    portfolioState = (
        [
            # TODO: generate random token stuff
            (1, MARKETS[0], 2, 0.1e18, 0)
        ],
        (),
        0,
        1,
        (),
    )

    # assetCash     = 100000000000000000
    # fCash         = 100000000000000000
    # totalCashOut  = 909090909090909
    # cashToAccount = 818181818181818

    (
        incentivePaid,
        localAssetRequired,
        newBalanceContext,
        newPortfolioState,
        newMarketStates,
    ) = liquidation.liquidateLocalLiquidityTokens(
        factors, START_TIME, balanceStates[0], portfolioState
    )

    # assert that the balance transfers net out to what was required when entering the function
    totalCashClaim = newBalanceContext[3] + incentivePaid

    # TODO: assert that market has updated properly
    # fCash amounts net off
    assert newMarketStates[0][2] + newPortfolioState[1][0][3] == 1e18
    # asset amounts net off
    assert newMarketStates[0][3] + totalCashClaim == 1e18
    # total liquidity amounts net off
    assert newMarketStates[0][3] + portfolioState[0][0][3] == 1e18

    # haircut amount - incentive = localAssetRequired change
    assert factors[0] >= localAssetRequired
    assert factors[0] - localAssetRequired == (
        (newBalanceContext[3] + incentivePaid) * (100 - 90) / 100 - incentivePaid
    )


@pytest.mark.only
def test_liquidate_collateral(liquidation, ethAggregators, assetRateAggregator, accounts):
    setup_markets(liquidation)
    config = ((1, 1, 97), (2, 1, 97))
    (cashGroups, marketStates) = get_cash_groups_and_market_states(config)

    balanceStates = ((1, 0, 0, 0, 0, 0), (2, 0.7e18, 0, 0, 0, 0))
    portfolioState = ([(2, MARKETS[0], 2, 0.1e18, 0)], (), 0, 1, ())
    netPortfolioValue = [-1e18, 0]

    factors = liquidation.getLiquidationFactors(
        1, 2, balanceStates, tuple(cashGroups), tuple(marketStates), tuple(netPortfolioValue)
    )

    (localToPurchase, newCollateralBalance, newPortfolioState) = liquidation.liquidateCollateral(
        factors, balanceStates[1], portfolioState, 0, START_TIME
    )

    assert False

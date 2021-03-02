import brownie
import pytest
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment

chain = Chain()
QUARTER = 86400 * 90
YEAR = QUARTER * 4
RATE_PRECISION = 1e9
INITIAL_CASH_AMOUNT = 100000e8


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    env = TestEnvironment(accounts[0])
    env.enableCurrency("DAI", CurrencyDefaults)

    cToken = env.cToken["DAI"]
    token = env.token["DAI"]
    token.approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(10000000e18, {"from": accounts[0]})
    cToken.approve(env.proxy.address, 2 ** 255, {"from": accounts[0]})

    return env


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def initialize_markets(environment, accounts):
    currencyId = 2
    environment.router["Governance"].updatePerpetualDepositParameters(
        currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9]
    )

    environment.router["Governance"].updateInitializationParameters(
        currencyId, [1.05e9, 1.05e9], [0.5e9, 0.5e9]
    )

    environment.router["MintPerpetual"].perpetualTokenMint(
        currencyId, 100000e8, False, {"from": accounts[0]}
    )
    environment.router["InitializeMarkets"].initializeMarkets(currencyId, True)


def get_maturities(index):
    blockTime = chain.time()
    tRef = blockTime - blockTime % QUARTER
    maturity = []
    if index >= 1:
        maturity.append(tRef + QUARTER)

    if index >= 2:
        maturity.append(tRef + 2 * QUARTER)

    if index >= 3:
        maturity.append(tRef + YEAR)

    if index >= 4:
        maturity.append(tRef + 2 * YEAR)

    if index >= 5:
        maturity.append(tRef + 5 * YEAR)

    if index >= 6:
        maturity.append(tRef + 7 * YEAR)

    if index >= 7:
        maturity.append(tRef + 10 * YEAR)

    if index >= 8:
        maturity.append(tRef + 15 * YEAR)

    if index >= 9:
        maturity.append(tRef + 20 * YEAR)

    return maturity


def perp_token_asserts(environment, currencyId, isFirstInit):
    blockTime = chain.time()
    perpTokenAddress = environment.router["Views"].getPerpetualTokenAddress(currencyId)
    (cashBalance, perpTokenBalance) = environment.router["Views"].getAccountBalance(
        currencyId, perpTokenAddress
    )

    (cashGroup, assetRate) = environment.router["Views"].getCashGroupAndRate(currencyId)
    portfolio = environment.router["Views"].getAccountPortfolio(perpTokenAddress)
    (depositShares, leverageThresholds) = environment.router["Views"].getPerpetualDepositParameters(
        currencyId
    )
    (rateAnchors, proportions) = environment.router["Views"].getInitializationParameters(currencyId)
    maturity = get_maturities(cashGroup[0])
    markets = environment.router["Views"].getActiveMarkets(currencyId)
    previousMarkets = environment.router["Views"].getActiveMarketsAtBlockTime(
        currencyId, blockTime - QUARTER
    )

    # assert perp token has no cash left
    assert cashBalance == 0
    assert perpTokenBalance == 0

    # assert that perp token has liquidity tokens
    assert len(portfolio) == cashGroup[0]  # max market index

    # These values are used to calculate non first init liquidity values
    totalAssetCashInMarketsExcl3Month = sum([m[3] for m in markets[1:]])
    depositSharesBasis = sum(depositShares[1:])

    for (i, asset) in enumerate(portfolio):
        assert asset[0] == currencyId
        # assert liquidity token is on a valid maturity date
        assert asset[1] == maturity[i]
        # assert liquidity tokens are ordered
        assert asset[2] == 2 + i
        # assert that liquidity is proportional to deposit shares
        if isFirstInit:
            # Initialize amount is a percentage of the initial cash amount
            assert asset[3] == INITIAL_CASH_AMOUNT * depositShares[i] / int(1e8)
        else:
            # Initialize amount is a percentage of the net cash amount excl the 3 month
            assert (
                asset[3]
                == totalAssetCashInMarketsExcl3Month * depositShares[i] / depositSharesBasis
            )

    ifCashAssets = environment.router["Views"].getifCashAssets(perpTokenAddress)
    for (i, asset) in enumerate(ifCashAssets):
        assert asset[0] == currencyId
        assert asset[1] == maturity[i]
        assert asset[2] == 1
        # assert that perp token has an fCash asset
        # TODO: this should be a combination of previous fCash value, and the net added
        # TODO: it's possible for this to be zero
        assert asset[3] < 0

    for (i, market) in enumerate(markets):
        assert market[0] == currencyId
        assert market[1] == maturity[i]
        # all market liquidity is from the perp token
        assert market[4] == portfolio[i][3]

        totalCashUnderlying = market[3] * assetRate[1] / 1e18
        proportion = market[2] * RATE_PRECISION / (totalCashUnderlying + market[2])
        proportion = proportion / (RATE_PRECISION - proportion)
        # assert that market proportions are not above leverage thresholds
        assert proportion < leverageThresholds[i]

        if previousMarkets[i][7] == 0:
            # This means that the market is initialized for the first time
            assert proportion == proportions[i]
        else:
            # assert that oracle values are in line
            assert market[6] == 0

    # TODO: assert account context


def test_first_initialization(environment, accounts):
    currencyId = 2
    with brownie.reverts("IM: insufficient cash"):
        # no parameters are set
        environment.router["InitializeMarkets"].initializeMarkets(currencyId, True)

    environment.router["Governance"].updatePerpetualDepositParameters(
        currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9]
    )

    environment.router["Governance"].updateInitializationParameters(
        currencyId, [1.05e9, 1.05e9], [0.5e9, 0.5e9]
    )

    with brownie.reverts("IM: insufficient cash"):
        # no cash deposits
        environment.router["InitializeMarkets"].initializeMarkets(currencyId, True)

    environment.router["MintPerpetual"].perpetualTokenMint(
        currencyId, 100000e8, False, {"from": accounts[0]}
    )
    environment.router["InitializeMarkets"].initializeMarkets(currencyId, True)
    perp_token_asserts(environment, currencyId, True)


def test_settle_and_initialize(environment, accounts):
    initialize_markets(environment, accounts)
    currencyId = 2
    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + QUARTER))

    # No trading has occured
    environment.router["InitializeMarkets"].initializeMarkets(currencyId, False)
    perp_token_asserts(environment, currencyId, False)


def test_settle_and_extend(environment, accounts):
    pass


def test_settle_and_negative_fcash(environment, accounts):
    pass

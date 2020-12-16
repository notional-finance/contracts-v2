import pytest
from brownie.test import given, strategy


@pytest.fixture(scope="module", autouse=True)
def exchangeRate(MockExchangeRate, accounts):
    return accounts[0].deploy(MockExchangeRate)


@pytest.fixture(scope="module", autouse=True)
def aggregator(MockAggregator, accounts):
    return accounts[0].deploy(MockAggregator, 18)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.mark.parametrize(
    "decimals,mustInvert", [(6, True), (6, False), (8, True), (8, False), (18, True), (18, False)]
)
def test_convert_to_eth(accounts, MockAggregator, exchangeRate, decimals, mustInvert):
    aggregator = accounts[0].deploy(MockAggregator, decimals)
    aggregator.setAnswer(10 ** decimals / 100)

    eth = exchangeRate.convertToETH(
        (aggregator.address, aggregator.decimals(), mustInvert, 1e9),
        10 ** decimals,
        10 ** decimals,
        False,
    )

    if mustInvert:
        assert eth == 1e20
    else:
        assert eth == 1e16


@pytest.mark.parametrize(
    "decimals,mustInvert", [(6, True), (6, False), (8, True), (8, False), (18, True), (18, False)]
)
def test_convert_eth_to_decimals(accounts, MockAggregator, exchangeRate, decimals, mustInvert):
    aggregator = accounts[0].deploy(MockAggregator, decimals)
    aggregator.setAnswer(10 ** decimals / 100)

    base = exchangeRate.convertETHTo(
        (aggregator.address, aggregator.decimals(), mustInvert, 1e9), 10 ** decimals, 1e18
    )

    assert base == (10 ** decimals * 100)


@pytest.mark.parametrize(
    "decimals,mustInvert", [(6, True), (6, False), (8, True), (8, False), (18, True), (18, False)]
)
def test_fetch_exchange_rate(accounts, MockAggregator, exchangeRate, decimals, mustInvert):
    aggregator = accounts[0].deploy(MockAggregator, decimals)
    aggregator.setAnswer(10 ** decimals / 100)

    rate = exchangeRate.fetchExchangeRate(
        (aggregator.address, aggregator.decimals(), mustInvert, 1e9), False
    )

    if mustInvert:
        assert rate == 10 ** decimals * 100
    else:
        assert rate == 10 ** decimals / 100


@pytest.mark.parametrize(
    "decimals,mustInvert", [(6, True), (6, False), (8, True), (8, False), (18, True), (18, False)]
)
def test_fetch_exchange_rate_invert(accounts, MockAggregator, exchangeRate, decimals, mustInvert):
    aggregator = accounts[0].deploy(MockAggregator, decimals)
    aggregator.setAnswer(10 ** decimals / 100)

    rate = exchangeRate.fetchExchangeRate(
        (aggregator.address, aggregator.decimals(), mustInvert, 1e9), True
    )

    # ETH is always the quote in the call above so mustInvert has no effect here
    assert rate == 10 ** decimals * 100


@given(buffer=strategy("uint32", min_value=1e9, max_value=2e9))
def test_convert_to_eth_buffer(aggregator, exchangeRate, buffer):
    aggregator.setAnswer(1e18)

    eth = exchangeRate.convertToETH(
        (aggregator.address, aggregator.decimals(), False, buffer), 1e18, 1e18, True
    )

    assert eth == buffer * 1e9

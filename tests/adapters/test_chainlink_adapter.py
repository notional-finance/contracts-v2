import pytest


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_matching_decimals(accounts, MockAggregator, ChainlinkAdapter):
    baseToUSD = MockAggregator.deploy(8, {"from": accounts[0]})
    baseToUSD.setAnswer(100020410)
    quoteToUSD = MockAggregator.deploy(8, {"from": accounts[0]})
    quoteToUSD.setAnswer(412438918571)

    chainlink = ChainlinkAdapter.deploy(
        baseToUSD.address,
        quoteToUSD.address,
        "Notional USDC/ETH Chainlink Adapater",
        {"from": accounts[0]},
    )

    (_, answer, _, _, _) = chainlink.latestRoundData()
    assert pytest.approx((answer * 4124) / 1e18, rel=1e-3) == 1


def test_decimal_mismatch(accounts, MockAggregator, ChainlinkAdapter):
    baseToUSD = MockAggregator.deploy(8, {"from": accounts[0]})
    baseToUSD.setAnswer(100020410)
    quoteToUSD = MockAggregator.deploy(6, {"from": accounts[0]})
    quoteToUSD.setAnswer(4124389185)

    chainlink = ChainlinkAdapter.deploy(
        baseToUSD.address,
        quoteToUSD.address,
        "Notional USDC/ETH Chainlink Adapater",
        {"from": accounts[0]},
    )

    (_, answer, _, _, _) = chainlink.latestRoundData()
    assert pytest.approx((answer * 4124) / 1e18, rel=1e-3) == 1


import pytest
import brownie
from brownie import ZERO_ADDRESS, accounts
from brownie import interface, interface, ERC4626HoldingsOracle, MockERC4626
from brownie.network.state import Chain
from scripts.mainnet.V3Environment import getEnvironment

chain = Chain()

@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()

@pytest.fixture(scope="module", autouse=True)
def v3env(accounts):
    return getEnvironment(accounts, "v3.arbitrum-one.json")

def rebalance_currency(v3env, currencyId, waToken):
    if currencyId == 1:
        underlying = ZERO_ADDRESS
    else:
        underlying = interface.IERC20(v3env.notional.getCurrency(currencyId)[1][0])
    holdingsOracle = ERC4626HoldingsOracle.deploy(
        [
            v3env.notional.address,
            underlying,
            waToken.address,
        ],
        {"from": v3env.notional.owner()})
    v3env.notional.updatePrimeCashHoldingsOracle(
        currencyId, holdingsOracle, {"from": v3env.notional.owner()}
    )
    v3env.notional.setRebalancingTargets(
        currencyId, [[waToken.address, 100]], {"from": v3env.notional.owner()}
    )
    # 100% waToken
    v3env.notional.rebalance([currencyId], {"from": ZERO_ADDRESS})
    if underlying == ZERO_ADDRESS:
        assert v3env.notional.balance() == 0
    else:
        assert underlying.balanceOf(v3env.notional) == 0        
    assert waToken.balanceOf(v3env.notional) > 0

    rate1 = v3env.notional.getPrimeFactorsStored(currencyId).dict()["oracleSupplyRate"]

    chain.sleep(50000)
    chain.mine()

    # 50% underlying 50% waToken
    v3env.notional.setRebalancingTargets(
        currencyId, [[waToken.address, 50]], {"from": v3env.notional.owner()}
    )
    v3env.notional.rebalance([currencyId], {"from": ZERO_ADDRESS})
    if underlying == ZERO_ADDRESS:
        assert v3env.notional.balance() > 0
    else:
        assert underlying.balanceOf(v3env.notional) > 0
    assert waToken.balanceOf(v3env.notional) > 0

    rate2 = v3env.notional.getPrimeFactorsStored(currencyId).dict()["oracleSupplyRate"]

    chain.sleep(50000)
    chain.mine()

    # 100% underlying
    v3env.notional.setRebalancingTargets(
        currencyId, [[waToken.address, 0]], {"from": v3env.notional.owner()}
    )
    v3env.notional.rebalance([currencyId], {"from": ZERO_ADDRESS})
    if underlying == ZERO_ADDRESS:
        assert v3env.notional.balance() > 0
    else:
        assert underlying.balanceOf(v3env.notional) > 0
    assert waToken.balanceOf(v3env.notional) == 0

    rate3 = v3env.notional.getPrimeFactorsStored(currencyId).dict()["oracleSupplyRate"]

    assert rate1 == 0
    assert rate2 > 0
    assert rate3 > 0
    assert rate3 < rate2

def test_rebalancing_eth(v3env):
    rebalance_currency(v3env, 1, interface.IERC20("0x18C100415988bEF4354EfFAd1188d1c22041B046"))

def test_rebalacing_dai(v3env):
    rebalance_currency(v3env, 2, interface.IERC20("0x345A864Ac644c82c2D649491c905C71f240700b2"))

def test_rebalancing_usdc(v3env):
    rebalance_currency(v3env, 3, interface.IERC20("0x1c0aca7cEc87Ce862638BC0DD8D8fa874d8Ad95F"))

def test_rebalancing_wbtc(v3env):
    rebalance_currency(v3env, 4, interface.IERC20("0x9ca453E4585d1Acde7Bd13f7dA2294CFAaeC4376"))

def test_underlying_delta(v3env):
    underlying = interface.IERC20(v3env.notional.getCurrency(3)[1][0])
    mockToken = MockERC4626.deploy(
        "testUSDC",
        "tUSDC",
        6,
        0,
        v3env.notional.getCurrency(3)[1][0],
        80,
        {"from": accounts[0]}
    )
    mockToken.transfer(mockToken.address, 10000000e6, {"from": accounts[0]})
    holdingsOracle = ERC4626HoldingsOracle.deploy(
        [
            v3env.notional.address,
            underlying,
            mockToken.address,
        ],
        {"from": v3env.notional.owner()})
    v3env.notional.updatePrimeCashHoldingsOracle(
        3, holdingsOracle, {"from": v3env.notional.owner()}
    )
    v3env.notional.setRebalancingTargets(
        3, [[mockToken.address, 100]], {"from": v3env.notional.owner()}
    )
    with brownie.reverts():
        v3env.notional.rebalance.call([3], {"from": ZERO_ADDRESS})

    mockToken.setScaleFactor(100)
    v3env.notional.rebalance([3], {"from": ZERO_ADDRESS})

def test_deposit_failure(v3env):
    underlying = interface.IERC20(v3env.notional.getCurrency(3)[1][0])
    mockToken = MockERC4626.deploy(
        "testUSDC",
        "tUSDC",
        6,
        0,
        v3env.notional.getCurrency(3)[1][0],
        100,
        {"from": accounts[0]}
    )
    mockToken.transfer(mockToken.address, 10000000e6, {"from": accounts[0]})
    holdingsOracle = ERC4626HoldingsOracle.deploy(
        [
            v3env.notional.address,
            underlying,
            mockToken.address,
        ],
        {"from": v3env.notional.owner()})
    v3env.notional.updatePrimeCashHoldingsOracle(
        3, holdingsOracle, {"from": v3env.notional.owner()}
    )
    v3env.notional.setRebalancingTargets(
        3, [[mockToken.address, 100]], {"from": v3env.notional.owner()}
    )

    mockToken.setDepositRevert(True)

    # Rebalance should still work
    v3env.notional.rebalance([3], {"from": ZERO_ADDRESS})
    assert underlying.balanceOf(v3env.notional) > 0
    assert mockToken.balanceOf(v3env.notional) == 0

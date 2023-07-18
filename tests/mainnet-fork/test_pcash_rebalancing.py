import pytest
import brownie
from brownie import ZERO_ADDRESS, accounts, Contract, interface
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
    return getEnvironment(accounts, "v2.mainnet.json", True, True)

def check_stored_token_balances(v3env, underlyingDonations=None, assetDonations=None):
    balances = v3env.notional.getStoredTokenBalances([
        ZERO_ADDRESS,
        v3env.pETH.holdings()[0],
        v3env.tokens["DAI"].address,
        v3env.pDAI.holdings()[0],
        v3env.tokens["USDC"].address,
        v3env.pUSDC.holdings()[0],
        v3env.tokens["WBTC"].address,
        v3env.pWBTC.holdings()[0]
    ])

    ethUnderlyingDonation = 0
    daiUnderlyingDonation = 0
    usdcUnderlyingDonation = 0
    wbtcUnderlyingDonation = 0

    if underlyingDonations != None:
        if "ETH" in underlyingDonations:
            ethUnderlyingDonation = underlyingDonations["ETH"]
        if "DAI" in underlyingDonations:
            daiUnderlyingDonation = underlyingDonations["DAI"]
        if "USDC" in underlyingDonations:
            usdcUnderlyingDonation = underlyingDonations["USDC"]
        if "WBTC" in underlyingDonations:
            wbtcUnderlyingDonation = underlyingDonations["WBTC"]

    ethAssetDonation = 0
    daiAssetDonation = 0
    usdcAssetDonation = 0
    wbtcAssetDonation = 0

    if assetDonations != None:
        if "ETH" in assetDonations:
            ethAssetDonation = assetDonations["ETH"]
        if "DAI" in assetDonations:
            daiAssetDonation = assetDonations["DAI"]
        if "USDC" in assetDonations:
            usdcAssetDonation = assetDonations["USDC"]
        if "WBTC" in assetDonations:
            wbtcAssetDonation = assetDonations["WBTC"]

    assert balances[0] + ethUnderlyingDonation == v3env.notional.balance()
    # Asset tokens have rounding errors
    assert balances[1] + ethAssetDonation == interface.IERC20(v3env.pETH.holdings()[0]).balanceOf(v3env.notional)
    assert balances[2] + daiUnderlyingDonation == v3env.tokens["DAI"].balanceOf(v3env.notional)
    assert balances[3] + daiAssetDonation == interface.IERC20(v3env.pDAI.holdings()[0]).balanceOf(v3env.notional)
    assert balances[4] + usdcUnderlyingDonation == v3env.tokens["USDC"].balanceOf(v3env.notional)
    assert balances[5] + usdcAssetDonation== interface.IERC20(v3env.pUSDC.holdings()[0]).balanceOf(v3env.notional)
    assert balances[6] + wbtcUnderlyingDonation == v3env.tokens["WBTC"].balanceOf(v3env.notional)
    assert balances[7] + wbtcAssetDonation== interface.IERC20(v3env.pWBTC.holdings()[0]).balanceOf(v3env.notional)

def test_rebalancing_to_underlying_100_percent(v3env):
    ethRateOracle = v3env.notional.getCurrencyAndRates(4)["assetRate"]["rateOracle"]

    v3env.upgradeToV3()

    # Set targets to 0 = 100% underlying
    v3env.notional.setRebalancingTargets(1, [[v3env.pETH.holdings()[0], 0]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(2, [[v3env.pDAI.holdings()[0], 0]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(3, [[v3env.pUSDC.holdings()[0], 0]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(4, [[v3env.pWBTC.holdings()[0], 0]], {"from": v3env.notional.owner()})

    assert v3env.notional.getRebalancingTarget(1, v3env.pETH.holdings()[0]) == 0
    assert v3env.notional.getRebalancingTarget(2, v3env.pDAI.holdings()[0]) == 0
    assert v3env.notional.getRebalancingTarget(3, v3env.pUSDC.holdings()[0]) == 0
    assert v3env.notional.getRebalancingTarget(4, v3env.pWBTC.holdings()[0]) == 0

    check_stored_token_balances(v3env)

    expectedUnderlyingETH = v3env.pETH.getTotalUnderlyingValueView()
    expectedUnderlyingDAI = v3env.pDAI.getTotalUnderlyingValueView()
    expectedUnderlyingUSDC = v3env.pUSDC.getTotalUnderlyingValueView()
    expectedUnderlyingWBTC = v3env.pWBTC.getTotalUnderlyingValueView()

    # Only treasury manager can rebalance
    with brownie.reverts():
        v3env.notional.rebalance.call([1,2,3,4], {"from": v3env.notional.owner()})

    v3env.notional.rebalance([1,2,3,4], {"from": v3env.notional.getTreasuryManager()})

    check_stored_token_balances(v3env)

    assert v3env.notional.balance() == expectedUnderlyingETH[0]
    assert pytest.approx(v3env.tokens["DAI"].balanceOf(v3env.notional), rel=1e-5) == expectedUnderlyingDAI[0]
    assert pytest.approx(v3env.tokens["USDC"].balanceOf(v3env.notional), rel=1e-5) == expectedUnderlyingUSDC[0]
    assert pytest.approx(v3env.tokens["WBTC"].balanceOf(v3env.notional), rel=1e-5) == expectedUnderlyingWBTC[0]
    
def test_rebalancing_to_asset_100_percent(v3env):
    v3env.upgradeToV3()

    # Set targets to 0 = 100% underlying
    v3env.notional.setRebalancingTargets(1, [[v3env.pETH.holdings()[0], 100]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(2, [[v3env.pDAI.holdings()[0], 100]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(3, [[v3env.pUSDC.holdings()[0], 100]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(4, [[v3env.pWBTC.holdings()[0], 100]], {"from": v3env.notional.owner()})

    assert v3env.notional.getRebalancingTarget(1, v3env.pETH.holdings()[0]) == 100
    assert v3env.notional.getRebalancingTarget(2, v3env.pDAI.holdings()[0]) == 100
    assert v3env.notional.getRebalancingTarget(3, v3env.pUSDC.holdings()[0]) == 100
    assert v3env.notional.getRebalancingTarget(4, v3env.pWBTC.holdings()[0]) == 100

    check_stored_token_balances(v3env)

    v3env.notional.rebalance([1,2,3,4], {"from": v3env.notional.getTreasuryManager()})

    check_stored_token_balances(v3env)

    assert v3env.notional.balance() == 0
    assert v3env.tokens["DAI"].balanceOf(v3env.notional) == 0
    assert v3env.tokens["USDC"].balanceOf(v3env.notional) == 0
    assert v3env.tokens["WBTC"].balanceOf(v3env.notional) == 0
    

def test_rebalancing_to_underlying_50_percent(v3env):
    v3env.upgradeToV3()

    # Set targets to 0 = 100% underlying
    v3env.notional.setRebalancingTargets(1, [[v3env.pETH.holdings()[0], 50]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(2, [[v3env.pDAI.holdings()[0], 50]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(3, [[v3env.pUSDC.holdings()[0], 50]], {"from": v3env.notional.owner()})
    v3env.notional.setRebalancingTargets(4, [[v3env.pWBTC.holdings()[0], 50]], {"from": v3env.notional.owner()})

    assert v3env.notional.getRebalancingTarget(1, v3env.pETH.holdings()[0]) == 50
    assert v3env.notional.getRebalancingTarget(2, v3env.pDAI.holdings()[0]) == 50
    assert v3env.notional.getRebalancingTarget(3, v3env.pUSDC.holdings()[0]) == 50
    assert v3env.notional.getRebalancingTarget(4, v3env.pWBTC.holdings()[0]) == 50

    check_stored_token_balances(v3env)

    v3env.notional.rebalance([1,2,3,4], {"from": v3env.notional.getTreasuryManager()})

    check_stored_token_balances(v3env)

    expectedUnderlyingETH = v3env.pETH.getTotalUnderlyingValueView()
    expectedUnderlyingDAI = v3env.pDAI.getTotalUnderlyingValueView()
    expectedUnderlyingUSDC = v3env.pUSDC.getTotalUnderlyingValueView()
    expectedUnderlyingWBTC = v3env.pWBTC.getTotalUnderlyingValueView()

    assert pytest.approx(v3env.notional.balance(), rel=1e-5) == expectedUnderlyingETH[0] / 2
    assert pytest.approx(v3env.tokens["DAI"].balanceOf(v3env.notional), rel=1e-5) == expectedUnderlyingDAI[0] / 2
    assert pytest.approx(v3env.tokens["USDC"].balanceOf(v3env.notional), rel=1e-5) == expectedUnderlyingUSDC[0] / 2
    assert pytest.approx(v3env.tokens["WBTC"].balanceOf(v3env.notional), rel=1e-5) == expectedUnderlyingWBTC[0] / 2

def test_underlying_donations(v3env):
    v3env.upgradeToV3()

    ethWhale = accounts.at("0x1b3cb81e51011b549d78bf720b0d924ac763a7c2", force=True)
    daiWhale = accounts.at("0x604981db0C06Ea1b37495265EDa4619c8Eb95A3D", force=True)
    usdcWhale = accounts.at("0x0a59649758aa4d66e25f08dd01271e891fe52199", force=True)
    wbtcWhale = accounts.at("0x693942887922785105088f04E9906D16188E9388", force=True)

    check_stored_token_balances(v3env)

    ethWhale.transfer(v3env.notional, 100e18)
    v3env.tokens["DAI"].transfer(v3env.notional, 10000e18, {"from": daiWhale})
    v3env.tokens["USDC"].transfer(v3env.notional, 10000e6, {"from": usdcWhale})
    v3env.tokens["WBTC"].transfer(v3env.notional, 10e8, {"from": wbtcWhale})

    check_stored_token_balances(v3env, {
        "ETH": 100e18,
        "DAI": 10000e18,
        "USDC": 10000e6,
        "WBTC": 10e8
    })

def test_asset_donations(v3env):
    v3env.upgradeToV3()

    cethWhale = accounts.at("0x1a1cd9c606727a7400bb2da6e4d5c70db5b4cade", force=True)
    cdaiWhale = accounts.at("0xFbD01435Bcb21ca11526653fb2Cde27ceF012937", force=True)
    cusdcWhale = accounts.at("0xE0E484Dfa7F3aA36733A915D6f07EB5a57A74a11", force=True)
    cwbtcWhale = accounts.at("0x562859C109170E59e5a1f14712E36A08C117559f", force=True)

    check_stored_token_balances(v3env)

    v3env.tokens["cETH"].transfer(v3env.notional, 100000e8, {"from": cethWhale})
    v3env.tokens["cDAI"].transfer(v3env.notional, 100000e8, {"from": cdaiWhale})
    v3env.tokens["cUSDC"].transfer(v3env.notional, 100000e8, {"from": cusdcWhale})
    v3env.tokens["cWBTC"].transfer(v3env.notional, 10e8, {"from": cwbtcWhale})

    check_stored_token_balances(v3env, None, {
        "ETH": 100000e8,
        "DAI": 100000e8,
        "USDC": 100000e8,
        "WBTC": 10e8
    })

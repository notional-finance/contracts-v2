
import json
import pytest
from brownie import MockERC20, interface, Router, Contract, nProxy
from brownie.network.contract import Contract
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
    output_file = "v3.arbitrum-one.json"
    addresses = None
    with open(output_file, "r") as f:
        addresses = json.load(f)

    notional = Contract.from_abi("Notional", addresses["notional"], abi=interface.NotionalProxy.abi)
    router = Contract.from_abi("Router", addresses["notional"], abi=Router.abi)
    proxy = Contract.from_abi("Proxy", addresses["notional"], abi=nProxy.abi)
    return (notional, router, proxy)

def test_migrate_usdc(v3env, MigrateUSDC, UnderlyingHoldingsOracle, accounts):
    (notional, _, proxy) = v3env
    oracle = UnderlyingHoldingsOracle.deploy(notional.address, "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", {"from": accounts[0]})
    migrate = MigrateUSDC.deploy(oracle, {"from": accounts[0]})

    nativeUSDCWhale = "0x3DD1D15b3c78d6aCFD75a254e857Cbe5b9fF0aF2"
    funding = migrate.FUNDING()
    usdc = MockERC20.at(migrate.USDC())
    usdc_e = MockERC20.at(migrate.USDC_E())
    usdc.transfer(funding, usdc_e.balanceOf(notional.address), {"from": nativeUSDCWhale})

    usdc.approve(notional, 2 ** 255, {"from": migrate.FUNDING()})
    routerBefore = proxy.getImplementation()

    balanceBefore = usdc_e.balanceOf(notional.address)
    notional.transferOwnership(migrate, False, {"from": notional.owner()})
    txn = migrate.atomicPatchAndUpgrade({"from": notional.owner()})

    notional.accruePrimeInterest(3, {"from": accounts[0]})

    assert proxy.getImplementation() == routerBefore
    assert notional.getCurrency(3)['underlyingToken'][0] == usdc.address
    assert balanceBefore == usdc.balanceOf(notional.address)
    assert usdc_e.balanceOf(notional.address) == 0

    usdc.transfer(funding, 100e6, {"from": nativeUSDCWhale})
    notional.depositUnderlyingToken(funding, 3, 100e6, {"from": funding})
    assert pytest.approx(notional.getAccountBalance(3, funding)[0], rel=0.01) == 99.1e8



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

def test_migrate_usdc(v3env, MigrateUSDC, accounts):
    (notional, _, proxy) = v3env
    migrate = MigrateUSDC.at("0xD314feBE286b84368c64b2b81e21A40d86D3C1C8")

    funding = migrate.FUNDING()
    usdc = MockERC20.at(migrate.USDC())
    usdc_e = MockERC20.at(migrate.USDC_E())
    routerBefore = proxy.getImplementation()

    balanceBefore = usdc_e.balanceOf(notional.address)
    notional.transferOwnership(migrate, False, {"from": notional.owner()})
    lastUnderlyingBefore = notional.getPrimeFactors(3, chain.time())['factors']['lastTotalUnderlyingValue']
    txn = migrate.atomicPatchAndUpgrade({"from": notional.owner()})

    notional.accruePrimeInterest(3, {"from": accounts[0]})
    lastUnderlyingAfter = notional.getPrimeFactors(3, chain.time() + 1)['factors']['lastTotalUnderlyingValue']

    assert lastUnderlyingBefore == lastUnderlyingAfter
    assert proxy.getImplementation() == routerBefore
    assert notional.getCurrency(3)['underlyingToken'][0] == usdc.address
    assert balanceBefore == usdc.balanceOf(notional.address)
    assert usdc_e.balanceOf(notional.address) == 0
    assert usdc_e.balanceOf(funding) == balanceBefore

    notional.depositUnderlyingToken(funding, 3, 10e6, {"from": funding})
    assert pytest.approx(notional.getAccountBalance(3, funding)[0], rel=0.01) == 9.9e8


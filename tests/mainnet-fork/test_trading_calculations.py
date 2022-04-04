import pytest
from brownie import NotionalV21PatchFix
from brownie.convert.datatypes import Wei
from brownie.network import Chain
from brownie.test import given, strategy
from scripts.mainnet.EnvironmentConfig import getEnvironment
from scripts.mainnet.upgrade_notional import full_upgrade

chain = Chain()


@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()


@pytest.fixture(scope="module", autouse=True)
def environment():
    return getEnvironment()


def upgrade_to_v21(notional, deployer, owner):
    impl = notional.getImplementation()
    (router, pauseRouter, contracts) = full_upgrade(deployer, False)
    # Upgrade so transfer ownership works
    notional.upgradeTo(router.address, {"from": owner})

    patchFix = NotionalV21PatchFix.deploy(impl, router.address, notional.address, {"from": deployer})
    notional.transferOwnership(patchFix.address, False, {"from": owner})
    txn = patchFix.atomicPatchAndUpgrade({"from": owner})
    return txn


@given(
    cashAmountInternal=strategy("int256", min_value=-100_000e8, max_value=-10e8),
    marketIndex=strategy("uint", min_value=1, max_value=3),
)
def test_calculations_no_errors(
    environment, cashAmountInternal, marketIndex, MockContractLender, accounts
):
    upgrade_to_v21(environment.notional, environment.deployer, environment.owner)
    lender = MockContractLender.deploy(environment.notional.address, {"from": accounts[0]})
    account = environment.whales["USDC"]
    currencyId = 3
    cashAmountExternal = Wei(cashAmountInternal / -100)

    environment.tokens["USDC"].transfer(lender, cashAmountExternal + 1, {"from": account})
    # This should not revert
    lender.lend(currencyId, cashAmountInternal, marketIndex, {"from": accounts[0]})

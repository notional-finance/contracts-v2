import brownie
import pytest
from tests.helpers import initialize_environment


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


def test_patch_fix_router(environment, MockPatchFix, MockRouter, accounts):
    newRouter = MockRouter.deploy({"from": accounts[0]})
    patchFix = MockPatchFix.deploy(
        environment.proxy.getImplementation(),
        newRouter.address, 
        environment.notional.address, 
        {"from": accounts[0]}
    )

    with brownie.reverts():
        patchFix.atomicPatchAndUpgrade({"from": accounts[0]})

    environment.notional.transferOwnership(patchFix.address, False, {"from": accounts[0]})
    patchFix.atomicPatchAndUpgrade({"from": accounts[0]})

    assert environment.proxy.getImplementation() == newRouter.address
    assert environment.notional.owner() == accounts[0]

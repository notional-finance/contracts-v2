import brownie
import pytest
from tests.helpers import initialize_environment


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


def test_patch_fix_router(environment, SettlementRateFix, accounts):
    originalImpl = environment.proxy.getImplementation()
    patchFix = SettlementRateFix.deploy(
        originalImpl, environment.notional.address, {"from": accounts[0]}
    )

    with brownie.reverts():
        patchFix.atomicPatchAndUpgrade({"from": accounts[0]})

    environment.notional.transferOwnership(patchFix.address, False, {"from": accounts[0]})
    patchFix.atomicPatchAndUpgrade({"from": accounts[0]})

    assert environment.proxy.getImplementation() == originalImpl
    assert environment.notional.owner() == accounts[0]

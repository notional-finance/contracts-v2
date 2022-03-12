import pytest
from brownie import NotionalV21PatchFix
from scripts.mainnet.EnvironmentConfig import getEnvironment
from scripts.mainnet.upgrade_notional import full_upgrade


@pytest.fixture(scope="module", autouse=True)
def environment():
    return getEnvironment()


def upgrade_to_v21(notional, deployer, owner):
    (router, pauseRouter, contracts) = full_upgrade(deployer, False)
    # Upgrade so transfer ownership works
    notional.upgradeTo(router.address, {"from": owner})

    patchFix = NotionalV21PatchFix.deploy(router.address, notional.address, {"from": deployer})
    notional.transferOwnership(patchFix.address, False, {"from": owner})
    txn = patchFix.atomicPatchAndUpgrade({"from": owner})
    return txn


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_patchfix_migration(environment, accounts):
    nTokenAccounts = []
    for i in range(0, 4):
        nTokenAddress = environment.notional.nTokenAddress(i + 1)
        nTokenAccounts.append(environment.notional.getNTokenAccount(nTokenAddress))

    txn = upgrade_to_v21(environment.notional, environment.deployer, environment.owner)
    assert environment.notional.owner() == environment.owner.address

    for i in range(0, 4):
        nTokenAddress = environment.notional.nTokenAddress(i + 1)
        context = environment.notional.getNTokenAccount(nTokenAddress)
        # Ensure that all non incentive factors (including total supply) have not changed
        # before and after the upgrade
        assert nTokenAccounts[i][0:5] == context[0:5]
        assert context[6] == 0
        assert context[7] == txn.timestamp


@pytest.mark.only
def test_migrate_existing_accounts(environment, accounts):
    # TODO: test a few existing accounts
    assert False


@pytest.mark.only
def test_establish_new_accounts(environment, accounts):
    # TODO: establish new accounts
    assert False

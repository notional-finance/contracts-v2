import pytest
from brownie import NotionalV21PatchFix
from brownie.network import Chain
from scripts.mainnet.EnvironmentConfig import getEnvironment
from scripts.mainnet.upgrade_notional import full_upgrade
from tests.helpers import get_balance_action

chain = Chain()
initialImpl = None


@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()


@pytest.fixture(scope="module", autouse=True)
def environment():
    return getEnvironment()


def upgrade_to_v21(notional, deployer, owner):
    global initialImpl
    initialImpl = notional.getImplementation()
    (router, pauseRouter, contracts) = full_upgrade(deployer, False)
    # Upgrade so transfer ownership works
    notional.upgradeTo(router.address, {"from": owner})

    patchFix = NotionalV21PatchFix.deploy(router.address, notional.address, {"from": deployer})
    notional.transferOwnership(patchFix.address, False, {"from": owner})
    txn = patchFix.atomicPatchAndUpgrade({"from": owner})
    return txn


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


def test_migrate_existing_accounts_no_change_to_incentives(environment, accounts):
    whale = accounts.at("0x4a65e76be1b4e8dd6ef618277fa55200e3f8f20a", force=True)
    minnow = accounts.at("0xb04ad04a2ac41dbbe8be06ee8938318575bb5e4b", force=True)

    environment.notional.nTokenClaimIncentives({"from": whale})
    environment.notional.nTokenClaimIncentives({"from": minnow})

    whaleBalanceAfterNoUpgrade = environment.tokens["NOTE"].balanceOf(whale)
    minnowBalanceAfterNoUpgrade = environment.tokens["NOTE"].balanceOf(minnow)
    chain.undo(2)

    upgrade_to_v21(environment.notional, environment.deployer, environment.owner)

    environment.notional.nTokenClaimIncentives({"from": whale})
    environment.notional.nTokenClaimIncentives({"from": minnow})
    whaleBalanceAfterUpgrade = environment.tokens["NOTE"].balanceOf(whale)
    minnowBalanceAfterUpgrade = environment.tokens["NOTE"].balanceOf(minnow)

    assert pytest.approx(whaleBalanceAfterNoUpgrade, rel=1e-5) == whaleBalanceAfterUpgrade
    assert pytest.approx(minnowBalanceAfterNoUpgrade, rel=1e-5) == minnowBalanceAfterUpgrade


def test_establish_new_accounts(environment, accounts):
    currencyId = 2
    # Brownie is not properly reverting the contract upgrade so ensure that it is upgraded here
    # txn = upgrade_to_v21(environment.notional, environment.deployer, environment.owner)
    assert environment.notional.getImplementation() != initialImpl

    assert (0, 0, 0) == environment.notional.getAccountBalance(
        currencyId, environment.whales["DAI"]
    )
    assert environment.tokens["NOTE"].balanceOf(environment.whales["DAI"]) == 0
    environment.tokens["DAI"].approve(
        environment.notional.address, 2 ** 255 - 1, {"from": environment.whales["DAI"]}
    )
    environment.notional.batchBalanceAction(
        environment.whales["DAI"],
        [
            get_balance_action(
                currencyId, "DepositUnderlyingAndMintNToken", depositActionAmount=50_000_000e18
            )
        ],
        {"from": environment.whales["DAI"]},
    )
    totalSupply = environment.tokens["nDAI"].totalSupply()
    balanceOf = environment.tokens["nDAI"].balanceOf(environment.whales["DAI"])

    chain.mine(timedelta=86400)
    environment.notional.nTokenClaimIncentives({"from": environment.whales["DAI"]})
    balanceAfter = environment.tokens["NOTE"].balanceOf(environment.whales["DAI"])
    expected = (balanceOf * 9_000_000e8) / totalSupply / 360
    assert (expected - balanceAfter) / 1e8 < 10

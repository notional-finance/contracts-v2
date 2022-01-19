import brownie
import pytest
from brownie.network.state import Chain
from scripts.mainnet.EnvironmentConfig import getEnvironment
from scripts.mainnet.upgrade_notional import full_upgrade

chain = Chain()


@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()


@pytest.fixture(autouse=True)
def env():
    e = getEnvironment()

    (router, pauseRouter, contracts) = full_upgrade(e.deployer, False)
    e.notional.upgradeTo(router.address, {"from": e.owner})

    return e


def test_set_treasury_manager_owner(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.owner})
    assert env.notional.getTreasuryManager() == env.deployer


def test_set_treasury_manager_non_owner(env):
    with brownie.reverts():
        env.notional.setTreasuryManager(env.deployer, {"from": env.deployer})


def test_set_reserve_buffer_owner(env):
    env.notional.setReserveBuffer(2, 1e6, {"from": env.owner})
    assert env.notional.getReserveBuffer(2) == 1e6


def test_set_reserve_buffer_non_owner(env):
    with brownie.reverts():
        env.notional.setReserveBuffer(2, 0.01e8, {"from": env.deployer})


def test_set_reserve_buffer_too_large(env):
    with brownie.reverts():
        env.notional.setReserveBuffer(2, 1e10, {"from": env.owner})


def test_claim_comp_manager(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.owner})
    claimed = env.tokens["COMP"].balanceOf(env.deployer)
    assert claimed == 0
    env.notional.claimCOMP([env.tokens["cDAI"].address], {"from": env.deployer})
    claimed = env.tokens["COMP"].balanceOf(env.deployer)
    assert claimed >= 3600009197861284083563


def test_claim_comp_non_manager(env):
    with brownie.reverts():
        env.notional.claimCOMP([env.tokens["cDAI"]], {"from": env.deployer})


def test_harvest_reserve_manager(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.owner})
    env.notional.setReserveBuffer(2, 0.0001e8, {"from": env.owner})
    DAIBalBefore = env.tokens["DAI"].balanceOf(env.deployer)
    assert DAIBalBefore == 0
    cDAIReserveBefore = env.notional.getReserveBalance(2)
    cDAITotalBefore = env.tokens["cDAI"].balanceOf(env.notional.address)
    assert cDAIReserveBefore / cDAITotalBefore > 0.0008
    env.notional.transferReserveToTreasury([2], {"from": env.deployer})
    DAIBalAfter = env.tokens["DAI"].balanceOf(env.deployer)
    assert DAIBalAfter > 0
    cDAIReserveAfter = env.notional.getReserveBalance(2)
    cDAITotalAfter = env.tokens["cDAI"].balanceOf(env.notional.address)
    ratio = cDAIReserveAfter / cDAITotalAfter
    assert ratio > 0.0001 and ratio < 0.00011

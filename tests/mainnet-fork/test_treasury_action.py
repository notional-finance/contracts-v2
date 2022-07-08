import math

import brownie
import pytest
from brownie.network.state import Chain
from scripts.mainnet.EnvironmentConfig import getEnvironment

chain = Chain()


@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()


@pytest.fixture(autouse=True)
def env():
    e = getEnvironment()
    return e


def test_set_treasury_manager_owner(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.notional.owner()})
    assert env.notional.getTreasuryManager() == env.deployer


def test_set_treasury_manager_non_owner(env):
    with brownie.reverts():
        env.notional.setTreasuryManager(env.deployer, {"from": env.deployer})


def test_set_reserve_buffer_owner(env):
    env.notional.setReserveBuffer(2, 1000e8, {"from": env.notional.owner()})
    assert env.notional.getReserveBuffer(2) == 1000e8


def test_set_reserve_buffer_non_owner(env):
    with brownie.reverts():
        env.notional.setReserveBuffer(2, 1000e8, {"from": env.deployer})


def test_claim_comp_manager(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.notional.owner()})
    assert env.tokens["COMP"].balanceOf(env.notional.address) == 0
    assert env.tokens["COMP"].balanceOf(env.deployer) == 0
    env.notional.claimCOMPAndTransfer([env.tokens["cDAI"].address], {"from": env.deployer})
    assert env.tokens["COMP"].balanceOf(env.notional.address) == 0
    assert env.tokens["COMP"].balanceOf(env.deployer) >= 3113005691001499849856


def test_claim_comp_non_manager(env):
    with brownie.reverts():
        env.notional.claimCOMPAndTransfer([env.tokens["cDAI"].address], {"from": env.deployer})


def convert_to_underlying(assetRate, assetBalance):
    return assetRate[1] * assetBalance / assetRate[2]


def check_reserve_balances(env, currencyId, before, after, buffer):
    assetRate = env.notional.getCurrencyAndRates(currencyId)[3]
    assert math.floor(after / 1e10) == math.floor(
        convert_to_underlying(assetRate, before - buffer) / 1e10
    )
    assert env.notional.getReserveBalance(currencyId) == buffer


def test_harvest_reserve_DAI_manager_more_than_buffer(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.notional.owner()})
    env.notional.setReserveBuffer(2, 10000e8, {"from": env.notional.owner()})

    DAIBalBefore = env.tokens["DAI"].balanceOf(env.deployer)

    env.notional.transferReserveToTreasury([2], {"from": env.deployer})
    assert env.notional.getReserveBalance(2) == 10000e8
    assert env.tokens["DAI"].balanceOf(env.deployer) - DAIBalBefore > 0


def test_harvest_reserve_DAI_non_manager(env):
    env.notional.setReserveBuffer(2, 10000e8, {"from": env.notional.owner()})
    with brownie.reverts():
        env.notional.transferReserveToTreasury([2], {"from": env.deployer})


def test_harvest_reserve_invalid_currency_id(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.notional.owner()})
    env.notional.setReserveBuffer(2, 10000e8, {"from": env.notional.owner()})
    with brownie.reverts():
        env.notional.transferReserveToTreasury([10], {"from": env.deployer})


def test_harvest_reserve_ETH_manager_more_than_buffer(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.notional.owner()})
    env.notional.setReserveBuffer(1, 0.01e8, {"from": env.notional.owner()})

    ETHBalBefore = env.deployer.balance()
    cETHReserveBefore = env.notional.getReserveBalance(1)

    env.notional.transferReserveToTreasury([1], {"from": env.deployer})
    ETHBalAfter = env.deployer.balance()
    check_reserve_balances(env, 1, cETHReserveBefore, ETHBalAfter - ETHBalBefore, 0.01e8)


def test_harvest_reserve_ETH_manager_less_than_buffer(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.notional.owner()})
    env.notional.setReserveBuffer(1, 100e8, {"from": env.notional.owner()})

    ETHBalBefore = env.deployer.balance()
    env.notional.transferReserveToTreasury([1], {"from": env.deployer})
    assert env.deployer.balance() - ETHBalBefore == 0


def test_harvest_reserve_multiple(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.notional.owner()})
    env.notional.setReserveBuffer(1, 0.01e8, {"from": env.notional.owner()})
    env.notional.setReserveBuffer(2, 10000e8, {"from": env.notional.owner()})

    DAIBalBefore = env.tokens["DAI"].balanceOf(env.deployer)
    cDAIReserveBefore = env.notional.getReserveBalance(2)

    ETHBalBefore = env.deployer.balance()
    cETHReserveBefore = env.notional.getReserveBalance(1)
    env.notional.transferReserveToTreasury([1, 2], {"from": env.deployer})

    DAIBalAfter = env.tokens["DAI"].balanceOf(env.deployer)
    check_reserve_balances(env, 2, cDAIReserveBefore, DAIBalAfter - DAIBalBefore, 10000e8)

    ETHBalAfter = env.deployer.balance()
    check_reserve_balances(env, 1, cETHReserveBefore, ETHBalAfter - ETHBalBefore, 0.01e8)


def test_harvest_reserve_multiple_invalid_order(env):
    env.notional.setTreasuryManager(env.deployer, {"from": env.notional.owner()})
    env.notional.setReserveBuffer(1, 0.01e8, {"from": env.notional.owner()})
    env.notional.setReserveBuffer(2, 10000e8, {"from": env.notional.owner()})
    with brownie.reverts():
        env.notional.transferReserveToTreasury([2, 1], {"from": env.deployer})


def test_set_reserve_cash_balance_owner(env):
    balanceBefore = env.notional.getReserveBalance(2)
    env.notional.setReserveCashBalance(2, balanceBefore / 2, {"from": env.notional.owner()})
    balanceAfter = env.notional.getReserveBalance(2)
    assert math.floor(balanceBefore / 2) == balanceAfter


def test_set_reserve_cash_balance_non_owner(env):
    balanceBefore = env.notional.getReserveBalance(2)
    with brownie.reverts():
        env.notional.setReserveCashBalance(2, balanceBefore / 2, {"from": env.deployer})


def test_set_reserve_cash_balance_invalid_currency(env):
    balanceBefore = env.notional.getReserveBalance(2)
    with brownie.reverts():
        env.notional.setReserveCashBalance(10, balanceBefore / 2, {"from": env.notional.owner()})

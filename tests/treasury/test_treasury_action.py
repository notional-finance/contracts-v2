import pytest
import brownie
import eth_abi
from brownie import accounts
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from scripts.treasury.treasury import create_environment, EnvironmentConfig
from brownie.network.web3 import web3

chain = Chain()

@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()

def test_set_treasury_manager_owner():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    assert env.treasury.getTreasuryManager() == env.deployer

def test_set_treasury_manager_non_owner():
    env = create_environment()
    with brownie.reverts():
        env.treasury.setTreasuryManager(env.deployer, {"from": env.deployer})

def test_set_reserve_buffer_owner():
    env = create_environment()
    env.treasury.setReserveBuffer(2, 1e6, {"from": env.proxy.owner()})
    assert env.treasury.getReserveBuffer(2) == 1e6

def test_set_reserve_buffer_non_owner():
    env = create_environment()
    with brownie.reverts():
        env.treasury.setReserveBuffer(2, 0.01e8, {"from": env.deployer})        

def test_set_reserve_buffer_too_large():
    env = create_environment()
    with brownie.reverts():
        env.treasury.setReserveBuffer(2, 1e10, {"from": env.proxy.owner()})        

def test_claim_comp_manager():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    claimed = env.COMPToken.balanceOf(env.deployer)
    assert claimed == 0
    env.treasury.claimCOMP([EnvironmentConfig["cDAI"]], {"from": env.deployer})   
    claimed = env.COMPToken.balanceOf(env.deployer)
    assert claimed >= 3600009197861284083563
    
def test_claim_comp_non_manager():
    env = create_environment()
    with brownie.reverts():
        env.treasury.claimCOMP([EnvironmentConfig["cDAI"]], {"from": env.deployer})

def test_harvest_reserve_manager():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(2, 0.0001e8, {"from": env.proxy.owner()})
    DAIBalBefore = env.DAIToken.balanceOf(env.deployer)
    assert DAIBalBefore == 0
    cDAIReserveBefore = env.proxy.getReserveBalance(2)
    cDAITotalBefore = env.cDAIToken.balanceOf(env.proxy.address)
    assert cDAIReserveBefore / cDAITotalBefore > 0.0008
    env.treasury.transferReserveToTreasury([2], {"from": env.deployer})
    DAIBalAfter = env.DAIToken.balanceOf(env.deployer)
    assert DAIBalAfter > 0
    cDAIReserveAfter = env.proxy.getReserveBalance(2)
    cDAITotalAfter = env.cDAIToken.balanceOf(env.proxy.address)
    ratio = cDAIReserveAfter / cDAITotalAfter
    assert ratio > 0.0001 and ratio < 0.00011

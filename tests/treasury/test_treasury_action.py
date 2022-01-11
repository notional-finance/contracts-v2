import pytest
import brownie
import eth_abi
from brownie import accounts
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from scripts.treasury.treasury import create_environment, EnvironmentConfig

chain = Chain()
@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()

def test_set_treasury_manager_owner():
    env = create_environment()
    env.treasury.setTreasuryManager('0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef', {"from": env.proxy.owner()})
    assert env.treasury.getTreasuryManager() == '0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef'
    pass

def test_set_treasury_manager_non_owner():
    env = create_environment()
    with brownie.reverts():
        env.treasury.setTreasuryManager(env.deployer, {"from": env.deployer})
    pass

def test_set_reserve_buffer_owner():
    env = create_environment()
    env.treasury.setReserveBuffer(2, 1e6, {"from": env.proxy.owner()})
    assert env.treasury.getReserveBuffer(2) == 1e6
    pass

def test_set_reserve_buffer_non_owner():
    env = create_environment()
    with brownie.reverts():
        env.treasury.setReserveBuffer(2, 0.01e8, {"from": env.deployer})        
    pass

def test_set_reserve_buffer_too_large():
    env = create_environment()
    with brownie.reverts():
        env.treasury.setReserveBuffer(2, 1e10, {"from": env.proxy.owner()})        
    pass

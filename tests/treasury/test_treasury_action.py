import pytest
import brownie
import math
from brownie import accounts
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from scripts.treasury.treasury import create_environment, EnvironmentConfig, TestAccounts
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
    assert env.proxy.getTreasuryManager() == env.deployer

def test_set_treasury_manager_non_owner():
    env = create_environment()
    with brownie.reverts():
        env.treasury.setTreasuryManager(env.deployer, {"from": env.deployer})

def test_set_reserve_buffer_owner():
    env = create_environment()
    env.treasury.setReserveBuffer(2, 1000e8, {"from": env.proxy.owner()})
    assert env.proxy.getReserveBuffer(2) == 1000e8

def test_set_reserve_buffer_non_owner():
    env = create_environment()
    with brownie.reverts():
        env.treasury.setReserveBuffer(2, 1000e8, {"from": env.deployer})        

def test_claim_comp_manager():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    assert env.COMPToken.balanceOf(env.treasury.address) == 0
    assert env.COMPToken.balanceOf(env.deployer) == 0
    env.treasury.claimCOMPAndTransfer([EnvironmentConfig["cDAI"]], {"from": env.deployer})   
    assert env.COMPToken.balanceOf(env.treasury.address) == 0
    assert env.COMPToken.balanceOf(env.deployer) >= 3600009197861284083563
    
def test_claim_comp_non_manager():
    env = create_environment()
    with brownie.reverts():
        env.treasury.claimCOMPAndTransfer([EnvironmentConfig["cDAI"]], {"from": env.deployer})

def test_claim_comp_preexisting_balance():
    env = create_environment()
    testAccounts = TestAccounts()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.COMPToken.transfer(env.treasury.address, 100e18, {"from": testAccounts.COMPWhale})
    assert env.COMPToken.balanceOf(env.treasury.address) == 100e18
    assert env.COMPToken.balanceOf(env.deployer) == 0
    env.treasury.claimCOMPAndTransfer([EnvironmentConfig["cDAI"]], {"from": env.deployer})   
    assert env.COMPToken.balanceOf(env.treasury.address) == 100e18
    assert env.COMPToken.balanceOf(env.deployer) >= 3600009197861284083563

def convert_to_underlying(assetRate, assetBalance):
    return assetRate[1] * assetBalance / assetRate[2]

def check_reserve_balances(env, currencyId, before, after, buffer):
    assetRate = env.proxy.getCurrencyAndRates(currencyId)[3]
    assert math.floor(after / 1e10) == math.floor(convert_to_underlying(assetRate, before - buffer) / 1e10)
    assert env.proxy.getReserveBalance(currencyId) == buffer

def test_harvest_reserve_DAI_manager_more_than_buffer():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(2, 10000e8, {"from": env.proxy.owner()})

    DAIBalBefore = env.DAIToken.balanceOf(env.deployer)
    assert DAIBalBefore == 0
    cDAIReserveBefore = env.proxy.getReserveBalance(2)

    env.treasury.transferReserveToTreasury([2], {"from": env.deployer})
    DAIBalAfter = env.DAIToken.balanceOf(env.deployer)
    check_reserve_balances(env, 2, cDAIReserveBefore, DAIBalAfter, 10000e8)

def test_harvest_reserve_DAI_manager_less_than_buffer():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(2, 10000000e8, {"from": env.proxy.owner()})

    DAIBalBefore = env.DAIToken.balanceOf(env.deployer)
    assert DAIBalBefore == 0

    env.treasury.transferReserveToTreasury([2], {"from": env.deployer})
    assert env.DAIToken.balanceOf(env.deployer) == 0
 
def test_harvest_reserve_DAI_non_manager():
    env = create_environment()
    env.treasury.setReserveBuffer(2, 10000e8, {"from": env.proxy.owner()})
    with brownie.reverts():
       env.treasury.transferReserveToTreasury([2], {"from": env.deployer})

def test_harvest_reserve_invalid_currency_id():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(2, 10000e8, {"from": env.proxy.owner()})
    with brownie.reverts():
       env.treasury.transferReserveToTreasury([10], {"from": env.deployer})
 
def test_harvest_reserve_ETH_manager_more_than_buffer():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(1, 0.01e8, {"from": env.proxy.owner()})

    WETHBalBefore = env.WETHToken.balanceOf(env.deployer)
    assert WETHBalBefore == 0
    cETHReserveBefore = env.proxy.getReserveBalance(1)

    env.treasury.transferReserveToTreasury([1], {"from": env.deployer})
    WETHBalAfter = env.WETHToken.balanceOf(env.deployer)
    check_reserve_balances(env, 1, cETHReserveBefore, WETHBalAfter, 0.01e8)

def test_harvest_reserve_ETH_manager_less_than_buffer():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(1, 100e8, {"from": env.proxy.owner()})

    WETHBalBefore = env.WETHToken.balanceOf(env.deployer)
    assert WETHBalBefore == 0

    env.treasury.transferReserveToTreasury([1], {"from": env.deployer})
    assert env.WETHToken.balanceOf(env.deployer) == 0

def test_harvest_reserve_multiple():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(1, 0.01e8, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(2, 10000e8, {"from": env.proxy.owner()})

    DAIBalBefore = env.DAIToken.balanceOf(env.deployer)
    assert DAIBalBefore == 0
    cDAIReserveBefore = env.proxy.getReserveBalance(2)

    WETHBalBefore = env.WETHToken.balanceOf(env.deployer)
    assert WETHBalBefore == 0
    cETHReserveBefore = env.proxy.getReserveBalance(1)
    env.treasury.transferReserveToTreasury([1, 2], {"from": env.deployer})

    DAIBalAfter = env.DAIToken.balanceOf(env.deployer)
    check_reserve_balances(env, 2, cDAIReserveBefore, DAIBalAfter, 10000e8)

    WETHBalAfter = env.WETHToken.balanceOf(env.deployer)
    check_reserve_balances(env, 1, cETHReserveBefore, WETHBalAfter, 0.01e8)

def test_harvest_reserve_multiple_invalid_order():
    env = create_environment()
    env.treasury.setTreasuryManager(env.deployer, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(1, 0.01e8, {"from": env.proxy.owner()})
    env.treasury.setReserveBuffer(2, 10000e8, {"from": env.proxy.owner()})
    with brownie.reverts():
       env.treasury.transferReserveToTreasury([2, 1], {"from": env.deployer})

def test_set_reserve_cash_balance_owner():
    env = create_environment()
    balanceBefore = env.proxy.getReserveBalance(2)
    env.treasury.setReserveCashBalance(2, balanceBefore / 2, {"from": env.proxy.owner()})
    balanceAfter = env.proxy.getReserveBalance(2)
    assert math.floor(balanceBefore / 2) == balanceAfter

def test_set_reserve_cash_balance_non_owner():
    env = create_environment()
    balanceBefore = env.proxy.getReserveBalance(2)
    with brownie.reverts():
        env.treasury.setReserveCashBalance(2, balanceBefore / 2, {"from": env.deployer})

def test_set_reserve_cash_balance_invalid_currency():
    env = create_environment()
    balanceBefore = env.proxy.getReserveBalance(2)
    with brownie.reverts():
        env.treasury.setReserveCashBalance(10, balanceBefore / 2, {"from": env.proxy.owner()})

def test_set_reserve_cash_balance_invalid_amount():
    env = create_environment()
    balanceBefore = env.proxy.getReserveBalance(2)
    with brownie.reverts():
        env.treasury.setReserveCashBalance(2, balanceBefore * 2, {"from": env.proxy.owner()})



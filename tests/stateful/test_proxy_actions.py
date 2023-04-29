import brownie
import pytest
from brownie import nBeaconProxy, Contract, EmptyProxy, PrimeCashProxy
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.helpers import initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()

@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    env = initialize_environment(accounts)
    env.notional.depositUnderlyingToken(accounts[0], 1, 100e18, {"value": 100e18, "from": accounts[0]})
    return env

@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

def getProxy(environment, useNToken):
    if useNToken:
        return environment.nToken[1]
    else:
        return Contract.from_abi('pETH', environment.notional.pCashAddress(1), PrimeCashProxy.abi)

@given(useNToken=strategy("bool"))
def test_cannot_emit_unless_notional(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)

    with brownie.reverts("Unauthorized"):
        proxy.emitTransfer(accounts[1], accounts[2], 100e8, {"from": accounts[1]})

    with brownie.reverts("Unauthorized"):
        proxy.emitMintOrBurn(accounts[1], 100e8, {"from": accounts[1]})

    with brownie.reverts("Unauthorized"):
        proxy.emitMintTransferBurn(accounts[1], accounts[1], 100e8, 100e8, {"from": accounts[1]})

    with brownie.reverts("Unauthorized"):
        proxy.emitfCashTradeTransfers(accounts[1], accounts[2], 100e8, 10e8, {"from": accounts[1]})
    
    txn = proxy.emitTransfer(accounts[1], accounts[2], 100e8, {"from": environment.notional})
    assert 'Transfer' in txn.events

@given(useNToken=strategy("bool"))
def test_cannot_reinitialize_proxy(environment, useNToken, accounts):
    proxy = getProxy(environment, useNToken)
    with brownie.reverts():
        proxy.initialize(2, proxy.address, "test", "test", {"from": accounts[0]})

    beacon = Contract.from_abi('beacon', proxy.address, nBeaconProxy.abi)
    impl = Contract.from_abi('impl', beacon.getImplementation(), PrimeCashProxy.abi)

    # Also cannot call initialize on the implementation
    with brownie.reverts("Unauthorized"):
        impl.initialize(2, proxy.address, "test", "test", {"from": accounts[0]})

    with brownie.reverts("Initializable: contract is already initialized"):
        impl.initialize(2, proxy.address, "test", "test", {"from": environment.notional})

@given(useNToken=strategy("bool"))
def test_upgrade_pcash_proxy(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)
    emptyImpl = EmptyProxy.deploy(accounts[0], {"from": accounts[0]})

    proxyEnum = 0 if useNToken else 1
    with brownie.reverts():
        environment.notional.upgradeBeacon(proxyEnum, emptyImpl, {"from": accounts[1]})

    txn = environment.notional.upgradeBeacon(proxyEnum, emptyImpl, {"from": environment.notional.owner()})
    assert txn.events['Upgraded']['implementation'] == emptyImpl.address

    # this method no longer exists
    with brownie.reverts():
        proxy.balanceOf(accounts[0])

    # Other proxy is unaffected
    assert getProxy(environment, not useNToken).balanceOf(accounts[1]) == 0

def test_cannot_call_proxy_actions_directly(environment, accounts):
    with brownie.reverts():
        environment.notional.nTokenTransferApprove(
            1, accounts[2], accounts[1], 2 ** 255, {"from": accounts[1]}
        )

    with brownie.reverts():
        environment.notional.pCashTransferApprove(
            1, accounts[2], accounts[1], 2 ** 255, {"from": accounts[1]}
        )

    with brownie.reverts():
        environment.notional.nTokenTransfer(
            1, accounts[2], accounts[1], 100e8, {"from": accounts[1]}
        )

    with brownie.reverts():
        environment.notional.pCashTransfer(
            1, accounts[2], accounts[1], 100e8, {"from": accounts[1]}
        )

    with brownie.reverts():
        environment.notional.nTokenTransferFrom(
            1, accounts[2], accounts[1], accounts[0], 100e8, {"from": accounts[1]}
        )

    with brownie.reverts():
        environment.notional.pCashTransferFrom(
            1, accounts[2], accounts[1], accounts[0], 100e8, {"from": accounts[1]}
        )

@given(useNToken=strategy("bool"))
def test_transfer_self_failure(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)

    with brownie.reverts():
        proxy.transfer(accounts[0], 1, {"from": accounts[0]})

    with brownie.reverts():
        proxy.transferFrom(accounts[0], accounts[0], 1, {"from": accounts[0]})

@given(useNToken=strategy("bool"))
def test_cannot_transfer_to_system_account(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)
    with brownie.reverts():
        proxy.transfer(environment.notional.address, 1e8, {"from": accounts[0]})

@given(useNToken=strategy("bool"))
def test_set_transfer_allowance(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)
    proxy.approve(accounts[1], 100e8, {"from": accounts[0]})
    assert proxy.allowance(accounts[0], accounts[1]) == 100e8

    with brownie.reverts("Insufficient allowance"):
        proxy.transferFrom(accounts[0], accounts[2], 101e8, {"from": accounts[1]})

    proxy.transferFrom(accounts[0], accounts[2], 100e8, {"from": accounts[1]})
    assert proxy.allowance(accounts[0], accounts[1]) == 0
    assert proxy.balanceOf(accounts[2]) == 100e8

@given(useNToken=strategy("bool"))
def test_transfer_tokens(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)
    balance = proxy.balanceOf(accounts[0])

    if useNToken:
        with brownie.reverts("Neg nToken"):
            proxy.transfer(accounts[1], balance + 1, {"from": accounts[0]})
    else:
        with brownie.reverts("Insufficient balance"):
            proxy.transfer(accounts[1], balance + 1, {"from": accounts[0]})

    proxy.transfer(accounts[2], 100e8, {"from": accounts[0]})
    assert proxy.balanceOf(accounts[2]) == 100e8

def test_cannot_transfer_and_incur_debt(environment, accounts):
    # only applies to pCash
    proxy = getProxy(environment, False)

    balance = proxy.balanceOf(accounts[0])
    environment.notional.enablePrimeBorrow(True, {"from": accounts[0]})
    environment.notional.withdraw(1, balance + 5e8, True, {"from": accounts[0]})

    assert pytest.approx(environment.notional.getAccountBalance(1, accounts[0])['cashBalance'], abs=1000) == -5e8
    assert proxy.balanceOf(accounts[0]) == 0

    # Reverts because balance is negative
    with brownie.reverts("Insufficient balance"):
        proxy.transfer(accounts[1],  1e8, {"from": accounts[0]})

@given(useNToken=strategy("bool"))
def test_transfer_negative_fc_failure(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)
    proxy.transfer(accounts[2], 5000e8, {"from": accounts[0]})

    environment.notional.enablePrimeBorrow(True, {"from": accounts[2]})
    # Now we have some debt
    environment.notional.withdraw(2, 5000e8, True, {"from": accounts[2]})

    with brownie.reverts("Insufficient free collateral"):
        proxy.transfer(accounts[0], 5000e8, {"from": accounts[2]})

    # Does allow a smaller transfer
    proxy.transfer(accounts[0], 500e8, {"from": accounts[2]})

@given(useNToken=strategy("bool"))
def test_total_supply_and_value(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)
    totalSupply = proxy.totalSupply()
    totalAssets = proxy.totalAssets()

    if useNToken:
        assert totalSupply == environment.notional.getNTokenAccount(proxy.address)['totalSupply']
        assert totalAssets == environment.notional.nTokenPresentValueUnderlyingDenominated(proxy.currencyId()) * 1e18 / 1e8
    else:
        (_, factors, _, totalUnderlying) = environment.notional.getPrimeFactors(proxy.currencyId(), chain.time())
        assert totalSupply == factors['totalPrimeSupply']
        assert pytest.approx(totalAssets, abs=5) == totalUnderlying * 1e18 / 1e8


@given(useNToken=strategy("bool"))
def test_erc4626_convert_to_shares_and_assets(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)
    shares = proxy.convertToShares(1e18)
    assets = proxy.convertToAssets(shares)

    assert assets == 1e18
    assert proxy.previewDeposit(assets) == shares
    assert proxy.previewMint(shares) == assets

@given(useNToken=strategy("bool"))
def test_transfer_above_supply_cap(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)
    (_, factors, _, _) = environment.notional.getPrimeFactors(proxy.currencyId(), chain.time())
    environment.notional.setMaxUnderlyingSupply(1, factors['lastTotalUnderlyingValue'] - 100e8)
    
    # Assert cap is in effect
    with brownie.reverts("Over Supply Cap"):
        environment.notional.depositUnderlyingToken(accounts[0], 1, 100e18, {"value": 100e18, "from": accounts[0]})

    # Can still transfer above cap
    proxy.transfer(accounts[2], 100e8, {"from": accounts[0]})

@given(useNToken=strategy("bool"))
def test_max_mint_and_deposit_respects_supply_cap(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)

    # No cap means unlimited mint
    assert proxy.maxDeposit(accounts[0]) == 2 ** 256 - 1
    assert proxy.maxMint(accounts[0]) == 2 ** 256 - 1

    (_, factors, _, _) = environment.notional.getPrimeFactors(proxy.currencyId(), chain.time())
    environment.notional.setMaxUnderlyingSupply(1, factors['lastTotalUnderlyingValue'])

    assert proxy.maxDeposit(accounts[0]) == 0
    assert proxy.maxMint(accounts[0]) == 0

    cap = factors['lastTotalUnderlyingValue'] + 100e8
    environment.notional.setMaxUnderlyingSupply(1, cap)

    assert pytest.approx(proxy.maxDeposit(accounts[0]), rel=1e-6) == 100e18
    assert pytest.approx(proxy.maxMint(accounts[0]), rel=1e-6) == 5000e8

@given(useNToken=strategy("bool"))
def test_max_redeem_and_withdraw_respects_balance(environment, accounts, useNToken):
    proxy = getProxy(environment, useNToken)

    assert proxy.maxWithdraw(accounts[0]) == proxy.convertToAssets(proxy.balanceOf(accounts[0]))
    assert proxy.maxRedeem(accounts[0]) == proxy.balanceOf(accounts[0])

    assert proxy.maxWithdraw(accounts[1]) == 0
    assert proxy.maxRedeem(accounts[1]) == 0

### Above here

def test_mint(environment, accounts):
    pass

def test_deposit(environment, accounts):
    pass

@given(useSender=strategy("bool"))
def test_redeem(environment, accounts, useSender):
    pass

@given(useSender=strategy("bool"))
def test_withdraw(environment, accounts, useSender):
    pass
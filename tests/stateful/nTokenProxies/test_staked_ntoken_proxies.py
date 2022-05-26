import brownie
import pytest
from brownie import Contract, StakedNTokenERC20Proxy
from brownie.network import Chain
from tests.constants import SECONDS_IN_DAY
from tests.helpers import active_currencies_to_list, initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(scope="module", autouse=False)
def snDAI(environment, accounts):
    environment.notional.enableStakedNToken(
        2, 100_000, "DAI Stablecoin", "DAI", {"from": accounts[0]}
    )
    address = environment.notional.StakedNTokenAddress(2)
    return Contract.from_abi("snDAI", address, abi=StakedNTokenERC20Proxy.abi)


@pytest.fixture(scope="module", autouse=True)
def DAI(environment):
    return environment.token["DAI"]


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_can_enable_proxy(environment, accounts):
    with brownie.reverts():
        # Does not pass authentication
        environment.notional.enableStakedNToken(
            2, 100_000, "DAI Stablecoin", "DAI", {"from": accounts[1]}
        )

    # Enabled
    environment.notional.enableStakedNToken(
        2, 100_000, "DAI Stablecoin", "DAI", {"from": accounts[0]}
    )
    address = environment.notional.StakedNTokenAddress(2)
    snDAI = Contract.from_abi("snDAI", address, abi=StakedNTokenERC20Proxy.abi)

    assert snDAI.totalSupply() == 0

    with brownie.reverts("dev: cannot reset ntoken address"):
        # Does not pass authentication
        environment.notional.enableStakedNToken(
            2, 100_000, "DAI Stablecoin", "DAI", {"from": accounts[0]}
        )


def test_can_upgrade_proxy(environment, accounts, EmptyProxy):
    environment.notional.enableStakedNToken(
        2, 100_000, "DAI Stablecoin", "DAI", {"from": accounts[0]}
    )
    address = environment.notional.StakedNTokenAddress(2)
    snDAI = Contract.from_abi("snDAI", address, abi=StakedNTokenERC20Proxy.abi)
    assert snDAI.totalSupply() == 0

    emptyProxy = EmptyProxy.deploy({"from": accounts[0]})
    with brownie.reverts():
        # Not owner
        environment.notional.upgradeStakedNTokenBeacon(emptyProxy.address, {"from": accounts[1]})
    environment.notional.upgradeStakedNTokenBeacon(emptyProxy.address, {"from": accounts[0]})

    with brownie.reverts():
        # Now reverts due to empty proxy
        snDAI.totalSupply()


def test_mint_staked_ntokens_via_erc4626(environment, accounts, snDAI, DAI):
    DAI.approve(snDAI.address, 2 ** 255 - 1, {"from": accounts[1]})
    assets = snDAI.previewMint(100e8)

    balanceBefore = DAI.balanceOf(accounts[1])
    snDAI.mint(100e8, accounts[1], {"from": accounts[1]})
    balanceAfter = DAI.balanceOf(accounts[1])
    assert (balanceBefore - balanceAfter) == assets
    assert snDAI.balanceOf(accounts[1]) == 100e8
    assert DAI.balanceOf(snDAI.address) == 0

    (accountContext, _, _) = environment.notional.getAccount(accounts[1])
    activeCurrenciesList = active_currencies_to_list(accountContext[4])
    assert len(activeCurrenciesList) == 0

    check_system_invariants(environment, accounts)


def test_deposit_staked_ntokens_via_erc4626(environment, accounts, snDAI, DAI):
    DAI.approve(snDAI.address, 2 ** 255 - 1, {"from": accounts[1]})
    shares = snDAI.previewDeposit(100e18)

    balanceBefore = DAI.balanceOf(accounts[1])
    snDAI.deposit(100e18, accounts[1], {"from": accounts[1]})
    balanceAfter = DAI.balanceOf(accounts[1])
    assert (balanceBefore - balanceAfter) == 100e18
    assert snDAI.balanceOf(accounts[1]) == shares
    assert DAI.balanceOf(snDAI.address) == 0

    (accountContext, _, _) = environment.notional.getAccount(accounts[1])
    activeCurrenciesList = active_currencies_to_list(accountContext[4])
    assert len(activeCurrenciesList) == 0

    check_system_invariants(environment, accounts)


def test_redeem_staked_ntokens_via_erc4626(environment, accounts, snDAI, DAI):
    DAI.approve(snDAI.address, 2 ** 255 - 1, {"from": accounts[1]})
    snDAI.deposit(100e18, accounts[1], {"from": accounts[1]})
    chain.mine(1, timedelta=65 * SECONDS_IN_DAY)

    with brownie.reverts("Cannot Unstake"):
        snDAI.redeem(snDAI.balanceOf(accounts[1]), accounts[1], accounts[1], {"from": accounts[1]})

    unstakeAmount = snDAI.balanceOf(accounts[1])
    snDAI.signalUnstake(unstakeAmount, {"from": accounts[1]})
    assert snDAI.balanceOf(accounts[1]) == unstakeAmount

    chain.mine(1, timedelta=25 * SECONDS_IN_DAY)
    environment.notional.initializeMarkets(2, False, {"from": accounts[0]})
    chain.mine(1, timedelta=2 * SECONDS_IN_DAY)

    balanceBefore = DAI.balanceOf(accounts[1])
    snDAI.redeem(unstakeAmount, accounts[1], accounts[1], {"from": accounts[1]})
    balanceAfter = DAI.balanceOf(accounts[1])

    assert (balanceAfter - balanceBefore) == 100e18
    assert snDAI.balanceOf(accounts[1]) == 0
    assert DAI.balanceOf(snDAI.address) == 0

    check_system_invariants(environment, accounts)


def test_withdraw_staked_ntokens_via_erc4626(environment, accounts, snDAI, DAI):
    DAI.approve(snDAI.address, 2 ** 255 - 1, {"from": accounts[1]})
    snDAI.deposit(100e18, accounts[1], {"from": accounts[1]})
    chain.mine(1, timedelta=65 * SECONDS_IN_DAY)

    with brownie.reverts("Cannot Unstake"):
        snDAI.redeem(snDAI.balanceOf(accounts[1]), accounts[1], accounts[1], {"from": accounts[1]})

    unstakeAmount = snDAI.balanceOf(accounts[1])
    snDAI.signalUnstake(unstakeAmount, {"from": accounts[1]})
    assert snDAI.balanceOf(accounts[1]) == unstakeAmount

    chain.mine(1, timedelta=25 * SECONDS_IN_DAY)
    environment.notional.initializeMarkets(2, False, {"from": accounts[0]})
    chain.mine(1, timedelta=2 * SECONDS_IN_DAY)

    # Assert that balanceOf has not changed
    assert snDAI.balanceOf(accounts[1]) == unstakeAmount
    balanceBefore = DAI.balanceOf(accounts[1])
    snDAI.withdraw(100e18, accounts[1], accounts[1], {"from": accounts[1]})
    balanceAfter = DAI.balanceOf(accounts[1])

    assert (balanceAfter - balanceBefore) == 100e18
    assert snDAI.balanceOf(accounts[1]) == 0
    assert DAI.balanceOf(snDAI.address) == 0

    check_system_invariants(environment, accounts)


def test_redeem_allowance_staked_ntokens_via_erc4626(environment, accounts, snDAI, DAI):
    DAI.approve(snDAI.address, 2 ** 255 - 1, {"from": accounts[1]})
    snDAI.deposit(100e18, accounts[1], {"from": accounts[1]})
    chain.mine(1, timedelta=65 * SECONDS_IN_DAY)

    unstakeAmount = snDAI.balanceOf(accounts[1])
    snDAI.signalUnstake(unstakeAmount, {"from": accounts[1]})

    chain.mine(1, timedelta=25 * SECONDS_IN_DAY)
    environment.notional.initializeMarkets(2, False, {"from": accounts[0]})
    chain.mine(1, timedelta=2 * SECONDS_IN_DAY)

    with brownie.reverts("Insufficient Allowance"):
        snDAI.redeem(unstakeAmount, accounts[2], accounts[1], {"from": accounts[3]})

    with brownie.reverts("Insufficient Allowance"):
        snDAI.withdraw(50e18, accounts[2], accounts[1], {"from": accounts[3]})

    snDAI.approve(accounts[3], 3000e8, {"from": accounts[1]})

    with brownie.reverts("Insufficient Allowance"):
        snDAI.redeem(unstakeAmount, accounts[2], accounts[1], {"from": accounts[3]})

    with brownie.reverts("Insufficient Allowance"):
        snDAI.withdraw(100e18, accounts[2], accounts[1], {"from": accounts[3]})

    balanceBefore = DAI.balanceOf(accounts[2])
    snDAI.redeem(2000e8, accounts[2], accounts[1], {"from": accounts[3]})
    sharesWithdrawn = snDAI.previewWithdraw(10e18)
    snDAI.withdraw(10e18, accounts[2], accounts[1], {"from": accounts[3]})
    balanceAfter = DAI.balanceOf(accounts[2])

    assert snDAI.allowance(accounts[1], accounts[3]) == 3000e8 - sharesWithdrawn - 2000e8
    assert pytest.approx(balanceAfter - balanceBefore, abs=1e11) == 50e18
    assert snDAI.balanceOf(accounts[1]) == 5000e8 - sharesWithdrawn - 2000e8
    assert DAI.balanceOf(snDAI.address) == 0

    check_system_invariants(environment, accounts)


def test_balance_of_loses_deposit(environment, accounts, snDAI, DAI):
    DAI.approve(snDAI.address, 2 ** 255 - 1, {"from": accounts[1]})
    snDAI.deposit(200e18, accounts[1], {"from": accounts[1]})
    chain.mine(1, timedelta=65 * SECONDS_IN_DAY)

    balanceBefore = snDAI.balanceOf(accounts[1])
    snDAI.signalUnstake(balanceBefore / 2, {"from": accounts[1]})
    assert snDAI.balanceOf(accounts[1]) == balanceBefore

    chain.mine(1, timedelta=25 * SECONDS_IN_DAY)
    environment.notional.initializeMarkets(2, False, {"from": accounts[0]})
    chain.mine(1, timedelta=2 * SECONDS_IN_DAY)

    # Still no change to balance of during unstake window
    assert snDAI.balanceOf(accounts[1]) == balanceBefore

    chain.mine(1, timedelta=6 * SECONDS_IN_DAY)

    # Now they should lose the deposit amount of 25 basis points (50% of the balance was signalled)
    assert (balanceBefore - snDAI.balanceOf(accounts[1])) / balanceBefore == 0.0025

    check_system_invariants(environment, accounts)


# def test_mint_staked_neth_via_erc4626()
# def test_deposit_staked_neth_via_erc4626()
# def test_redeem_staked_neth_via_erc4626()
# def test_withdraw_staked_neth_via_erc4626()

# def test_mint_staked_non_mintable_via_erc4626()
# def test_deposit_staked_non_mintable_via_erc4626()
# def test_redeem_staked_non_mintable_via_erc4626()
# def test_withdraw_staked_non_mintable_via_erc4626()

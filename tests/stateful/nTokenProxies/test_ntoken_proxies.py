import brownie
import pytest
from brownie.network.state import Chain
from tests.helpers import active_currencies_to_list, initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_can_upgrade_proxy(environment, accounts, EmptyProxy):
    emptyProxy = EmptyProxy.deploy({"from": accounts[0]})

    with brownie.reverts():
        # Not Owner
        environment.notional.upgradeNTokenBeacon(emptyProxy.address, {"from": accounts[1]})

    environment.notional.upgradeNTokenBeacon(emptyProxy.address, {"from": accounts[0]})

    with brownie.reverts():
        # These methods should start to revert since the ERC20 implementation is now empty
        environment.nToken[1].balanceOf(accounts[0])


@pytest.mark.only
def test_mint_ntokens_via_erc4626(environment, accounts):
    nDAI = environment.nToken[2]
    DAI = environment.token["DAI"]
    assert DAI.address == nDAI.asset()

    DAI.approve(nDAI.address, 2 ** 255 - 1, {"from": accounts[1]})
    assets = nDAI.previewMint(100e8)

    balanceBefore = DAI.balanceOf(accounts[1])
    nDAI.mint(100e8, accounts[1], {"from": accounts[1]})
    balanceAfter = DAI.balanceOf(accounts[1])

    assert (balanceBefore - balanceAfter) == assets
    assert DAI.balanceOf(nDAI.address) == 0
    (accountContext, accountBalances, portfolio) = environment.notional.getAccount(accounts[1])
    activeCurrenciesList = active_currencies_to_list(accountContext[4])
    assert len(activeCurrenciesList) == 1
    assert activeCurrenciesList[0] == (2, False, True)
    assert accountBalances[0][0] == 2
    assert accountBalances[0][1] == 0
    assert accountBalances[0][2] == 100e8

    check_system_invariants(environment, accounts)


# def test_deposit_ntokens_via_erc4626()
# def test_redeem_ntokens_via_erc4626()
# def test_withdraw_ntokens_via_erc4626()

# def test_mint_eth_ntokens_via_erc4626()
# def test_deposit_eth_ntokens_via_erc4626()
# def test_redeem_eth_ntokens_via_erc4626()
# def test_withdraw_eth_ntokens_via_erc4626()

# def test_mint_non_mintable_ntokens_via_erc4626()
# def test_deposit_non_mintable_ntokens_via_erc4626()
# def test_redeem_non_mintable_ntokens_via_erc4626()
# def test_withdraw_non_mintable_ntokens_via_erc4626()

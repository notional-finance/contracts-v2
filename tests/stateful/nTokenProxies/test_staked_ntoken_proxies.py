import pytest
from tests.helpers import initialize_environment


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


# def test_can_upgrade_proxy()
# def test_can_enable_proxy()
# def test_mint_staked_ntokens_via_erc4626()
# def test_deposit_staked_ntokens_via_erc4626()
# def test_redeem_staked_ntokens_via_erc4626()
# def test_withdraw_staked_ntokens_via_erc4626()

# def test_mint_staked_neth_via_erc4626()
# def test_deposit_staked_neth_via_erc4626()
# def test_redeem_staked_neth_via_erc4626()
# def test_withdraw_staked_neth_via_erc4626()

# def test_mint_staked_non_mintable_via_erc4626()
# def test_deposit_staked_non_mintable_via_erc4626()
# def test_redeem_staked_non_mintable_via_erc4626()
# def test_withdraw_staked_non_mintable_via_erc4626()

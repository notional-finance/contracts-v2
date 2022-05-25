import pytest
from tests.helpers import initialize_environment


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


# def test_stake_ntoken_via_transfer()
# def test_stake_ntoken_via_transfer_undercollateralized()
# def test_deposit_asset_and_mint_stake_ntoken()
# def test_deposit_underlying_and_mint_stake_ntoken()
# def test_convert_cash_and_mint_stake_ntoken()
# def test_convert_cash_and_mint_stake_ntoken_undercollateralized()
# def test_unstake_to_ntoken()
# def test_unstake_and_redeem_to_ntoken()
# def test_claim_incentives()

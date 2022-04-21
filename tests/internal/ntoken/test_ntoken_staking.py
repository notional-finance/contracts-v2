import brownie
import pytest
from brownie.network import Chain
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF

chain = Chain()
# from brownie.convert.datatypes import Wei
# from brownie.test import given, strategy


@pytest.fixture(scope="module", autouse=True)
def run_around_tests(StakedNToken, accounts):
    yield
    check_invariants(StakedNToken, accounts)


@pytest.fixture(scope="module", autouse=True)
def StakedNToken(MockNTokenStaked, nTokenMintAction, nTokenRedeemAction, accounts):
    nTokenMintAction.deploy({"from": accounts[0]})
    nTokenRedeemAction.deploy({"from": accounts[0]})
    mock = MockNTokenStaked.deploy({"from": accounts[0]})
    chain.mine(1, START_TIME_TREF)
    return mock


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def check_invariants(StakedNToken, accounts):
    # This should never be set
    zeroMaturity = StakedNToken.getStakedMaturityIncentive(1, 0)
    assert zeroMaturity == (0, 0, 0, 0)

    # Check some reasonable range of dates
    stakedSupply = StakedNToken.getStakedNTokenSupply(1).dict()
    totalTermSupply = 0
    for i in range(-4, 12):
        m = StakedNToken.getStakedMaturityIncentive(
            1, START_TIME_TREF + i * SECONDS_IN_QUARTER
        ).dict()
        totalTermSupply += m["termStakedSupply"]

        # Last accumulated time is never greater than unstake maturity
        assert m["lastAccumulatedTime"] <= START_TIME_TREF + i * SECONDS_IN_QUARTER

    # Sum of all term supply equals total supply (this might not always be true b/c transfers)
    assert stakedSupply["totalSupply"] == totalTermSupply

    # Sum of all stakers equals total supply
    totalStakerSupply = 0
    for a in accounts:
        m = StakedNToken.getNTokenStaker(a.address, 1).dict()
        totalStakerSupply += m["stakedNTokenBalance"]
    assert totalStakerSupply == stakedSupply["totalSupply"]

    # Last accumulated time on all active terms is equal
    activeTerms = StakedNToken.getStakedMaturityIncentivesFromRef(1, START_TIME_TREF)
    lastAccumulatedTimeSet = set([t[3] for t in activeTerms])
    assert len(lastAccumulatedTimeSet) == 1
    assert lastAccumulatedTimeSet.pop() != 0

    # TODO: is there anything to assert over accumulated note?


def test_fail_staking_maturity_before_blocktime(StakedNToken, accounts):
    with brownie.reverts("Invalid Maturity"):
        # Previous quarter
        StakedNToken.stakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF - SECONDS_IN_QUARTER, START_TIME_TREF + 100
        )

        # Current Tref
        StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF, START_TIME_TREF + 100)

        # Current Tref Equal
        StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF, START_TIME_TREF)


def test_staking_maturity_must_be_longer(StakedNToken, accounts):
    # Staked to a future maturity
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + 3 * SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    # Cannot shorten unstake maturity
    with brownie.reverts("Invalid Maturity"):
        StakedNToken.stakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + 1 * SECONDS_IN_QUARTER, START_TIME_TREF + 110
        )

        StakedNToken.stakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + 2 * SECONDS_IN_QUARTER, START_TIME_TREF + 110
        )


def test_cannot_stake_past_max_terms(StakedNToken, accounts):
    with brownie.reverts("Invalid Maturity"):
        StakedNToken.stakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + 5 * SECONDS_IN_QUARTER, START_TIME_TREF + 100
        )


def test_staking_maturity_not_quarter_alignment(StakedNToken, accounts):
    with brownie.reverts("Invalid Maturity"):
        # Future maturity but not on quarter alignment
        StakedNToken.stakeNToken(
            accounts[0],
            1,
            100e8,
            START_TIME_TREF + SECONDS_IN_QUARTER * 86400,
            START_TIME_TREF + 110,
        )


def test_stake_ntoken(StakedNToken, accounts):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )


# def test_ntoken_claim_doesnt_increase()
# def test_note_incentives_are_deterministic()
# def test_no_dilution_of_previous_incentives()
# def test_longer_terms_always_have_higher_incentives()
# def test_unstaking_during_window()
# def test_unstaking_outside_window()
# def test_unstaking_with_maturity_in_previous_quarter()
# def test_unstaking_with_maturity_in_future_quarter()
# def test_unstaking_insufficient_balance()

# def test_paying_fees_increases_stake()
# def test_paying_fees_accumulates_note()
# def test_redeem_ntokens_for_shortfall()
# def test_redeem_ntokens_for_shortfall_to_zero()

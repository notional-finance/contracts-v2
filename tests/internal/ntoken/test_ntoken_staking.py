from collections import defaultdict

import brownie
import pytest
from brownie.network import Chain
from brownie.test import given, strategy
from tests.constants import SECONDS_IN_DAY, SECONDS_IN_QUARTER, START_TIME_TREF
from tests.helpers import get_tref

# from brownie.convert.datatypes import Wei

chain = Chain()


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


def check_invariants(StakedNToken, accounts, blockTime, prevIncentiveAccumulator=None):
    tRef = get_tref(blockTime)
    # This should never be set
    zeroMaturity = StakedNToken.getStakedMaturityIncentive(1, 0)
    assert zeroMaturity == (0, 0, 0, 0)
    incentiveAccumulators = {
        "accountIncentiveDebt": defaultdict(lambda: 0),
        "accumulatedNOTE": defaultdict(lambda: 0),
        "stakedSupply": defaultdict(lambda: 0),
        "termLastAccumulatedTime": defaultdict(lambda: 0),
        "termAccumulatedNOTEPerStaked": defaultdict(lambda: 0),
    }

    # Check some reasonable range of dates
    stakedSupply = StakedNToken.getStakedNTokenSupply(1).dict()
    incentiveAccumulators["baseAccumulatedNOTEPerStaked"] = stakedSupply[
        "baseAccumulatedNOTEPerStaked"
    ]
    incentiveAccumulators["lastBaseAccumulatedNOTEPerNToken"] = stakedSupply[
        "lastBaseAccumulatedNOTEPerNToken"
    ]

    if prevIncentiveAccumulator:
        assert (
            stakedSupply["baseAccumulatedNOTEPerStaked"]
            >= prevIncentiveAccumulator["baseAccumulatedNOTEPerStaked"]
        )
        assert (
            stakedSupply["lastBaseAccumulatedNOTEPerNToken"]
            >= prevIncentiveAccumulator["lastBaseAccumulatedNOTEPerNToken"]
        )

    # Sum of all stakers equals total supply
    totalStakerSupply = 0
    termSupplyCalc = defaultdict(lambda: 0)
    for a in accounts:
        m = StakedNToken.getNTokenStaker(a.address, 1).dict()
        totalStakerSupply += m["stakedNTokenBalance"]

        # Sum up the per term supply
        termSupplyCalc[m["unstakeMaturity"]] += m["stakedNTokenBalance"]
        incentiveAccumulators["accountIncentiveDebt"][a.address] = m["accountIncentiveDebt"]
        incentiveAccumulators["accumulatedNOTE"][a.address] = m["accumulatedNOTE"]

        if prevIncentiveAccumulator:
            # If the staked supply has changed then accumulators must increase
            if prevIncentiveAccumulator["stakedSupply"][a.address] != m["stakedNTokenSupply"]:
                assert (
                    m["accountIncentiveDebt"]
                    > prevIncentiveAccumulator["accountIncentiveDebt"][a.address]
                )
                assert m["accumulatedNOTE"] > prevIncentiveAccumulator["accumulatedNOTE"][a.address]
            else:
                assert (
                    m["accountIncentiveDebt"]
                    == prevIncentiveAccumulator["accountIncentiveDebt"][a.address]
                )
                assert (
                    m["accumulatedNOTE"] == prevIncentiveAccumulator["accumulatedNOTE"][a.address]
                )

    assert totalStakerSupply == stakedSupply["totalSupply"]

    for i in range(-4, 12):
        m = StakedNToken.getStakedMaturityIncentive(1, tRef + i * SECONDS_IN_QUARTER).dict()
        if blockTime >= m["unstakeMaturity"]:
            # Last accumulated time goes up to maturity and never over
            assert m["lastAccumulatedTime"] == m["unstakeMaturity"] or m["lastAccumulatedTime"] == 0
        else:
            assert m["lastAccumulatedTime"] == blockTime or m["termStakedSupply"] == 0

        incentiveAccumulators["termAccumulatedNOTEPerStaked"][m["unstakeMaturity"]] = m[
            "termAccumulatedNOTEPerStaked"
        ]
        if prevIncentiveAccumulator:
            assert (
                m["termAccumulatedNOTEPerStaked"]
                > prevIncentiveAccumulator["termAccumulatedNOTEPerStaked"][m["unstakeMaturity"]]
            )

    # Last accumulated time on all active terms is equal
    activeTerms = StakedNToken.getStakedMaturityIncentivesFromRef(1, tRef)
    lastAccumulatedTimeSet = set([t[3] for t in activeTerms])
    assert len(lastAccumulatedTimeSet) == 1
    assert lastAccumulatedTimeSet.pop() != 0

    for (i, term) in enumerate(activeTerms):
        # Assert that each active term has the correct total supply
        assert termSupplyCalc[term[0]] == term[2]
        if i > 0:
            # longer termAccumulatedNOTEPerStaked is always greater than the previous
            # activeTerm
            assert activeTerms[i - 1][1] < term[1] or term[1] == 0


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


def test_unstaking_outside_window(StakedNToken, accounts):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    # Cannot unstake outside the window
    with brownie.reverts("Invalid unstake time"):
        StakedNToken.unstakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER + 7 * SECONDS_IN_DAY + 1
        )

        StakedNToken.unstakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER + 8 * SECONDS_IN_DAY
        )


def test_unstaking_with_maturity_in_future_quarter(StakedNToken, accounts):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + 3 * SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    # Cannot unstake until the quarter
    with brownie.reverts("Invalid unstake time"):
        StakedNToken.unstakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER)

        StakedNToken.unstakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + 2 * SECONDS_IN_QUARTER)


def test_unstaking_insufficient_balance(StakedNToken, accounts):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    with brownie.reverts():
        # More balance than the account has
        StakedNToken.unstakeNToken(accounts[0], 1, 200e8, START_TIME_TREF + SECONDS_IN_QUARTER + 1)

        # Account has no position at all
        StakedNToken.unstakeNToken(accounts[1], 1, 200e8, START_TIME_TREF + SECONDS_IN_QUARTER + 1)


@given(
    windowOffset=strategy("uint32", min_value=0, max_value=7 * SECONDS_IN_DAY),
    # Any reasonable time in a future quarter
    quarterOffset=strategy("uint32", min_value=2, max_value=8),
)
def test_unstaking_at_maturity(StakedNToken, accounts, quarterOffset, windowOffset):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    for i in range(1, quarterOffset):
        StakedNToken.updateAccumulatedNOTEIncentives(1, START_TIME_TREF + i * SECONDS_IN_QUARTER)

    # Unstaking is valid anytime during the 7 day staking window
    blockTime = START_TIME_TREF + quarterOffset * SECONDS_IN_QUARTER + windowOffset
    StakedNToken.unstakeNToken(accounts[0], 1, 100e8, blockTime)
    assert StakedNToken.getNTokenClaim(1, accounts[0].address) == 0
    assert StakedNToken.getNTokenStaker(accounts[0].address, 1).dict()["stakedNTokenBalance"] == 0

    check_invariants(StakedNToken, accounts, blockTime)


@given(initialStake=strategy("uint80"), secondStake=strategy("uint80"))
def test_stake_ntoken(StakedNToken, accounts, initialStake, secondStake):
    blockTime = START_TIME_TREF + 100
    StakedNToken.stakeNToken(
        accounts[0], 1, initialStake, START_TIME_TREF + SECONDS_IN_QUARTER, blockTime
    )
    assert initialStake == StakedNToken.getNTokenClaim(1, accounts[0].address)

    StakedNToken.stakeNToken(
        accounts[1], 1, secondStake, START_TIME_TREF + SECONDS_IN_QUARTER, blockTime
    )

    # Account 0 claim does not change
    assert initialStake == StakedNToken.getNTokenClaim(1, accounts[0].address)
    assert secondStake == StakedNToken.getNTokenClaim(1, accounts[1].address)

    check_invariants(StakedNToken, accounts, blockTime)


# def test_paying_fees_increases_stake()
# def test_redeem_ntokens_for_shortfall()
# def test_redeem_ntokens_for_shortfall_to_zero()


# def test_note_incentives_are_deterministic()
# def test_no_dilution_of_previous_incentives()
# def test_longer_terms_always_have_higher_incentives()
# def test_paying_fees_accumulates_note()

# def test_transfers()

"""
simulation:
    actions during quarter:
    stake
    pay fee
    redeem for shortfall
    transfer

    actions during window:
    stake
    redeem for shortfall
    unstake
    transfer

    # make this a separate test
    incentives over a year will equal totalAnnualTermEmission + underlyingEmissionRate
"""

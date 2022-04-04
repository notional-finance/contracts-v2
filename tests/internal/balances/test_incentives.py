import pytest
from brownie.convert import to_bytes
from brownie.convert.datatypes import HexString, Wei
from brownie.test import given, strategy
from tests.constants import SECONDS_IN_DAY, SECONDS_IN_YEAR, START_TIME
from tests.helpers import get_balance_state


@pytest.mark.balances
class TestIncentives:
    @pytest.fixture(scope="module", autouse=True)
    def incentives(self, MockIncentives, MigrateIncentives, accounts):
        MigrateIncentives.deploy({"from": accounts[0]})
        mock = MockIncentives.deploy({"from": accounts[0]})
        mock.setNTokenAddress(1, accounts[9])

        return mock

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_migrate_calculation(self, incentives, accounts):
        incentives.setEmissionRateDirect(accounts[9], 10_000)
        incentives.setDeprecatedStorageValues(accounts[9], 100_000e8, 1_000_000e8, START_TIME)
        incentives.migrateNToken(1, START_TIME + 20)

        (
            totalSupply,
            accumulatedNOTEPerNToken,
            lastAccumulatedTime,
        ) = incentives.getStoredNTokenSupplyFactors(accounts[9])
        assert totalSupply == 100_000e8
        assert accumulatedNOTEPerNToken == 0
        assert lastAccumulatedTime == START_TIME + 20

        (
            emissionRate,
            integralTotalSupply,
            migrationTime,
        ) = incentives.getDeprecatedNTokenSupplyFactors(accounts[9])

        assert emissionRate == 10_000
        assert integralTotalSupply == 3_000_000e8
        assert migrationTime == START_TIME + 20

        incentives.setEmissionRate(accounts[9], 50_000, START_TIME + 50)
        incentives.changeNTokenSupply(accounts[9], 100_000e8, START_TIME + 100)

        # Check that none of these values change
        (
            emissionRate,
            integralTotalSupply,
            migrationTime,
        ) = incentives.getDeprecatedNTokenSupplyFactors(accounts[9])

        assert emissionRate == 10_000
        assert integralTotalSupply == 3_000_000e8
        assert migrationTime == START_TIME + 20

    @given(nTokensMinted=strategy("uint", min_value=1e8, max_value=1e18))
    def test_new_account_under_new_calculation(self, incentives, nTokensMinted, accounts):
        incentives.changeNTokenSupply(accounts[9], 100_000e8, START_TIME)
        incentives.setEmissionRate(accounts[9], 50_000, START_TIME)

        balanceState = get_balance_state(
            1, storedNTokenBalance=0, netNTokenSupplyChange=nTokensMinted
        )

        (incentivesToClaim, balanceState_) = incentives.calculateIncentivesToClaim(
            accounts[9], balanceState, START_TIME + SECONDS_IN_DAY, nTokensMinted
        )

        assert incentivesToClaim == 0
        # Last Claim Time
        assert balanceState_[7] == 0
        # Accumulated Reward Debt as one day's worth of tokens
        assert pytest.approx(balanceState_[8], abs=10) == Wei(
            nTokensMinted * (50_000e8 / 360) / 100_000e8
        )

    @given(
        nTokensMinted=strategy("uint", min_value=1e8, max_value=1e18),
        timeSinceMigration=strategy("uint", min_value=0, max_value=SECONDS_IN_YEAR),
    )
    def test_migrate_account_to_new_calculation(
        self, incentives, nTokensMinted, timeSinceMigration, accounts
    ):
        incentives.setEmissionRateDirect(accounts[9], 10_000)
        incentives.setDeprecatedStorageValues(accounts[9], 100_000e8, 1_000_000e8, START_TIME)

        incentives.migrateNToken(1, START_TIME)

        balanceState = get_balance_state(
            1,
            storedNTokenBalance=nTokensMinted,
            netNTokenSupplyChange=nTokensMinted,
            lastClaimTime=(START_TIME - 86400),
            lastClaimSupply=950_000e8,
        )

        # Average Supply over the last day
        avgTotalSupply = Wei((1_000_000e8 - 950_000e8) / 86400)
        # Calculated incentives old will never change as time passes
        calculatedIncentivesOld = Wei(nTokensMinted * (10_000e8 / 360) / avgTotalSupply)
        calculatedIncentivesNew = Wei(
            Wei(
                nTokensMinted
                * Wei((10_000e8 * timeSinceMigration * 1e18) / SECONDS_IN_YEAR)
                / 100_000e8
            )
            / 1e18
        )
        calculatedIncentives = calculatedIncentivesNew + calculatedIncentivesOld

        (incentivesToClaim, balanceState_) = incentives.calculateIncentivesToClaim(
            accounts[9], balanceState, START_TIME + timeSinceMigration, nTokensMinted
        )

        assert pytest.approx(incentivesToClaim, rel=1e-10, abs=100) == Wei(calculatedIncentives)
        assert balanceState_[7] == 0
        assert pytest.approx(balanceState_[8], rel=1e-7, abs=10) == calculatedIncentivesNew

    @given(timeSinceMigration=strategy("uint", min_value=0, max_value=SECONDS_IN_YEAR))
    def test_no_dilution_of_previous_incentives(self, incentives, accounts, timeSinceMigration):
        incentives.changeNTokenSupply(accounts[9], 100_000e8, START_TIME)
        incentives.setEmissionRate(accounts[9], 50_000, START_TIME)

        balanceStateMinnow = get_balance_state(
            1, storedNTokenBalance=100e8, netNTokenSupplyChange=0
        )

        balanceStateWhale = get_balance_state(
            1, storedNTokenBalance=0, netNTokenSupplyChange=100_000_000e8
        )

        # Calculate claim of the minnow first
        (incentivesToClaimMinnow1, _) = incentives.calculateIncentivesToClaim(
            accounts[9], balanceStateMinnow, START_TIME + timeSinceMigration, 100e8
        )

        # Whale now mints a lot of tokens
        incentives.changeNTokenSupply(accounts[9], 100_000_000e8, START_TIME + timeSinceMigration)

        (incentivesToClaimMinnow2, _) = incentives.calculateIncentivesToClaim(
            accounts[9], balanceStateMinnow, START_TIME + timeSinceMigration, 100e8
        )

        # Assert that this has not changed
        assert incentivesToClaimMinnow1 == incentivesToClaimMinnow2

        (incentivesToClaimWhale, _) = incentives.calculateIncentivesToClaim(
            accounts[9], balanceStateWhale, START_TIME + timeSinceMigration, 100_000_000e8
        )
        assert incentivesToClaimWhale == 0

        # Ensure that these incentives are still accumulating
        (incentivesToClaimMinnow3, _) = incentives.calculateIncentivesToClaim(
            accounts[9], balanceStateMinnow, START_TIME + timeSinceMigration + 100, 100e8
        )
        assert incentivesToClaimMinnow3 > incentivesToClaimMinnow2

    def test_set_secondary_rewarder(self, incentives, MockSecondaryRewarder, accounts):
        zeroAddress = HexString(to_bytes(0, "bytes20"), "bytes20")
        secondaryRewarder = incentives.getSecondaryRewarder(accounts[9])
        assert secondaryRewarder == zeroAddress

        rewarder = MockSecondaryRewarder.deploy({"from": accounts[0]})
        incentives.setSecondaryRewarder(1, rewarder)

        secondaryRewarder = incentives.getSecondaryRewarder(accounts[9])
        assert secondaryRewarder == rewarder.address

        incentives.setSecondaryRewarder(1, zeroAddress)
        secondaryRewarder = incentives.getSecondaryRewarder(accounts[9])
        assert secondaryRewarder == zeroAddress

    def test_call_secondary_rewarder(self, incentives, MockSecondaryRewarder, accounts):
        incentives.changeNTokenSupply(accounts[9], 100_000e8, START_TIME)
        incentives.setEmissionRate(accounts[9], 0, START_TIME)

        rewarder = MockSecondaryRewarder.deploy({"from": accounts[0]})
        incentives.setSecondaryRewarder(1, rewarder)

        balanceState = get_balance_state(1, storedNTokenBalance=100e8, netNTokenSupplyChange=20e8)

        txn = incentives.claimIncentives(balanceState, accounts[2], 120e8)
        assert txn.events["ClaimRewards"]["account"] == accounts[2]
        assert txn.events["ClaimRewards"]["nTokenBalanceBefore"] == 100e8
        assert txn.events["ClaimRewards"]["nTokenBalanceAfter"] == 120e8
        assert txn.events["ClaimRewards"]["NOTETokensClaimed"] == 0

        zeroAddress = HexString(to_bytes(0, "bytes20"), "bytes20")
        incentives.setSecondaryRewarder(1, zeroAddress)
        txn = incentives.claimIncentives(balanceState, accounts[2], 120e8)
        assert "ClaimRewards" not in txn.events

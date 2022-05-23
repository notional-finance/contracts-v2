// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {Constants} from "../../../global/Constants.sol";
import {DateTime} from "../../markets/DateTime.sol";
import {
    nTokenStaker,
    nTokenStakerStorage,
    nTokenUnstakeSignalStorage,
    nTokenTotalUnstakeSignalStorage
} from "../../../global/Types.sol";
import {StakedNTokenSupply, StakedNTokenSupplyLib} from "./StakedNTokenSupply.sol";
import {LibStorage} from "../../../global/LibStorage.sol";
import {SafeInt256} from "../../../math/SafeInt256.sol";
import {SafeUint256} from "../../../math/SafeUint256.sol";

library nTokenStakerLib {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;

    /// @notice Returns an staked nToken account
    function getStaker(address account, uint16 currencyId) internal view returns (nTokenStaker memory staker) {
        mapping(address => mapping(uint256 => nTokenStakerStorage)) storage store = LibStorage.getNTokenStaker();
        nTokenStakerStorage storage s = store[account][currencyId];

        staker.snTokenBalance = s.snTokenBalance;
        staker.accountIncentiveDebt = s.accountIncentiveDebt;
        staker.accumulatedNOTE = s.accumulatedNOTE;
    }

    /**
     * @notice Updates a staker's balance and incentive counters and sets them in storage.
     * @param account the address of the staker
     * @param currencyId currency id of the nToken
     * @param netBalanceChange signed integer representing the direction of the balance change
     * @param totalAccumulatedNOTEPerStaked the result of the updateAccumulatedNOTEIncentives calculation
     */
    function updateStakerBalance(
        address account,
        uint16 currencyId,
        int256 netBalanceChange,
        uint256 totalAccumulatedNOTEPerStaked
    ) internal returns (uint256 snTokenBalance) {
        mapping(address => mapping(uint256 => nTokenStakerStorage)) storage store = LibStorage.getNTokenStaker();
        nTokenStakerStorage storage s = store[account][currencyId];

        // Read the values onto the stack
        snTokenBalance = s.snTokenBalance;
        uint256 accountIncentiveDebt = s.accountIncentiveDebt;
        uint256 accumulatedNOTE = s.accumulatedNOTE;

        // This is the additional incentives accumulated before any net change to the balance
        accumulatedNOTE = accumulatedNOTE.add(
            snTokenBalance
                .mul(totalAccumulatedNOTEPerStaked)
                .div(Constants.INCENTIVE_ACCUMULATION_PRECISION)
                .sub(accountIncentiveDebt)
        );

        if (netBalanceChange >= 0) {
            snTokenBalance = snTokenBalance.add(netBalanceChange.toUint());
        } else {
            snTokenBalance = snTokenBalance.sub(netBalanceChange.neg().toUint());
        }

        // This is the incentives the account does not have a claim on after the balance change
        accountIncentiveDebt = snTokenBalance
            .mul(totalAccumulatedNOTEPerStaked)
            .div(Constants.INCENTIVE_ACCUMULATION_PRECISION);

        // Set all the values in storage
        s.snTokenBalance = snTokenBalance.toUint88();
        s.accountIncentiveDebt = accountIncentiveDebt.toUint56();
        s.accumulatedNOTE = accumulatedNOTE.toUint56();
    }

    /**
     * @notice Allows a staker to signal that they want to unstake a certain amount of snTokens in
     * the next unstaking window. By signalling their intent to unstake before the unstaking window
     * opens it allows the vaults to calculate the borrow capacity for the subsequent maturity.
     * @param account the address of the staker
     * @param currencyId currency id of the snToken
     * @param snTokensToUnstake the amount of snTokens to unstake at the next maturity, if there is already
     * a value in storage for the current unstake maturity this will overwrite it.
     * @param blockTime the current block time
     */
    function setUnstakeSignal(
        address account,
        uint16 currencyId,
        uint256 snTokensToUnstake,
        uint256 blockTime
    ) internal {
        uint256 maturity = getCurrentMaturity(blockTime);
        // Require that we are within the designated unstaking window, this is so that when we go into
        // rolling vaults forward, we have a collection of the entire balance of tokens that have been
        // signalled that they want to unstake. The unstake signal window begins 28 days before the maturity
        // and ends 14 days before the maturity.
        require(
            maturity.sub(Constants.UNSTAKE_SIGNAL_WINDOW_BEGIN_OFFSET) <= blockTime &&
            blockTime <= maturity.sub(Constants.UNSTAKE_SIGNAL_WINDOW_END_OFFSET),
            "Not in Signal Window"
        );

        (uint256 unstakeMaturity, uint256 prevTokensToUnstake, uint256 snTokenDeposit) = getUnstakeSignal(account, currencyId);
        int256 netBalanceChange;
        int256 netSignalChange;

        if (unstakeMaturity == maturity) {
            // If the staker is resetting their signal on the current maturity then we refund the deposit
            // in full and they will set a new deposit based on their new signal.
            netBalanceChange = snTokenDeposit.toInt();
            // We also update that total signal value based on the net change from the old signal to the new signal
            netSignalChange = prevTokensToUnstake.toInt().neg();
        }

        // Withhold some amount of snTokens as a deposit for unstaking. If the user does come back to unstake
        // this deposit will be credited back to their balance. If they do not unstake then the deposit will
        // be "lost" and become protocol owned liquidity.
        uint256 newTokenDeposit = snTokensToUnstake.mul(Constants.UNSTAKE_DEPOSIT_RATE).div(uint256(Constants.RATE_PRECISION));
        netBalanceChange = netBalanceChange.sub(newTokenDeposit.toInt());

        // Update the balance on the staker to remove the token deposit (refunding a previous deposit for this maturity
        // if it exists)
        StakedNTokenSupply memory stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);
        uint256 accumulatedNOTE = stakedSupply.updateAccumulatedNOTE(currencyId, blockTime, 0);
        uint256 finalTokenBalance = updateStakerBalance(account, currencyId, netBalanceChange, accumulatedNOTE);
        // Check that snTokensToUnstake is less than or equal to the tokens held
        require(finalTokenBalance >= snTokensToUnstake.add(newTokenDeposit));

        _updateUnstakeSignal(account, currencyId, maturity, snTokensToUnstake, newTokenDeposit, netSignalChange);
    }

    function getUnstakeSignal(address account, uint16 currencyId) internal view returns (
        uint256 unstakeMaturity,
        uint256 snTokensToUnstake,
        uint256 snTokenDeposit
    ) { 
        mapping(address => mapping(uint256 => nTokenUnstakeSignalStorage)) storage store = LibStorage.getStakedNTokenUnstakeSignal();
        nTokenUnstakeSignalStorage storage s = store[account][currencyId];

        unstakeMaturity = s.unstakeMaturity;
        snTokensToUnstake = s.snTokensToUnstake;
        snTokenDeposit = s.snTokenDeposit;
    }

    function _updateUnstakeSignal(
        address account,
        uint16 currencyId,
        uint256 maturity,
        uint256 snTokensToUnstake,
        uint256 snTokenDeposit,
        int256 netSignalChange
    ) private {
        // Updates the unstake signal on the account
        nTokenUnstakeSignalStorage storage s = LibStorage.getStakedNTokenUnstakeSignal()[account][currencyId];
        s.unstakeMaturity = maturity.toUint32();
        s.snTokensToUnstake = snTokensToUnstake.toUint88();
        s.snTokensDeposit = snTokenDeposit.toUint88();

        nTokenTotalUnstakeSignalStorage storage t = LibStorage.getStakedNTokenTotalUnstakeSignal()[currencyId][maturity];
        int256 totalUnstakeSignal = int256(uint256(t.totalUnstakeSignal)).add(netSignalChange);
        // Prevents underflows to negative
        t.totalUnstakeSignal = totalUnstakeSignal.toUint().toUint88();
    }

    /// @notice Current unstaking maturity is always the end of the quarter
    /// @param blockTime blocktime
    function getCurrentMaturity(uint256 blockTime) internal pure returns (uint256) {
        return DateTime.getReferenceTime(blockTime).add(Constants.QUARTER);
    }
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {Constants} from "../../../global/Constants.sol";
import {nTokenStaker, nTokenStakerStorage} from "../../../global/Types.sol";
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

        staker.stakedNTokenBalance = s.stakedNTokenBalance;
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
    ) internal {
        mapping(address => mapping(uint256 => nTokenStakerStorage)) storage store = LibStorage.getNTokenStaker();
        nTokenStakerStorage storage s = store[account][currencyId];

        // Read the values onto the stack
        uint256 stakedNTokenBalance = s.stakedNTokenBalance;
        uint256 accountIncentiveDebt = s.accountIncentiveDebt;
        uint256 accumulatedNOTE = s.accumulatedNOTE;

        // This is the additional incentives accumulated before any net change to the balance
        accumulatedNOTE = accumulatedNOTE.add(
            stakedNTokenBalance
                .mul(totalAccumulatedNOTEPerStaked)
                .div(Constants.INCENTIVE_ACCUMULATION_PRECISION)
                .sub(accountIncentiveDebt)
        );

        if (netBalanceChange >= 0) {
            stakedNTokenBalance = stakedNTokenBalance.add(netBalanceChange.toUint());
        } else {
            stakedNTokenBalance = stakedNTokenBalance.sub(netBalanceChange.neg().toUint());
        }

        // This is the incentives the account does not have a claim on after the balance change
        accountIncentiveDebt = stakedNTokenBalance
            .mul(totalAccumulatedNOTEPerStaked)
            .div(Constants.INCENTIVE_ACCUMULATION_PRECISION);

        // Set all the values in storage
        s.stakedNTokenBalance = stakedNTokenBalance.toUint88();
        s.accountIncentiveDebt = accountIncentiveDebt.toUint56();
        s.accumulatedNOTE = accumulatedNOTE.toUint56();
    }
}

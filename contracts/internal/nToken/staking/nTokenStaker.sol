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
import {nTokenMintAction} from "../../../external/actions/nTokenMintAction.sol";
import {StakedNTokenSupply, StakedNTokenSupplyLib} from "./StakedNTokenSupply.sol";
import {LibStorage} from "../../../global/LibStorage.sol";
import {SafeInt256} from "../../../math/SafeInt256.sol";
import {SafeUint256} from "../../../math/SafeUint256.sol";

library nTokenStakerLib {
    using StakedNTokenSupplyLib for StakedNTokenSupply;
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
     * @notice Stakes an given amount of nTokens (which are already minted). A staked nToken position is a claim
     * on an ever increasing amount of underlying nTokens and asset cash. Fees paid in levered vaults will be held
     * in a cash pool and minted as nTokens on demand. nTokens can be staked at any time.
     *
     * @dev This method will mark the staked nToken balance and update incentive accumulators
     * for the staker. Once an nToken is staked it cannot be used as collateral anymore, so it
     * will disappear from the AccountContext.
     * 
     * @param account the address of the staker, must be a valid address according to requireValidAccount,
     * in the ActionGuards.sol file
     * @param currencyId the currency id of the nToken to stake
     * @param nTokensToStake the amount of nTokens to stake
     * @param blockTime the current block time
     * @return snTokensToMint the number of staked nTokens minted
     */
    function stakeNToken(
        address account,
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 blockTime
    ) internal returns (uint256 snTokensToMint) {
        StakedNTokenSupply memory stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);

        // Calculate the share of sNTokens the staker will receive as a share of the total snToken present value
        snTokensToMint = stakedSupply.calculateSNTokenToMint(currencyId, nTokensToStake, blockTime);

        // Accumulate NOTE incentives to the staker based on their staking term and balance.
        uint256 accumulatedNOTE = stakedSupply.updateAccumulatedNOTE(currencyId, blockTime, 0);

        // Update the total supply parameters
        stakedSupply.totalSupply = stakedSupply.totalSupply.add(snTokensToMint);
        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.add(nTokensToStake);
        stakedSupply.setStakedNTokenSupply(currencyId);

        updateStakerBalance(account, currencyId, snTokensToMint.toInt(), accumulatedNOTE);
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

    /**
     * @notice Unstaking nTokens can only be done if the staker has signalled that they will unstake and
     * then they can unstake during the designated unstaking window.
     *
     * @param account the address of the staker
     * @param currencyId the currency id of the nToken to stake
     * @param tokensToUnstake the amount of staked nTokens to unstake
     * @param blockTime the current block time
     * @return nTokenClaim that the staker will have credited to their balance
     */
    function unstakeNToken(
        address account,
        uint16 currencyId,
        uint256 tokensToUnstake,
        uint256 blockTime
    ) internal returns (uint256 nTokenClaim)  {
        uint256 maturity;
        uint256 snTokensToUnstake;
        uint256 snTokenDeposit;
        {
            bool canUnstake;
            (maturity, snTokensToUnstake, snTokenDeposit, canUnstake) = canAccountUnstake(account, currencyId, blockTime);
            // The account can unstake if they have set their signal, they are within the window and they specify
            // an appropriate unstaking amount.
            require(canUnstake && tokensToUnstake <= snTokensToUnstake, "Cannot Unstake");
        }

        // Return the snTokenDeposit to the staker since they are unstaking during the correct period
        uint256 depositRefund = snTokenDeposit.mul(tokensToUnstake).div(snTokensToUnstake);
        int256 netStakerBalanceChange = tokensToUnstake.toInt().neg().add(depositRefund.toInt());

        {
            // This will mint nTokens from totalCashProfits so that the user can withdraw the proper amount
            // of nTokens, this will ony happen on the first unstaking action.
            (StakedNTokenSupply memory stakedSupply, uint256 accumulatedNOTE) = _mintNTokenProfits(currencyId, blockTime);

            // This is the share of the overall nToken balance that the staked nToken has a claim on
            nTokenClaim = stakedSupply.nTokenBalance.mul(tokensToUnstake).div(stakedSupply.totalSupply);

            // Update the staker's balance and incentive counters
            updateStakerBalance(account, currencyId, netStakerBalanceChange, accumulatedNOTE);

            // Update total supply
            stakedSupply.totalSupply = stakedSupply.totalSupply.sub(tokensToUnstake);
            stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.sub(nTokenClaim);
            stakedSupply.setStakedNTokenSupply(currencyId);
        }

        // Updates the unstake signal
        _updateUnstakeSignal(
            account,
            currencyId,
            maturity,
            snTokensToUnstake.sub(tokensToUnstake),
            snTokenDeposit.sub(depositRefund),
            tokensToUnstake.toInt().neg()
        );
    }
    
    /**
     * @notice Mints nToken profits during unstaking if there is some amount of totalCashProfits to ensure
     * that the nTokenClaim withdrawn is correct.
     * @param currencyId the currency id of the nToken to stake
     * @param blockTime the current block time
     * @return stakedSupply the updated total supply figures
     * @return accumulatedNOTE the updated incentives figure
     */
    function _mintNTokenProfits(uint16 currencyId, uint256 blockTime) internal returns (
        StakedNTokenSupply memory stakedSupply,
        uint256 accumulatedNOTE
    ) {
        stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);
        uint256 nTokensMinted;

        if (stakedSupply.totalCashProfits > 0) {
            nTokensMinted = nTokenMintAction.nTokenMint(currencyId, stakedSupply.totalCashProfits.toInt()).toUint();
            stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.add(nTokensMinted);
            stakedSupply.totalCashProfits = 0;
        }

        // We must update accumulator here because the total supply of nTokens has changed
        accumulatedNOTE = stakedSupply.updateAccumulatedNOTE(currencyId, blockTime, nTokensMinted.toInt());
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
        s.snTokenDeposit = snTokenDeposit.toUint88();

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
    
    function canAccountUnstake(address account, uint16 currencyId, uint256 blockTime) internal view returns (
        uint256 maturity,
        uint256 snTokensToUnstake,
        uint256 snTokenDeposit,
        bool canUnstake
    ) {
        // In this case the maturity is in the past, it is the current reference time
        maturity = DateTime.getReferenceTime(blockTime);

        uint256 unstakeMaturity;
        (unstakeMaturity, snTokensToUnstake, snTokenDeposit) = getUnstakeSignal(account, currencyId);
        
        canUnstake = (
            // The account must have set their unstake signal to the maturity
            unstakeMaturity == maturity &&
            // The current time must be inside the unstaking window which begins 24 hours after the maturity and ends 7
            // days later (8 days after the maturity).
            maturity.add(Constants.UNSTAKE_WINDOW_BEGIN_OFFSET) <= blockTime &&
            blockTime <= maturity.add(Constants.UNSTAKE_WINDOW_END_OFFSET)
        );
    }
}

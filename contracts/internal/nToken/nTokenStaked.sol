// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../global/LibStorage.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "../markets/DateTime.sol";
import "./nTokenHandler.sol";
import "./nTokenSupply.sol";
import "../../external/actions/nTokenMintAction.sol";
import "../../external/actions/nTokenRedeemAction.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library nTokenStaked {
    using SafeMath for uint256;
    using SafeInt256 for int256;

    /** Getter and Setter Methods **/

    function getNTokenStaker(
        address account,
        uint16 currencyId
    ) internal view returns (nTokenStaker memory staker) {
        mapping(address => mapping(uint256 => nTokenStakerStorage)) storage store = LibStorage.getNTokenStaker();
        nTokenStakerStorage storage s = store[account][currencyId];

        staker.unstakeMaturity = s.unstakeMaturity;
        staker.stakedNTokenBalance = s.stakedNTokenBalance;
        staker.accountIncentiveDebt = s.accountIncentiveDebt;
        staker.accumulatedNOTE = s.accumulatedNOTE;
    }

    function _setNTokenStaker(
        address account,
        uint16 currencyId,
        nTokenStaker memory staker
    ) private {
        mapping(address => mapping(uint256 => nTokenStakerStorage)) storage store = LibStorage.getNTokenStaker();
        nTokenStakerStorage storage s = store[account][currencyId];

        require(staker.unstakeMaturity <= type(uint32).max); // dev: unstake maturity overflow
        require(staker.stakedNTokenBalance <= type(uint96).max); // dev: staked nToken balance overflow
        require(staker.accountIncentiveDebt <= type(uint56).max); // dev: account incentive debt overflow
        require(staker.accumulatedNOTE <= type(uint56).max); // dev: accumulated note overflow

        s.unstakeMaturity = uint32(staker.unstakeMaturity);
        s.stakedNTokenBalance = uint96(staker.stakedNTokenBalance);
        s.accountIncentiveDebt = uint56(staker.accountIncentiveDebt);
        s.accumulatedNOTE = uint56(staker.accumulatedNOTE);
    }

    function getStakedNTokenSupply(
        uint16 currencyId
    ) internal view returns (StakedNTokenSupply memory stakedSupply) {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        stakedSupply.totalSupply = s.totalSupply;
        stakedSupply.nTokenBalance = s.nTokenBalance;
        stakedSupply.termMultipliers = s.termMultipliers;
        // This is stored in whole tokens, so we scale it up to decimals here
        stakedSupply.totalAnnualTermEmission = uint256(s.totalAnnualTermEmission).mul(uint256(Constants.INTERNAL_TOKEN_PRECISION));
        stakedSupply.lastBaseAccumulatedNOTEPerNToken = s.lastBaseAccumulatedNOTEPerNToken;
        stakedSupply.baseAccumulatedNOTEPerStaked = s.baseAccumulatedNOTEPerStaked;
    }

    function _setStakedNTokenSupply(
        uint16 currencyId,
        StakedNTokenSupply memory stakedSupply
    ) private {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        require(stakedSupply.totalSupply <= type(uint96).max); // dev: staked total supply overflow
        require(stakedSupply.nTokenBalance <= type(uint96).max); // dev: staked ntoken balance overflow
        require(stakedSupply.lastBaseAccumulatedNOTEPerNToken <= type(uint128).max); // dev: staked last accumulated note overflow
        require(stakedSupply.baseAccumulatedNOTEPerStaked <= type(uint128).max); // dev: staked base accumulated note overflow

        // Term multipliers and incentive rates are not updated in here, they are updated separately in governance
        s.totalSupply = uint96(stakedSupply.totalSupply);
        s.nTokenBalance = uint96(stakedSupply.nTokenBalance);
        s.lastBaseAccumulatedNOTEPerNToken = uint128(stakedSupply.lastBaseAccumulatedNOTEPerNToken);
        s.baseAccumulatedNOTEPerStaked = uint128(stakedSupply.baseAccumulatedNOTEPerStaked);
    }

    /// @dev Returns active staked maturity incentives as an array since they are always updated together
    function getStakedMaturityIncentivesFromRef(uint16 currencyId, uint256 tRef) 
        internal view returns (StakedMaturityIncentive[] memory) 
    {
        mapping(uint256 => mapping(uint256 => StakedMaturityIncentivesStorage)) storage store = LibStorage.getStakedMaturityIncentives();
        StakedMaturityIncentive[] memory activeTerms = new StakedMaturityIncentive[](Constants.MAX_STAKING_TERMS);
        uint256 unstakeMaturity = tRef;

        for (uint256 i = 0; i < Constants.MAX_STAKING_TERMS; i++) {
            unstakeMaturity = unstakeMaturity.add(Constants.QUARTER);
            StakedMaturityIncentivesStorage storage s = store[currencyId][unstakeMaturity];

            activeTerms[i].termAccumulatedNOTEPerStaked = s.termAccumulatedNOTEPerStaked;
            activeTerms[i].termStakedSupply = s.termStakedSupply;
            activeTerms[i].unstakeMaturity = unstakeMaturity;
            activeTerms[i].lastAccumulatedTime = s.lastAccumulatedTime;

            // Initialize the lastAccumulatedTime to the tRef if we're seeing it for the first time.
            // For a 1 year staked maturity, this means that we will accumulate term incentives over
            // three quarters and then accumulate base incentives in the final quarter as it rolls down
            // to maturity.
            if (activeTerms[i].lastAccumulatedTime == 0) activeTerms[i].lastAccumulatedTime = tRef;
        }

        return activeTerms;
    }

    function _setStakedMaturityIncentives(
        uint16 currencyId,
        uint256 unstakeMaturity,
        uint256 termAccumulatedNOTEPerStaked,
        uint256 lastAccumulatedTime
    ) private  {
        mapping(uint256 => mapping(uint256 => StakedMaturityIncentivesStorage)) storage store = LibStorage.getStakedMaturityIncentives();
        StakedMaturityIncentivesStorage storage s = store[currencyId][unstakeMaturity];

        require(termAccumulatedNOTEPerStaked <= type(uint112).max); // dev: term accumulated note overflow
        require(lastAccumulatedTime <= type(uint32).max); // dev: last accumulated time overflow

        s.termAccumulatedNOTEPerStaked = uint112(termAccumulatedNOTEPerStaked);
        s.lastAccumulatedTime = uint32(lastAccumulatedTime);
    }

    /// @dev Updates the term staked supply:
    function _updateTermStakedSupply(
        uint16 currencyId,
        uint256 unstakeMaturity,
        uint256 blockTime,
        int256 netTermSupplyChange
    ) private {
        mapping(uint256 => mapping(uint256 => StakedMaturityIncentivesStorage)) storage store = LibStorage.getStakedMaturityIncentives();
        StakedMaturityIncentivesStorage storage s = store[currencyId][unstakeMaturity];
        // Require any updates to the term staked supply to happen only after accumulation. Term staked supply should never update
        // for matured terms.
        require(s.lastAccumulatedTime == blockTime); // dev: invalid stake update
        uint256 termStakedSupply = s.termStakedSupply;

        if (netTermSupplyChange >= 0) {
            termStakedSupply = termStakedSupply.add(SafeInt256.toUint(netTermSupplyChange));
        } else {
            termStakedSupply = termStakedSupply.sub(SafeInt256.toUint(netTermSupplyChange.neg()));
        }

        require(termStakedSupply <= type(uint96).max); // dev: term staked supply overflow
        s.termStakedSupply = uint96(termStakedSupply);
    }

    function _getTermAccumulatedNOTEPerStaked(
        uint16 currencyId,
        uint256 unstakeMaturity
    ) private view returns (uint256 termAccumulatedNOTEPerStaked) {
        // Save a storage read for first time stakers
        if (unstakeMaturity == 0) return 0;

        mapping(uint256 => mapping(uint256 => StakedMaturityIncentivesStorage)) storage store = LibStorage.getStakedMaturityIncentives();
        StakedMaturityIncentivesStorage storage s = store[currencyId][unstakeMaturity];
        return s.termAccumulatedNOTEPerStaked;
    }


    /**
     * @notice Stakes an nToken (which is already minted) for the given amount and term. Each
     * term specified is a single quarter. A staked nToken position is a claim on an ever increasing
     * amount of underlying nTokens. Fees paid in levered vaults will be denominated in nTokens and
     * donated to the staked nToken's underlying balance.
     * @dev This method will mark the staked nToken balance and update incentive accumulators
     * for the staker. Once an nToken is staked it cannot be used as collateral anymore, so it
     * will disappear from the AccountContext.
     * 
     * @param account the address of the staker, must be a valid address according to requireValidAccount,
     * in the ActionGuards.sol file
     * @param currencyId the currency id of the nToken to stake
     * @param nTokensToStake the amount of nTokens to stake
     * @param unstakeMaturity the timestamp of the maturity when the account can unstake, this must align with
     * an existing quarterly maturity date and be within the max staking terms defined.
     * @param blockTime the current block time
     * @return sNTokensToMint the number of staked nTokens minted
     */
    function stakeNToken(
        address account,
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 unstakeMaturity,
        uint256 blockTime
    ) internal returns (uint256 sNTokensToMint) {
        // If nTokensToStake == 0 then the user could just be resetting their unstakeMaturity
        nTokenStaker memory staker = getNTokenStaker(account, currencyId);
        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);

        // Validate that the termToStake is valid for this staker's context. If a staker is restaking with
        // a matured "unstakeMaturity", this forces the unstake maturity to get pushed forward to the next
        // quarterly roll (which is where it would be in any case.)
        require(
            unstakeMaturity >= staker.unstakeMaturity &&
            _isValidUnstakeMaturity(unstakeMaturity, blockTime, Constants.MAX_STAKING_TERMS),
            "Invalid Maturity"
        );

        // Calculate the share of sNTokens the staker will receive. Immediately after this calculation, the
        // staker's share of the pool will exactly equal the nTokens they staked.
        sNTokensToMint = _calculateSNTokenToMint(
            nTokensToStake,
            stakedSupply.totalSupply,
            stakedSupply.nTokenBalance
        );

        uint256 stakedNTokenBalanceAfter = staker.stakedNTokenBalance.add(sNTokensToMint);
        // Accumulate NOTE incentives to the staker based on their staking term and balance.
        uint256 baseAccumulatedNOTEPerStaked = _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply);
        _updateStakerIncentives(
            currencyId,
            baseAccumulatedNOTEPerStaked,
            staker.stakedNTokenBalance,
            stakedNTokenBalanceAfter,
            staker
        );

        if (staker.unstakeMaturity != 0 && staker.unstakeMaturity != unstakeMaturity) {
            // In this case the staker is moving from a lower maturity to a higher maturity, we
            // have to transfer the staked supply between the maturities.
            // NOTE: higher maturity requirement is checked above.
            
            // Decrease the token balance using the old value in the old maturity
            _updateTermStakedSupply(
                currencyId,
                staker.unstakeMaturity,
                blockTime,
                SafeInt256.toInt(staker.stakedNTokenBalance).neg()
            );

            // Increase the token balance using the new value in the new maturity
            _updateTermStakedSupply(
                currencyId,
                unstakeMaturity,
                blockTime,
                SafeInt256.toInt(stakedNTokenBalanceAfter)
            );
        } else {
            // In this case the staker still staking to the same maturity, we just update the net amount
            _updateTermStakedSupply(
                currencyId,
                unstakeMaturity,
                blockTime,
                SafeInt256.toInt(sNTokensToMint)
            );
        }

        // Update unstake maturity only after we accumulate incentives, we don't want users to accumulate
        // incentives on a term they are not currently staked in.
        staker.unstakeMaturity = unstakeMaturity;
        staker.stakedNTokenBalance = stakedNTokenBalanceAfter;
        stakedSupply.totalSupply = stakedSupply.totalSupply.add(sNTokensToMint);
        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.add(nTokensToStake);
        _setNTokenStaker(account, currencyId, staker);
        _setStakedNTokenSupply(currencyId, stakedSupply);
    }

    /**
     * @notice Unstaking nTokens can only be done during designated windows. At this point, the staker
     * will remove their share of nTokens.
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
    ) internal returns (uint256 nTokenClaim) {
        nTokenStaker memory staker = getNTokenStaker(account, currencyId);
        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);

        // Check that unstaking can only happen during designated unstaking windows
        uint256 tRef = DateTime.getReferenceTime(blockTime);
        require(
            // Staker's unstake maturity must have expired
            staker.unstakeMaturity <= blockTime 
            // Unstaking windows are only open during some period at the beginning of
            // every quarter. By definition, tRef is always less than blockTime so this
            // inequality is always tRef < blockTime < tRef + UNSTAKE_WINDOW_SECONDS
            && blockTime < tRef + Constants.UNSTAKE_WINDOW_SECONDS,
            "Invalid unstake time"
        );
    
        // This is the share of the overall nToken balance that the staked nToken has a claim on
        nTokenClaim = stakedSupply.nTokenBalance.mul(tokensToUnstake).div(stakedSupply.totalSupply);
        uint256 stakedNTokenBalanceAfter = staker.stakedNTokenBalance.sub(tokensToUnstake);
        
        // Updates the accumulators and sets the storage values
        uint256 baseAccumulatedNOTEPerStaked = _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply);
        
        // Update the staker's incentive counters in memory
        _updateStakerIncentives(
            currencyId,
            baseAccumulatedNOTEPerStaked,
            staker.stakedNTokenBalance,
            stakedNTokenBalanceAfter,
            staker
        );

        // NOTE: term staked supply is not updated here, when we unstake the unstake maturity is in
        // the past and we no longer need to update term staked supplies in the past. We only ever reference
        // term staked supply past the first staking term in the future.

        // Update balances and set state
        staker.stakedNTokenBalance = stakedNTokenBalanceAfter;
        stakedSupply.totalSupply = stakedSupply.totalSupply.sub(tokensToUnstake);
        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.sub(nTokenClaim);
        _setNTokenStaker(account, currencyId, staker);
        _setStakedNTokenSupply(currencyId, stakedSupply);
    }

    /**
     * @notice Levered vaults will pay fees to the staked nToken in the form of more nTokens. In this
     * method, the balance of nTokens increases while the totalSupply of sNTokens does not
     * increase.
     *
     * @param currencyId the currency of the nToken
     * @param assetAmountInternal amount of asset tokens the fee is paid in
     * @return nTokensMinted the number of nTokens that were minted for the fee
     */
    function payFeeToStakedNToken(
        uint16 currencyId,
        int256 assetAmountInternal,
        uint256 blockTime
    ) internal returns (int256 nTokensMinted) {
        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);
        // nTokenMint will revert if assetAmountInternal is < 0
        nTokensMinted = nTokenMintAction.nTokenMint(currencyId, assetAmountInternal);

        // This updates the base accumulated NOTE and the nToken supply. Term staking has not changed
        // so we do not update those accumulated incentives
        _updateBaseAccumulatedNOTE(currencyId, blockTime, stakedSupply, nTokensMinted, 0);

        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.add(SafeInt256.toUint(nTokensMinted));
        _setStakedNTokenSupply(currencyId, stakedSupply);
    }

    /**
     * @notice In the event of a cash shortfall in a levered vault, this method will be called to redeem nTokens
     * to cover the shortfall. snToken holders will share in the shortfall due to the fact that their
     * underlying nToken balance has decreased.
     * 
     * @dev It is difficult to calculate nTokensToRedeem from assetCashRequired on chain so we require the off
     * chain caller to make this calculation.
     *
     * @param currencyId the currency id of the nToken to stake
     * @param nTokensToRedeem the amount of nTokens to attempt to redeem
     * @param assetCashRequired the amount of asset cash required to offset the shortfall
     * @param blockTime the current block time
     * @return netNTokenChange the amount of nTokens redeemed (negative)
     * @return assetCashRaised the amount of asset cash raised (positive)
     */
    function redeemNTokenToCoverShortfall(
        uint16 currencyId,
        int256 nTokensToRedeem,
        int256 assetCashRequired,
        uint256 blockTime
    ) internal returns (int256 netNTokenChange, int256 assetCashRaised) {
        require(assetCashRequired > 0);
        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);
        netNTokenChange = nTokensToRedeem.neg();
        // nTokenRedeemViaBatch will revert if nTokensToRedeem <= 0
        assetCashRaised = nTokenRedeemAction.nTokenRedeemViaBatch(currencyId, nTokensToRedeem);
        // Require that the cash raised by the specified amount of nTokens to redeem is sufficient or we
        // clean out the nTokenBalance altogether
        require(
            assetCashRaised >= assetCashRequired || SafeInt256.toUint(nTokensToRedeem) == stakedSupply.nTokenBalance,
            "Insufficient cash raised"
        );

        if (assetCashRaised > assetCashRequired) {
            // Put any surplus asset cash back into the nToken
            int256 assetCashSurplus = assetCashRaised - assetCashRequired; // overflow checked above
            int256 nTokensMinted = nTokenMintAction.nTokenMint(currencyId, assetCashSurplus);
            netNTokenChange = netNTokenChange.add(nTokensMinted);

            // Set this for the return value
            assetCashRaised = assetCashRequired;
        }

        // This updates the base accumulated NOTE and the nToken supply. Term staking has not changed
        // so we do not update those accumulated incentives
        _updateBaseAccumulatedNOTE(currencyId, blockTime, stakedSupply, netNTokenChange, 0);
        if (netNTokenChange > 0) {
            stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.add(SafeInt256.toUint(netNTokenChange));
        } else {
            stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.sub(SafeInt256.toUint(netNTokenChange.neg()));
        }
        _setStakedNTokenSupply(currencyId, stakedSupply);
    }

    /**
     * @notice Transfers staked nTokens between accounts. Unstake maturities must match or they are not fungible.
     * @dev If unstake maturities are in the past, we bump them up to the next unstake maturity.
     *
     * @param from account to transfer from
     * @param to account to transfer to
     * @param currencyId currency id of the nToken
     * @param amount amount of staked nTokens to transfer
     * @param blockTime current block time
     */
    function transferStakedNToken(
        address from,
        address to,
        uint16 currencyId,
        uint256 amount,
        uint256 blockTime
    ) internal {
        nTokenStaker memory fromStaker = getNTokenStaker(from, currencyId);
        nTokenStaker memory toStaker = getNTokenStaker(to, currencyId);
        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);

        uint256 fromStakerBalanceAfter = fromStaker.stakedNTokenBalance.sub(amount);
        uint256 toStakerBalanceAfter = toStaker.stakedNTokenBalance.add(amount);

        // First update incentives for both stakers, before attempting to change any balances
        // or unstake maturities.
        uint256 baseAccumulatedNOTEPerStaked = _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply);
        _updateStakerIncentives(
            currencyId,
            baseAccumulatedNOTEPerStaked,
            fromStaker.stakedNTokenBalance,
            fromStakerBalanceAfter,
            fromStaker
        );

        _updateStakerIncentives(
            currencyId,
            baseAccumulatedNOTEPerStaked,
            toStaker.stakedNTokenBalance,
            toStakerBalanceAfter,
            toStaker
        );

        uint256 tRef = DateTime.getReferenceTime(blockTime);
        if (blockTime > tRef + Constants.UNSTAKE_WINDOW_SECONDS) {
            // Ensure that we are outside the current unstake window, don't attempt to mess with the unstake
            // maturities or it may cause some accounts to be able to unstake. Otherwise, we can bump
            // maturities up to the firstUnstakeWindow before we compare to ensure that they are the same.

            uint256 firstUnstakeMaturity = tRef + Constants.QUARTER;
            if (fromStaker.unstakeMaturity < firstUnstakeMaturity) fromStaker.unstakeMaturity = firstUnstakeMaturity;
            if (toStaker.unstakeMaturity < firstUnstakeMaturity) toStaker.unstakeMaturity = firstUnstakeMaturity;

            // NOTE: we do not need to update term staked supply here since the first term counter is not used
            // for incentives
        }

        require(fromStaker.unstakeMaturity == toStaker.unstakeMaturity, "Maturity mismatch");
        fromStaker.stakedNTokenBalance = fromStakerBalanceAfter;
        toStaker.stakedNTokenBalance = toStakerBalanceAfter;

        _setNTokenStaker(from, currencyId, fromStaker);
        _setNTokenStaker(to, currencyId, toStaker);
        // Set the staked supply since accumulators have updated
        _setStakedNTokenSupply(currencyId, stakedSupply);
    }

    function _calculateSNTokenToMint(
        uint256 nTokensToStake,
        uint256 totalSupplyBeforeMint,
        uint256 nTokenBalanceBeforeStake
    ) internal pure returns (uint256 sNTokenToMint) {
        // Immediately after minting, we need to satisfy the equality:
        // (sNTokenToMint * (nTokenBalance + nTokensToStake)) / (totalSupply + sNTokenToMint) == nTokensToStake

        // Rearranging to get sNTokenToMint on one side:
        // (sNTokenToMint * (nTokenBalance + nTokensToStake)) = (totalSupply + sNTokenToMint) * nTokensToStake
        // (sNTokenToMint * (nTokenBalance + nTokensToStake)) = totalSupply * nTokensToStake + sNTokenToMint * nTokensToStake
        // (sNTokenToMint * (nTokenBalance + nTokensToStake)) - (sNTokenToMint * nTokensToStake) = totalSupply * nTokensToStake
        // sNTokenToMint * nTokenBalance = totalSupply * nTokensToStake
        // sNTokenToMint = (totalSupply * nTokensToStake) / nTokenBalance
        if (totalSupplyBeforeMint == 0) {
            sNTokenToMint = nTokensToStake;
        } else {
            sNTokenToMint = totalSupplyBeforeMint.mul(nTokensToStake).div(nTokenBalanceBeforeStake);
        }
    }

    function _isValidUnstakeMaturity(
        uint256 unstakeMaturity,
        uint256 blockTime,
        uint256 maxStakingTerms
    ) internal pure returns (bool) {
        uint256 tRef = DateTime.getReferenceTime(blockTime);
        return (
            // Must divide evenly into quarters so it aligns with a quarterly roll
            unstakeMaturity % Constants.QUARTER == 0 &&
            // Must be in the future (so the soonest unstake maturity will be the next one)
            unstakeMaturity > blockTime &&
            // Cannot be further in the future than the max number of staking terms whitelisted
            // for this particular staked nToken
            (unstakeMaturity.sub(tRef) / Constants.QUARTER) <= maxStakingTerms
        );
    }

    /**
     * Updates the accumulated NOTE incentives globally. Staked nTokens earn NOTE incentives through three
     * channels:
     *  - baseAccumulatedNOTEPerNToken: these are NOTE incentives accumulated to all nToken holders, regardless
     *    of staking status. They are computed using the accumulatedNOTEPerNToken figure calculated in nTokenSupply.
     *    The source of these incentives are the nTokens held by the staked nToken account.
     *  - termAccumulatedBaseNOTEPerStaked: these are NOTE incentives accumulated to all staked nToken holders, regardless
     *    of the unstakeMaturity that they have. This is calculated based on the totalAnnualTermEmission and the supply
     *    of staked nTokens in the other terms.
     *  - termAccumulatedNOTEPerStaked: these are NOTE incentives accumulated to a specific maturity over the course of
     *    its maturity, calculated based on the termMultiplier and the totalAnnualTermEmission
     *
     * @param currencyId id of the currency
     * @param blockTime current block time
     * @param stakedSupply has its accumulators updated in memory
     * @return baseAccumulatedNOTEPerStaked can be used to update a staker's accumulated incentives
     */
    function _updateAccumulatedNOTEIncentives(
        uint16 currencyId,
        uint256 blockTime,
        StakedNTokenSupply memory stakedSupply
    ) internal returns (uint256 baseAccumulatedNOTEPerStaked) {
        uint256 tRef = DateTime.getReferenceTime(blockTime);
        StakedMaturityIncentive[] memory activeTerms = getStakedMaturityIncentivesFromRef(currencyId, tRef);
        uint256 termAccumulatedBaseNOTEPerStaked = 0;
        if (activeTerms[0].lastAccumulatedTime < tRef) {
            // If the last accumulation time on the first term is less than the tRef, we know that
            // we have not completed an accumulation for the previous quarter. Since all changes to staked
            // nToken supply must come through this method first, we can accumulate the past quarter up to its
            // unstaking maturity here to true up the previous quarter before we go on to accumulate incentives
            // for the current quarter.

            // NOTE: in the case that this method does not get called for an entire quarter, than some incentives
            // will not get minted. That would be pretty unlikely but we do that here to avoid an expensive recursive
            // search.
            StakedMaturityIncentive[] memory previousQuarterActiveTerms = getStakedMaturityIncentivesFromRef(
                currencyId,
                tRef.sub(Constants.QUARTER)
            );

            // NOTE: this method updates storage
            termAccumulatedBaseNOTEPerStaked = _updateTermAccumulatedNOTE(
                currencyId,
                tRef, // Accumulate incentives up to the tRef
                previousQuarterActiveTerms,
                stakedSupply
            );

            // Reload the active terms, they have been updated in storage here.
            activeTerms = getStakedMaturityIncentivesFromRef(currencyId, tRef);
        }

        // NOTE: this method updates storage
        termAccumulatedBaseNOTEPerStaked = termAccumulatedBaseNOTEPerStaked.add(
            _updateTermAccumulatedNOTE(currencyId, blockTime, activeTerms, stakedSupply)
        );

        // netNTokenSupply change is set to zero here, we expect that any minting or redeeming action on
        // behalf of the user happens before or after this method. In either case, when we update accumulatedNOTE,
        // it does not take into account any netChange in nTokens because it accumulates up to the point right
        // before the tokens are minted. This method updates storage.
        baseAccumulatedNOTEPerStaked = _updateBaseAccumulatedNOTE(
            currencyId,
            blockTime,
            stakedSupply,
            0,
            // These are additional NOTE incentives that accumulate to the staked incentive base
            termAccumulatedBaseNOTEPerStaked
        );
    }

    /**
     * @notice Updates a staker's incentive factors in memory
     *
     * @param currencyId id of the currency 
     * @param baseAccumulatedNOTEPerStaked this is the base accumulated NOTE for every staked nToken
     * @param stakedNTokenBalanceBefore staked ntoken balance before the stake/unstake action, accumulate
     * incentives up to this point
     * @param stakedNTokenBalanceAfter staked ntoken balance after the stake/unstake action, used to set
     * the incentive debt counter
     * @param staker has its incentive counters updated in memory, the unstakeMaturity has not updated yet
     */
    function _updateStakerIncentives(
        uint16 currencyId,
        uint256 baseAccumulatedNOTEPerStaked,
        uint256 stakedNTokenBalanceBefore,
        uint256 stakedNTokenBalanceAfter,
        nTokenStaker memory staker
    ) internal {
        uint256 termAccumulatedNOTEPerStaked = _getTermAccumulatedNOTEPerStaked(currencyId, staker.unstakeMaturity);
        // The accumulated NOTE per SNToken is a combination of the base level of NOTE incentives accumulated
        // to the token and the additional NOTE accumulated to tokens locked into a specific staking term.
        uint256 totalAccumulatedNOTEPerStaked = baseAccumulatedNOTEPerStaked.add(termAccumulatedNOTEPerStaked);

        // This is the additional incentives accumulated before any net change to the balance
        staker.accumulatedNOTE = staker.accumulatedNOTE.add(
            stakedNTokenBalanceBefore
                .mul(totalAccumulatedNOTEPerStaked)
                .div(Constants.INCENTIVE_ACCUMULATION_PRECISION)
                .sub(staker.accountIncentiveDebt)
        );

        staker.accountIncentiveDebt = stakedNTokenBalanceAfter
            .mul(totalAccumulatedNOTEPerStaked)
            .div(Constants.INCENTIVE_ACCUMULATION_PRECISION);
    }

    /**
     * @notice baseAccumulatedNOTEPerStaked needs to be updated every time either the nTokenBalance
     * or totalSupply of staked NOTE changes. Also accumulates incentives on the nToken.
     * @dev Updates the stakedSupply memory object but does not set storage.
     * @param currencyId currency id of the nToken
     * @param blockTime current block time
     * @param stakedSupply variables that apply to the sNToken supply
     * @param netNTokenSupplyChange passed into the changeNTokenSupply method in the case that the totalSupply
     * of nTokens has changed, this has no effect on the current accumulated NOTE
     * @param termAccumulatedBaseNOTEPerStaked is added to the baseAccumulatedNOTEPerStaked to account for incentives
     * accrued to stakers in the first term and in all matured terms
     * @return baseAccumulatedNOTEPerStaked the accumulated NOTE per staked ntoken up to this point
     */
    function _updateBaseAccumulatedNOTE(
        uint16 currencyId,
        uint256 blockTime,
        StakedNTokenSupply memory stakedSupply,
        int256 netNTokenSupplyChange,
        uint256 termAccumulatedBaseNOTEPerStaked
    ) internal returns (uint256 baseAccumulatedNOTEPerStaked) {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        // This will get the most current accumulated NOTE Per nToken.
        uint256 baseAccumulatedNOTEPerNToken = nTokenSupply.changeNTokenSupply(
            nTokenAddress, netNTokenSupplyChange, blockTime);

        // The accumulator is always increasing, therefore this value should always be greater than or equal
        // to zero.
        uint256 increaseInAccumulatedNOTE = baseAccumulatedNOTEPerNToken
            .sub(stakedSupply.lastBaseAccumulatedNOTEPerNToken);
        
        // Set the new last seen value for the next update
        stakedSupply.lastBaseAccumulatedNOTEPerNToken = baseAccumulatedNOTEPerNToken;
        if (stakedSupply.totalSupply > 0) {
            // Convert the increase from a perNToken basis to a per sNToken basis:
            // (NOTE / nToken) * (nToken / sNToken) = NOTE / sNToken
            stakedSupply.baseAccumulatedNOTEPerStaked = stakedSupply.baseAccumulatedNOTEPerStaked.add(
                increaseInAccumulatedNOTE
                    .mul(stakedSupply.nTokenBalance)
                    .div(stakedSupply.totalSupply)
            );
        }

        stakedSupply.baseAccumulatedNOTEPerStaked = stakedSupply.baseAccumulatedNOTEPerStaked
            .add(termAccumulatedBaseNOTEPerStaked); 

        // NOTE: stakedSupply is not set in storage here
        return stakedSupply.baseAccumulatedNOTEPerStaked;
    }

    /**
     * @notice Updates accumulated NOTE with respect to the accumulateTo time passed in,
     * can be used to accumulate NOTE incentives in the current maturity or in a previous
     * maturity to true it up to the quarter end.
     *
     * @param currencyId currency id of the nToken
     * @param accumulateToTime timestamp to accumulate up to, used to se
     * @param activeTerms the terms to accumulate
     * @param stakedSupply used to get global term factors
     */
    function _updateTermAccumulatedNOTE(
        uint16 currencyId,
        uint256 accumulateToTime,
        StakedMaturityIncentive[] memory activeTerms,
        StakedNTokenSupply memory stakedSupply
    ) internal returns (uint256 baseNOTEPerStaked) {
        (
            uint256 aggregateTermFactor,
            uint256 firstTermStakedSupply
        ) = _getAggregateTermFactors(activeTerms, stakedSupply.totalSupply, stakedSupply.termMultipliers);

        // baseNOTEPerStaked is accumulated to all stakers who have an unstakeMaturity in the past and those
        // who have an unstakeMaturity in the first term. Stakers can only unstake during specified windows so
        // even if they have an unstakeMaturity in the past they can only unstake during the next window.
        baseNOTEPerStaked = _getIncreaseInTermAccumulatedNOTE(
            activeTerms[0].lastAccumulatedTime,
            accumulateToTime,
            uint256(Constants.INTERNAL_TOKEN_PRECISION), // multiplier is hardcoded to 1 for first term
            stakedSupply.totalAnnualTermEmission,
            aggregateTermFactor,
            firstTermStakedSupply
        );

        // For the first term, we no longer update the termAccumulatedNOTEPerStaked, this value is
        // only used to account for incentives that are not part of the baseNOTEPerStaked. We simply
        // update the lastAccumulatedTime so that we do not re-accumulate this portion of the baseIncentives.
        _setStakedMaturityIncentives(
            currencyId,
            activeTerms[0].unstakeMaturity,
            activeTerms[0].termAccumulatedNOTEPerStaked,
            accumulateToTime // new last accumulated time
        );

        // Inside this loop, we accumulate term incentives for all terms beyond the first term.
        for (uint256 i = 1; i < activeTerms.length; i++) {
            uint256 increaseInAccumulatedNOTE = _getIncreaseInTermAccumulatedNOTE(
                accumulateToTime,
                aggregateTermFactor,
                stakedSupply.totalAnnualTermEmission,
                activeTerms[i].lastAccumulatedTime,
                activeTerms[i].termStakedSupply,
                _getTermIncentiveMultiplier(stakedSupply.termMultipliers, i)
            );

            // Accumulate term specific incentives
            activeTerms[i].termAccumulatedNOTEPerStaked = activeTerms[i].termAccumulatedNOTEPerStaked
                .add(increaseInAccumulatedNOTE);

            _setStakedMaturityIncentives(
                currencyId,
                activeTerms[i].unstakeMaturity,
                activeTerms[i].termAccumulatedNOTEPerStaked,
                accumulateToTime // new last accumulated time
            );
        }
    }

    /// @dev Calculates the aggregate term factors as well as the firstTermStakedSupply (which has special logic
    /// due to matured stakers)
    function _getAggregateTermFactors(
        StakedMaturityIncentive[] memory activeTerms,
        uint256 totalSupply,
        bytes4 termMultipliers
    ) internal pure returns (uint256 aggregateTermFactor, uint256 firstTermStakedSupply) {
        // This will be decremented as we loop through all the terms past the first term
        firstTermStakedSupply = totalSupply;

        // Because stakers can be passive, it is possible that the staker's unstake maturity is in the past. In this
        // case they will receive term incentives along with everyone who is staked in the first term. The first term
        // total supply is actually totalSupply - sum(stakedSupply in all other terms). This loop will start from the
        // second term.
        for (uint256 i = 1; i < activeTerms.length; i++) {
            uint256 multiplier = _getTermIncentiveMultiplier(termMultipliers, i);
            uint256 termStakedSupply = activeTerms[i].termStakedSupply;
            // This calculation is 1e8 * 1e8 (no division yet)
            aggregateTermFactor = aggregateTermFactor.add(termStakedSupply.mul(multiplier));
            firstTermStakedSupply = firstTermStakedSupply.sub(termStakedSupply);
        }
        // Term incentive multiplier for the first term is hardcoded to 1
        aggregateTermFactor = aggregateTermFactor.add(firstTermStakedSupply.mul(uint256(Constants.INTERNAL_TOKEN_PRECISION)));
    }

    /// @dev Calculates the increase in accumulated NOTE for a specific term
    function _getIncreaseInTermAccumulatedNOTE(
        uint256 accumulateToTime,
        uint256 aggregateTermFactor,
        uint256 totalAnnualTermEmission,
        uint256 lastAccumulatedTime,
        uint256 termStakedSupply,
        uint256 termMultiplier
    ) internal pure returns (uint256) {
        // The total term emission rate must adhere to the inequality:
        // totalAnnualTermEmission = YEAR * termRatePerStaked * sum(termStakedSupply * termMultiplier for allTerms)
        // 
        // Flipping the equation around to solve for termRatePerStaked:
        // termRatePerStaked = totalAnnualTermEmission / (aggregateTermFactor * YEAR)
        //      where aggregateTermFactor = sum(termStakedSupply * termMultiplier for allTerms)
        //
        // Therefore, each term will accumulate:
        // termAccumulatedNOTEPerStaked = (timeSinceLastAccumulation * termRatePerStaked * termMultiplier) / 
        //      (termStakedSupply)
        //
        // To limit loss of precision, we defer division to the end:
        // termAccumulatedNOTEPerStaked = (timeSinceLastAccumulation * totalAnnualTermEmission * termMultiplier) / 
        //      (termStakedSupply * aggregateTermFactor * YEAR)
        if (lastAccumulatedTime >= accumulateToTime) return 0;
        // This handles the initialization case
        if (termStakedSupply == 0) return 0;

        // This calculation is in:
        //    multiplier (1e8)
        //    MUL totalAnnualTermEmission (1e8)
        //    MUL seconds 
        //    MUL 1e8 (to balance out aggregateTermFactor)
        //    MUL 1e18 (to get to INCENTIVE_ACCUMULATION_PRECISION)
        //    DIV termStakedSupply (1e8)
        //    DIV aggregateTermFactor (1e8 * 1e8)
        //    DIV seconds
        uint256 increaseInAccumulatedNOTE = termMultiplier
            .mul(totalAnnualTermEmission) // overflow checked above
            .mul(accumulateToTime - lastAccumulatedTime) // overflow checked above
            .mul(uint256(Constants.INTERNAL_TOKEN_PRECISION) * Constants.INCENTIVE_ACCUMULATION_PRECISION); // 1e26
        
        increaseInAccumulatedNOTE = increaseInAccumulatedNOTE
            .div(termStakedSupply)
            .div(aggregateTermFactor)
            .div(Constants.YEAR);

        return increaseInAccumulatedNOTE;
    }

    function _getTermIncentiveMultiplier(
        bytes4 termMultipliers,
        uint256 _index
    ) private pure returns (uint256 incentiveMultiplier) {
        // This gives us a maximum multiplier of 655.36 if we are using 100 as a basis, it's not
        // clear if that is sufficient. This would mean if the 1 year term were earning 1 NOTE per sNToken
        // then the base would earn 0.0015 NOTE per sNToken.

        // Since we have 4 indexes here, we can either have 5 unstaking terms or use the first index
        // as a basis to shift the other term multipliers up or down

        // Or alternatively, we can use the 8 bytes to define a linear function for the multiplier and have
        // unlimited number of staking terms.
        // byte1 = maxTerms (0 - 255)
        // byte2 = baseMultiplier (0 - 655.36) using 100 as a base, applies to the first unstake term
        // byte2 = slope (0 - 655.36)  using 100 as a base
        // byte1 = optional kink term
        // byte2 = optional kink slope (0 - 655.36), applies after kink
        require(_index <= 4);
        incentiveMultiplier = uint8(bytes1(termMultipliers << (uint8(_index) * 8))) * uint256(Constants.INTERNAL_TOKEN_PRECISION);
    }
}
// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../global/LibStorage.sol";
import "../../global/Constants.sol";
import "../markets/DateTime.sol";
import "./nTokenHandler.sol";
import "./nTokenSupply.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library nTokenStaked {
    using SafeMath for uint256;

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

        // Term multipliers are not updated in here, they are updated separately in governance
        s.totalSupply = uint96(stakedSupply.totalSupply);
        s.nTokenBalance = uint96(stakedSupply.nTokenBalance);
        s.lastBaseAccumulatedNOTEPerNToken = uint128(stakedSupply.lastBaseAccumulatedNOTEPerNToken);
        s.baseAccumulatedNOTEPerStaked = uint128(stakedSupply.baseAccumulatedNOTEPerStaked);
    }

    function getStakedMaturityIncentives(
        uint16 currencyId,
        uint256 unstakeMaturity
    ) internal view returns (
        uint256 termAccumulatedNOTEPerStaked,
        uint256 lastBaseAccumulatedNOTEPerStaked,
        uint256 lastAccumulatedTime
    ) {
        mapping(uint256 => mapping(uint256 => StakedMaturityIncentivesStorage)) storage store = LibStorage.getStakedMaturityIncentives();
        StakedMaturityIncentivesStorage storage s = store[currencyId][unstakeMaturity];

        termAccumulatedNOTEPerStaked = s.termAccumulatedNOTEPerStaked;
        lastBaseAccumulatedNOTEPerStaked = s.lastBaseAccumulatedNOTEPerStaked;
        lastAccumulatedTime = s.lastAccumulatedTime;
    }

    function _setStakedMaturityIncentives(
        uint16 currencyId,
        uint256 unstakeMaturity,
        uint256 termAccumulatedNOTEPerStaked,
        uint256 lastBaseAccumulatedNOTEPerStaked,
        uint256 lastAccumulatedTime
    ) private  {
        mapping(uint256 => mapping(uint256 => StakedMaturityIncentivesStorage)) storage store = LibStorage.getStakedMaturityIncentives();
        StakedMaturityIncentivesStorage storage s = store[currencyId][unstakeMaturity];

        require(termAccumulatedNOTEPerStaked <= type(uint112).max); // dev: term accumulated note overflow
        require(lastBaseAccumulatedNOTEPerStaked <= type(uint112).max); // dev: last base accumulated note overflow
        require(lastAccumulatedTime <= type(uint32).max); // dev: last accumulated time overflow

        s.termAccumulatedNOTEPerStaked = uint112(termAccumulatedNOTEPerStaked);
        s.lastBaseAccumulatedNOTEPerStaked = uint112(lastBaseAccumulatedNOTEPerStaked);
        s.lastAccumulatedTime = uint32(lastAccumulatedTime);
    }


    // /**
    //  * Stakes an nToken (which is already minted) for the given amount and term. Each
    //  * term specified is a single quarter. This method will mark the staked nToken balance,
    //  * and update incentive accumulators for the staker. Once an nToken is staked it cannot
    //  * be used as collateral anymore, so it will disappear from the AccountContext.
    //  *
    //  * A staked nToken position is a claim on an ever increasing amount of underlying nTokens. Fees
    //  * paid in levered vaults will be denominated in nTokens and donated to the staked nToken's underlying
    //  * balance.
    //  *
    //  * @param staker the address of the staker, must be a valid address according to requireValidAccount,
    //  * in the ActionGuards.sol file
    //  * @param currencyId the currency id of the nToken to stake
    //  * @param nTokensToStake the amount of nTokens to stake
    //  * @param termToStake the number of quarter (90 day) long terms to stake before unstaking
    //  * is allowed. This value cannot decrease but it can increase.
    //  */
    // function stakeNToken(
    //     address staker,
    //     BalanceState memory stakerBalance,
    //     uint256 nTokensToStake,
    //     uint256 unstakeMaturity,
    //     uint256 blockTime
    // ) internal {
    //     // If nTokensToStake == 0 then the user could just be resetting their unstakeMaturity
    //     require(nTokensToStake >= 0);

    //     // TODO: require staker is valid address...
    //     AccountStakedNToken memory stakerContext = getStakerContext(staker);
    //     StakedNTokenContext memory sNTokenContext = getSNTokenContext(stakerBalance.currencyId);

    //     // Validate that the termToStake is valid for this staker's context. If a staker is restaking with
    //     // a matured "unstakeMaturity", this forces the unstake maturity to get pushed forward to the next
    //     // quarterly roll (which is where it would be in any case.)
    //     require(_isValidUnstakeMaturity(unstakeMaturity, blockTime, sNTokenContext.maxStakingTerms));
    //     require(unstakeMaturity >= stakerContext.unstakeMaturity);

    //     // Calculate the share of sNTokens the staker will receive. Immediately after this calculation, the
    //     // staker's share of the pool will exactly equal the nTokens they staked.
    //     uint256 sNTokensToMint = _calculateSNTokenToMint(
    //         nTokensToStake,
    //         sNTokenContext.totalSupply,
    //         sNTokenContext.nTokenBalance
    //     );

    //     // Accumulate NOTE incentives to the staker based on their staking term and balance.
    //     _updateAccumulatedNOTEIncentives(
    //         stakerContext,
    //         sNTokenContext,
    //         sNTokensToMint,
    //         blockTime
    //     );

    //     // Update unstake maturity only after we accumulate incentives
    //     stakerContext.unstakeMaturity = unstakeMaturity;
    //     stakerContext.stakedNTokenBalance = stakerContext.stakedNTokenBalance(sNTokensToMint);
    //     sNTokenContext.totalSupply = sNTokenContext.totalSupply.add(sNTokensToMint);
    //     sNTokenContext.nTokenBalance = sNTokenContext.nTokenBalance.add(nTokensToStake);
    //     stakerContext.setStorage();
    //     sNTokenContext.setStorage();

    //     // Balance state will be updated to effect a net nToken transfer. When this is finalized, any
    //     // incentives that the staker had accrued up to the point of staking will be transferred to their
    //     // wallet.
    //     stakerBalance.netNTokenTransfer = stakerBalance.netNTokenTransfer.sub(SafeInt256.toInt(nTokensToStake));
    // }

    // /**
    //  * Levered vaults will pay fees to the staked nToken in the form of more nTokens. In this
    //  * method, the balance of nTokens increases while the totalSupply of sNTokens does not
    //  * increase.
    //  *
    //  * @param currencyId the currency of the nToken
    //  * @param amountToDepositInternal amount of asset tokens the fee is paid in
    //  */
    // function payFeeToStakedNToken(
    //     uint16 currencyId,
    //     uint256 amountToDepositInternal,
    //     uint256 blockTime
    // ) internal {
    //     StakedNTokenContext memory sNTokenContext = getSNTokenContext(currencyId);
    //     uint256 nTokensMinted = nTokenMintAction.nTokenMint(currencyId, amountToDepositInternal);
    //     // This updates the total supply and accumulatedNOTEPerNToken
    //     nTokenSupply.changeNTokenSupply(tokenAddress, nTokensMinted, blockTime);

    //     // This updates the base accumulated NOTE based on the change in nToken balance...
    //     _updateBaseAccumulatedNOTE(currencyId, 0, blockTime);

    //     sNTokenContext.nTokenBalance = sNTokenContext.nTokenBalance.add(nTokensMinted);
    //     sNTokenContext.setStorage();
    // }

    // /**
    //  * Unstaking nTokens can only be done during designated windows. At this point, the staker
    //  * will remove their share of nTokens.
    //  *
    //  * @param currencyId the currency of the nToken
    //  * @param nTokenFee amount of nTokens the vault is paying
    //  */
    // function unstakeNToken(
    //     address staker,
    //     BalanceState memory stakerBalance,
    //     uint256 stakedNTokensToUnstake,
    //     uint256 blockTime
    // ) internal {
    //     if (stakedNTokensToUnstake == 0) return;
    //     require(stakedNTokensToUnstake > 0);

    //     AccountStakedNToken memory stakerContext = getStakerContext(staker);
    //     StakedNTokenContext memory sNTokenContext = getSNTokenContext(currencyId);

    //     // Check that unstaking can only happen during designated unstaking windows
    //     uint256 tRef = DateTime.getReferenceTime(blockTime);
    //     require(
    //         // Staker's unstake maturity must have expired
    //         stakerContext.unstakeMaturity <= blockTime 
    //         // Unstaking windows are only open during some period at the beginning of
    //         // every quarter. By definition, tRef is always less than blockTime so this
    //         // inequality is always tRef < blockTime < tRef + UNSTAKE_WINDOW_SECONDS
    //         && blockTime < tRef + Constants.UNSTAKE_WINDOW_SECONDS,
    //         "Invalid unstake time"
    //     );
    
    //     // This is the share of the overall nToken balance that the staked nToken has a claim on
    //     uint256 nTokenClaim = sNTokenContext.nTokenBalance
    //         .mul(stakedNTokensToUnstake)
    //         .div(sNTokenContext.totalSupply);
    
    //     _updateAccumulatedNOTEIncentives(
    //         stakerContext,
    //         sNTokenContext,
    //         stakedNTokensToUnstake,
    //         blockTime
    //     );

    //     // Update balances and set state
    //     sNTokenContext.totalSupply = sNTokenContext.totalSupply.sub(stakedNTokensToUnstake);
    //     stakerContext.stakedNTokenBalance = stakerContext.stakedNTokenBalance.sub(stakedNTokensToUnstake);
    //     sNTokenContext.nTokenBalance = sNTokenContext.nTokenBalance.sub(nTokenClaim);
    //     stakerBalance.netNTokenTransfer = stakerBalance.netNTokenTransfer.add(nTokenClaim);
    //     stakerContext.setStorage();
    //     sNTokenContext.setStorage();
    // }

    // /**
    //  * In the event of a cash shortfall in a levered vault, this method will be called to redeem nTokens
    //  * to cover the shortfall. snToken holders will share in the shortfall due to the fact that their
    //  * underlying nToken balance has decreased.
    //  */
    // function redeemNTokenToCoverShortfall(
    //     uint16 currencyId,
    //     uint256 nTokensToRedeem,
    //     uint256 blockTime
    // ) internal {
    //     StakedNTokenContext memory sNTokenContext = getSNTokenContext(currencyId);
    //     uint256 assetCashRaised = nTokenRedeemAction.nTokenRedeemViaBatch(currencyId, nTokensToRedeem);
    //     // This updates the total supply and accumulatedNOTEPerNToken
    //     nTokenSupply.changeNTokenSupply(tokenAddress, nTokensToRedeem.neg(), blockTime);
    //     sNTokenContext.nTokenBalance = sNTokenContext.nTokenBalance.sub(nTokensToRedeem);

    //     // This updates the base accumulated NOTE based on the change in nToken balance...
    //     _updateBaseAccumulatedNOTE(currencyId, 0, blockTime);
    //     sNTokenContext.setStorage();

    // }

    // // todo: transfer stakednTokens

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

    function _updateAccumulatedNOTEIncentives(
        uint16 currencyId,
        uint256 blockTime,
        uint256 stakedNTokenBalanceBefore,
        uint256 stakedNTokenBalanceAfter,
        StakedNTokenSupply memory stakedSupply,
        nTokenStaker memory staker
    ) internal {
        uint256 baseAccumulatedNOTEPerStaked = _updateBaseAccumulatedNOTE(currencyId, blockTime, stakedSupply);
        uint256 termAccumulatedNOTEPerStaked = _updateTermAccumulatedNOTE(
            currencyId,
            staker.unstakeMaturity,
            baseAccumulatedNOTEPerStaked,
            blockTime,
            stakedSupply.termMultipliers
        );

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
     * @notice baseAccumulatedNOTEPerSNToken needs to be updated every time either the nTokenBalance
     * or totalSupply of staked NOTE changes.
     * @dev Updates the sNTokenContext memory object internally but does not set storage.
     * @param currencyId currency id of the nToken
     * @param blockTime current block time
     * @param stakedSupply variables that apply to the sNToken supply
     */
    function _updateBaseAccumulatedNOTE(
        uint16 currencyId,
        uint256 blockTime,
        StakedNTokenSupply memory stakedSupply
    ) internal returns (uint256 baseAccumulatedNOTEPerStaked) {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        // This will get the most current accumulated NOTE Per nToken.
        uint256 baseAccumulatedNOTEPerNToken = nTokenSupply.changeNTokenSupply(nTokenAddress, 0, blockTime);

        // The accumulator is always increasing, therefore this value should always be greater than or equal
        // to zero.
        uint256 increaseInAccumulatedNOTE = baseAccumulatedNOTEPerNToken
            .sub(stakedSupply.lastBaseAccumulatedNOTEPerNToken);
        
        // Set the new last seen value for the next update
        stakedSupply.lastBaseAccumulatedNOTEPerNToken = baseAccumulatedNOTEPerNToken;
        
        // Convert the increase from a perNToken basis to a per sNToken basis:
        // (NOTE / nToken) * (nToken / sNToken) = NOTE / sNToken
        stakedSupply.baseAccumulatedNOTEPerStaked = stakedSupply.baseAccumulatedNOTEPerStaked.add(
            increaseInAccumulatedNOTE
                .mul(stakedSupply.nTokenBalance)
                .div(stakedSupply.totalSupply)
        );

        // NOTE: snTokenContext is not set here
        return stakedSupply.baseAccumulatedNOTEPerStaked;
    }

    /**
     * @notice Term accumulated NOTE per sNToken only updates when the total supply in a particular
     * staking term increases or decrease (either on staking or unstaking). A term accumulated NOTE
     * @param currencyId currency id of the nToken
     * @param unstakeMaturity current block time
     * @param baseAccumulatedNOTEPerStaked the current base accumulated note
     * @param blockTime current block time
     * @param termMultipliers used to get the incentive multiplier for the term
     */
    function _updateTermAccumulatedNOTE(
        uint16 currencyId,
        uint256 unstakeMaturity,
        uint256 baseAccumulatedNOTEPerStaked,
        uint256 blockTime,
        bytes8 termMultipliers
    ) internal returns (uint256) {
        (
            uint256 termAccumulatedNOTEPerStaked,
            uint256 lastBaseAccumulatedNOTEPerStaked,
            uint256 lastAccumulatedTime
        ) = getStakedMaturityIncentives(currencyId, unstakeMaturity);

        // In either of these cases, we do not accumulate additional incentives
        if (lastAccumulatedTime >= blockTime || lastAccumulatedTime == unstakeMaturity) return 0;

        // Get the increase in the base accumulated NOTE since the last time we accumulated
        uint256 increaseInAccumulatedNOTE = baseAccumulatedNOTEPerStaked.sub(lastBaseAccumulatedNOTEPerStaked);
        
        if (unstakeMaturity <= blockTime && lastAccumulatedTime < unstakeMaturity) {
            // The unstake maturity is in the past so we accumulate the base accumulated NOTE up to
            // the current time to ensure that term stakers get the fully accumulated NOTE to their
            // unstaking time. We can back date the baseAccumulatedNOTEPerNToken because we know that
            // emissionRatePerYear has not changed since the last time we calculated this figure (when
            // emission rates are updated all term accumulated NOTE figures are updated).

            // Prorate the increaseInAccumulatedNOTE to the amount of time that was not accumulated
            // over the unstakeMaturity. (XXX: is this 100% accurate?)

            // actual time elapsed: blockTime - lastAccumulatedTime
            // pro-rata time: unstakeMaturity - lastAccumulatedTime
            // therefore: increaseInAccumulatedNOTE * (unstakeMaturity - lastAccumulatedTime) / (blockTime - lastAccumulatedTime)
            increaseInAccumulatedNOTE = increaseInAccumulatedNOTE
                .mul(unstakeMaturity - lastAccumulatedTime) // overflow checked above
                // This won't divide by zero because of the next line where we set the lastAccumulatedTime. The
                // inequality above would prevent a zero value from entering this ifi branch.
                .div(blockTime - lastAccumulatedTime);
            
            lastAccumulatedTime = unstakeMaturity;
        } else {
            lastAccumulatedTime = blockTime;
        }
        
        // We apply a multiplier if the unstake maturity is past the first unstake term.
        uint256 firstUnstakeTerm = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
        if (unstakeMaturity > firstUnstakeTerm) {
            // It's possible that a particular term of the staked nToken goes an entire quarter without having its
            // termAccumulatedNOTEPerStaked updated. In this case that term would lose out on its incentive multiplier,
            // users should be aware and call the corresponding method to update their term incentive accumulator at least
            // once as close to the quarter end (but slightly before) as possible.

            // NOTE: there is no multiplier applied to the first unstake term, so matured staked nTokens will not miss
            // out on a multiplier when it accumulates up to the unstakeMaturity (in the if conditional above)
            uint256 index = (unstakeMaturity - firstUnstakeTerm) / Constants.QUARTER;
            uint256 termIncentiveMultiplier = _getTermIncentiveMultiplier(termMultipliers, index);
            increaseInAccumulatedNOTE = increaseInAccumulatedNOTE
                .mul(termIncentiveMultiplier)
                .div(uint256(Constants.PERCENTAGE_DECIMALS));
        }

        _setStakedMaturityIncentives(
            currencyId,
            unstakeMaturity,
            termAccumulatedNOTEPerStaked.add(increaseInAccumulatedNOTE),
            baseAccumulatedNOTEPerStaked,
            lastAccumulatedTime
        );

        return termAccumulatedNOTEPerStaked;
    }

    function _getTermIncentiveMultiplier(
        bytes8 termMultipliers,
        uint256 _index
    ) private pure returns (uint256 incentiveMultiplier) {
        require(_index <= 4);
        incentiveMultiplier = uint16(bytes2(termMultipliers << (uint8(_index) * 16)));
    }
}
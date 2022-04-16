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
        require(unstakeMaturity >= staker.unstakeMaturity);
        require(_isValidUnstakeMaturity(unstakeMaturity, blockTime, Constants.MAX_STAKING_TERMS));

        // Calculate the share of sNTokens the staker will receive. Immediately after this calculation, the
        // staker's share of the pool will exactly equal the nTokens they staked.
        sNTokensToMint = _calculateSNTokenToMint(
            nTokensToStake,
            stakedSupply.totalSupply,
            stakedSupply.nTokenBalance
        );

        uint256 stakedNTokenBalanceAfter = staker.stakedNTokenBalance.add(sNTokensToMint);
        // Accumulate NOTE incentives to the staker based on their staking term and balance.
        _updateAccumulatedNOTEIncentives(
            currencyId,
            blockTime,
            staker.stakedNTokenBalance,
            stakedNTokenBalanceAfter,
            stakedSupply,
            staker
        );

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
    
        _updateAccumulatedNOTEIncentives(
            currencyId,
            blockTime,
            staker.stakedNTokenBalance,
            stakedNTokenBalanceAfter,
            stakedSupply,
            staker
        );

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

        // This updates the base accumulated NOTE and the nToken supply
        _updateBaseAccumulatedNOTE(currencyId, blockTime, stakedSupply, nTokensMinted);

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

        // This updates the base accumulated NOTE and the nToken supply
        _updateBaseAccumulatedNOTE(currencyId, blockTime, stakedSupply, netNTokenChange);
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
        _updateAccumulatedNOTEIncentives(
            currencyId,
            blockTime,
            fromStaker.stakedNTokenBalance,
            fromStakerBalanceAfter,
            stakedSupply,
            fromStaker
        );

        _updateAccumulatedNOTEIncentives(
            currencyId,
            blockTime,
            toStaker.stakedNTokenBalance,
            toStakerBalanceAfter,
            stakedSupply,
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
     * Updates the accumulated NOTE incentives for a staker, called when staking and unstaking nTokens.
     * Accumulated NOTE incentives are based on the underlying baseAccumulatedNOTE from the nTokens with
     * a bonus multiplier for longer term stakers.
     *
     * @param currencyId id of the currency
     * @param blockTime current block time
     * @param stakedNTokenBalanceBefore staked ntoken balance before the stake/unstake action, accumulate
     * incentives up to this point
     * @param stakedNTokenBalanceAfter staked ntoken balance after the stake/unstake action, used to set
     * the incentive debt counter
     * @param stakedSupply has its accumulators updated in memory
     * @param staker has its incentive counters updated in memory
     */
    function _updateAccumulatedNOTEIncentives(
        uint16 currencyId,
        uint256 blockTime,
        uint256 stakedNTokenBalanceBefore,
        uint256 stakedNTokenBalanceAfter,
        StakedNTokenSupply memory stakedSupply,
        nTokenStaker memory staker
    ) internal {
        // netNTokenSupply change is set to zero here, we expect that any minting or redeeming action on
        // behalf of the user happens before or after this method. In either case, when we update accumulatedNOTE,
        // it does not take into account any netChange in nTokens because it accumulates up to the point right
        // before the tokens are minted.
        uint256 baseAccumulatedNOTEPerStaked = _updateBaseAccumulatedNOTE(currencyId, blockTime, stakedSupply, 0);
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
     * or totalSupply of staked NOTE changes. Also accumulates incentives on the nToken.
     * @dev Updates the stakedSupply memory object but does not set storage.
     * @param currencyId currency id of the nToken
     * @param blockTime current block time
     * @param stakedSupply variables that apply to the sNToken supply
     * @param netNTokenSupplyChange passed into the changeNTokenSupply method in the case that the totalSupply
     * of nTokens has changed, this has no effect on the current accumulated NOTE
     * @return baseAccumulatedNOTEPerStaked the accumulated NOTE per staked ntoken up to this point
     */
    function _updateBaseAccumulatedNOTE(
        uint16 currencyId,
        uint256 blockTime,
        StakedNTokenSupply memory stakedSupply,
        int256 netNTokenSupplyChange
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
        
        // Convert the increase from a perNToken basis to a per sNToken basis:
        // (NOTE / nToken) * (nToken / sNToken) = NOTE / sNToken
        stakedSupply.baseAccumulatedNOTEPerStaked = stakedSupply.baseAccumulatedNOTEPerStaked.add(
            increaseInAccumulatedNOTE
                .mul(stakedSupply.nTokenBalance)
                .div(stakedSupply.totalSupply)
        );

        // NOTE: stakedSupply is not set in storage here
        return stakedSupply.baseAccumulatedNOTEPerStaked;
    }

    /**
     * @notice Term accumulated NOTE per sNToken only updates when the total supply in a particular
     * staking term increases or decrease (either on staking or unstaking). A term accumulated NOTE
     * is based on a multiplier on top of the baseAccumulatedNOTE for a particular nToken.
     *
     * @param currencyId currency id of the nToken
     * @param unstakeMaturity current block time
     * @param baseAccumulatedNOTEPerStaked the current base accumulated note
     * @param blockTime current block time
     * @param termMultipliers used to get the incentive multiplier for the term
     * @return the accumulated NOTE per staked ntoken for the specified unstake maturity up to this point
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
        // TODO: analyze these settings here
        require(_index <= 4);
        incentiveMultiplier = uint16(bytes2(termMultipliers << (uint8(_index) * 16)));
    }
}
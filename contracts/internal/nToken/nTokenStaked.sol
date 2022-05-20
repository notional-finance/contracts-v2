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

    function stakedNTokenAddress(uint16 currencyId) internal view returns (address) { }

    /** Getter and Setter Methods **/
    function setStakedNTokenEmissions(
        uint16 currencyId,
        uint32 totalAnnualStakedEmission,
        uint32 blockTime
    ) internal {
        // First accumulate incentives up to the block time
        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);
        // No nToken supply change
        _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, 0);
        _setStakedNTokenSupply(currencyId, stakedSupply);

        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        // Sanity check that emissions rate is not specified in 1e8 terms.
        require(totalAnnualStakedEmission < Constants.INTERNAL_TOKEN_PRECISION, "Invalid rate");
        s.totalAnnualStakedEmission = totalAnnualStakedEmission;
    }

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
        stakedSupply.totalAnnualStakedEmission = s.totalAnnualStakedEmission;
        stakedSupply.lastAccumulatedTime = s.lastAccumulatedTime;

        stakedSupply.lastBaseAccumulatedNOTEPerNToken = s.lastBaseAccumulatedNOTEPerNToken;
        stakedSupply.totalAccumulatedNOTEPerStaked = s.totalAccumulatedNOTEPerStaked;
    }

    function _setStakedNTokenSupply(
        uint16 currencyId,
        StakedNTokenSupply memory stakedSupply
    ) internal {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        require(stakedSupply.totalSupply <= type(uint96).max); // dev: staked total supply overflow
        require(stakedSupply.nTokenBalance <= type(uint96).max); // dev: staked ntoken balance overflow
        require(stakedSupply.lastAccumulatedTime <= type(uint32).max); // dev: last accumulated time overflow
        require(stakedSupply.lastBaseAccumulatedNOTEPerNToken <= type(uint128).max); // dev: staked last accumulated note overflow
        require(stakedSupply.totalAccumulatedNOTEPerStaked <= type(uint128).max); // dev: staked base accumulated note overflow

        // Incentive rates are not updated in here, they are updated separately in governance
        s.totalSupply = uint96(stakedSupply.totalSupply);
        s.nTokenBalance = uint96(stakedSupply.nTokenBalance);
        s.lastAccumulatedTime = uint32(stakedSupply.lastAccumulatedTime);
        s.lastBaseAccumulatedNOTEPerNToken = uint128(stakedSupply.lastBaseAccumulatedNOTEPerNToken);
        s.totalAccumulatedNOTEPerStaked = uint128(stakedSupply.totalAccumulatedNOTEPerStaked);
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
        // require(
        //     unstakeMaturity >= staker.unstakeMaturity &&
        //     _isValidUnstakeMaturity(unstakeMaturity, blockTime, Constants.MAX_STAKING_TERMS),
        //     "Invalid Maturity"
        // );

        // Calculate the share of sNTokens the staker will receive. Immediately after this calculation, the
        // staker's share of the pool will exactly equal the nTokens they staked.
        sNTokensToMint = _calculateSNTokenToMint(
            nTokensToStake,
            stakedSupply.totalSupply,
            stakedSupply.nTokenBalance
        );

        uint256 stakedNTokenBalanceAfter = staker.stakedNTokenBalance.add(sNTokensToMint);
        // Accumulate NOTE incentives to the staker based on their staking term and balance.
        _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, 0);
        _updateStakerIncentives(
            stakedSupply.totalAccumulatedNOTEPerStaked,
            staker.stakedNTokenBalance,
            stakedNTokenBalanceAfter,
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
        
        // Updates the accumulators and sets the storage values
        _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, 0);
        // Update the staker's incentive counters in memory
        _updateStakerIncentives(
            stakedSupply.totalAccumulatedNOTEPerStaked,
            staker.stakedNTokenBalance,
            stakedNTokenBalanceAfter,
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

        // This updates the base accumulated NOTE and the nToken supply. Term staking has not changed
        // so we do not update those accumulated incentives
        _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, nTokensMinted);

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
     * @return actualNTokensRedeemed the amount of nTokens redeemed (negative)
     * @return assetCashRaised the amount of asset cash raised (positive)
     */
    function redeemNTokenToCoverShortfall(
        uint16 currencyId,
        int256 nTokensToRedeem,
        int256 assetCashRequired,
        uint256 blockTime
    ) internal returns (int256 actualNTokensRedeemed, int256 assetCashRaised) {
        require(assetCashRequired > 0 && nTokensToRedeem > 0);

        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);
        // overflow is checked above on nTokensToRedeem
        require(uint256(nTokensToRedeem) <= stakedSupply.nTokenBalance, "Insufficient nTokens");

        actualNTokensRedeemed = nTokensToRedeem;
        assetCashRaised = nTokenRedeemAction.nTokenRedeemViaBatch(currencyId, nTokensToRedeem);
        // Require that the cash raised by the specified amount of nTokens to redeem is sufficient or we
        // clean out the nTokenBalance altogether
        require(
            assetCashRaised >= assetCashRequired || uint256(nTokensToRedeem) == stakedSupply.nTokenBalance,
            "Insufficient cash raised"
        );

        if (assetCashRaised > assetCashRequired) {
            // Put any surplus asset cash back into the nToken
            int256 assetCashSurplus = assetCashRaised - assetCashRequired; // overflow checked above
            int256 nTokensMinted = nTokenMintAction.nTokenMint(currencyId, assetCashSurplus);
            actualNTokensRedeemed = actualNTokensRedeemed.sub(nTokensMinted);

            // Set this for the return value
            assetCashRaised = assetCashRequired;
        }
        require(actualNTokensRedeemed > 0); // dev: nTokens redeemed negative

        _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, actualNTokensRedeemed.neg());
        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.sub(uint256(actualNTokensRedeemed)); // overflow checked above
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

        // Update the incentive accumulators then the incentives on each staker
        _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, 0);
        _updateStakerIncentives(
            stakedSupply.totalAccumulatedNOTEPerStaked,
            fromStaker.stakedNTokenBalance,
            fromStakerBalanceAfter,
            fromStaker
        );

        _updateStakerIncentives(
            stakedSupply.totalAccumulatedNOTEPerStaked,
            toStaker.stakedNTokenBalance,
            toStakerBalanceAfter,
            toStaker
        );

        // uint256 tRef = DateTime.getReferenceTime(blockTime);
        // if (blockTime > tRef + Constants.UNSTAKE_WINDOW_SECONDS) {
        //     // Ensure that we are outside the current unstake window, don't attempt to mess with the unstake
        //     // maturities or it may cause some accounts to be able to unstake. Otherwise, we can bump
        //     // maturities up to the firstUnstakeWindow before we compare to ensure that they are the same.

        //     uint256 firstUnstakeMaturity = tRef + Constants.QUARTER;
        //     if (fromStaker.unstakeMaturity < firstUnstakeMaturity) fromStaker.unstakeMaturity = firstUnstakeMaturity;
        //     if (toStaker.unstakeMaturity < firstUnstakeMaturity) toStaker.unstakeMaturity = firstUnstakeMaturity;

        //     // NOTE: we do not need to update term staked supply here since the first term counter is not used
        //     // for incentives
        // }

        // require(fromStaker.unstakeMaturity == toStaker.unstakeMaturity, "Maturity mismatch");

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

    /**
     * Updates the accumulated NOTE incentives globally. Staked nTokens earn NOTE incentives through two
     * channels:
     *  - baseNOTEPerStaked: these are NOTE incentives accumulated to all nToken holders, regardless
     *    of staking status. They are computed using the accumulatedNOTEPerNToken figure calculated in nTokenSupply.
     *    The source of these incentives are the nTokens held by the staked nToken account.
     *  - additionalNOTEPerStaked: these are additional NOTE incentives that only accumulate to staked nToken holders,
     *    This is calculated based on the totalStakedEmission and the supply of staked nTokens.
     *
     * @param currencyId id of the currency
     * @param blockTime current block time
     * @param stakedSupply has its accumulators updated in memory
     */
    function _updateAccumulatedNOTEIncentives(
        uint16 currencyId,
        uint256 blockTime,
        StakedNTokenSupply memory stakedSupply,
        int256 netNTokenSupplyChange
    ) internal {
        // netNTokenSupply change is set to zero here, we expect that any minting or redeeming action on
        // behalf of the user happens before or after this method. In either case, when we update accumulatedNOTE,
        // it does not take into account any netChange in nTokens because it accumulates up to the point right
        // before the tokens are minted. This method updates storage.
        uint256 baseNOTEPerStaked = _updateBaseAccumulatedNOTE(currencyId, blockTime, stakedSupply, netNTokenSupplyChange);

        uint256 additionalNOTEPerStaked = nTokenSupply.calculateAdditionalNOTEPerSupply(
            stakedSupply.totalSupply,
            stakedSupply.lastAccumulatedTime,
            stakedSupply.totalAnnualStakedEmission,
            blockTime
        );

        stakedSupply.totalAccumulatedNOTEPerStaked = stakedSupply.totalAccumulatedNOTEPerStaked
            .add(baseNOTEPerStaked)
            .add(additionalNOTEPerStaked);
        stakedSupply.lastAccumulatedTime = blockTime;
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
     * @return baseAccumulatedNOTEPerStaked the additional accumulated NOTE per staked ntoken
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
        if (stakedSupply.totalSupply > 0) {
            // Convert the increase from a perNToken basis to a per sNToken basis:
            // (NOTE / nToken) * (nToken / sNToken) = NOTE / sNToken
            baseAccumulatedNOTEPerStaked = increaseInAccumulatedNOTE
                .mul(stakedSupply.nTokenBalance)
                .div(stakedSupply.totalSupply);
        }
    }

    /**
     * @notice Updates a staker's incentive factors in memory
     * @param totalAccumulatedNOTEPerStaked this is the total accumulated NOTE for every staked nToken
     * @param stakedNTokenBalanceBefore staked ntoken balance before the stake/unstake action, accumulate
     * incentives up to this point
     * @param stakedNTokenBalanceAfter staked ntoken balance after the stake/unstake action, used to set
     * the incentive debt counter
     * @param staker has its incentive counters updated in memory, the unstakeMaturity has not updated yet
     */
    function _updateStakerIncentives(
        uint256 totalAccumulatedNOTEPerStaked,
        uint256 stakedNTokenBalanceBefore,
        uint256 stakedNTokenBalanceAfter,
        nTokenStaker memory staker
    ) internal pure {
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
}
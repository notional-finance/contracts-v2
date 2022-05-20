// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../global/LibStorage.sol";
import "../../global/Constants.sol";
import "../markets/DateTime.sol";
import "./nTokenHandler.sol";
import "./nTokenSupply.sol";
import "../../external/actions/nTokenMintAction.sol";
import "../../external/actions/nTokenRedeemAction.sol";

import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

library nTokenStaked {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;

    /** Getter and Setter Methods **/
    function getStakedNTokenAddress(uint16 currencyId) internal view returns (address) {
        mapping(uint256 => StakedNTokenAddressStorage) storage store = LibStorage.getStakedNTokenAddress();
        return store[currencyId].stakedNTokenAddress;
    }

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

        s.stakedNTokenBalance = staker.stakedNTokenBalance.toUint96();
        s.accountIncentiveDebt = staker.accountIncentiveDebt.toUint56();
        s.accumulatedNOTE = staker.accumulatedNOTE.toUint56();
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

        // Incentive rates are not updated in here, they are updated separately in governance
        s.totalSupply = stakedSupply.totalSupply.toUint96();
        s.nTokenBalance = stakedSupply.nTokenBalance.toUint96();
        s.lastAccumulatedTime = stakedSupply.lastAccumulatedTime.toUint32();
        s.lastBaseAccumulatedNOTEPerNToken = stakedSupply.lastBaseAccumulatedNOTEPerNToken.toUint128();
        s.totalAccumulatedNOTEPerStaked = stakedSupply.totalAccumulatedNOTEPerStaked.toUint128();
    }

    function getStakerUnstakeSignal(address account, uint16 currencyId) internal view returns (
        uint256 unstakeMaturity,
        uint256 snTokensToUnstake,
        uint256 snTokenDeposit
    ) { }

    function setStakerUnstakeSignal(
        address account,
        uint16 currencyId,
        uint256 unstakeMaturity,
        uint256 snTokensToUnstake,
        uint256 snTokenDeposit
    ) internal { }

    function getStakedNTokenMaturity(uint16 currencyId, uint256 maturity) internal view returns (StakedNTokenMaturity memory snTokenMaturity) {

    }

    function _setStakedNTokenMaturity(uint16 currencyId, uint256 maturity, StakedNTokenMaturity memory snTokenMaturity) internal{

    }

    /// @notice Current unstaking maturity is always the end of the quarter
    /// @param blockTime blocktime
    function getCurrentMaturity(uint256 blockTime) internal pure returns (uint256) {
        return DateTime.getReferenceTime(blockTime).add(Constants.QUARTER);
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
     * @return sNTokensToMint the number of staked nTokens minted
     */
    function stakeNToken(
        address account,
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 blockTime
    ) internal returns (uint256 sNTokensToMint) {
        // If nTokensToStake == 0 then the user could just be resetting their unstakeMaturity
        nTokenStaker memory staker = getNTokenStaker(account, currencyId);
        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);

        // Calculate the share of sNTokens the staker will receive. Immediately after this calculation, the
        // staker's share of the pool will exactly equal the nTokens they staked.
        sNTokensToMint = _calculateSNTokenToMint(currencyId, nTokensToStake, stakedSupply, blockTime);

        uint256 stakedNTokenBalanceAfter = staker.stakedNTokenBalance.add(sNTokensToMint);
        // Accumulate NOTE incentives to the staker based on their staking term and balance.
        _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, 0);
        _updateStakerIncentives(
            stakedSupply.totalAccumulatedNOTEPerStaked,
            staker.stakedNTokenBalance,
            stakedNTokenBalanceAfter,
            staker
        );

        // Update all the staker parameters and store them
        staker.stakedNTokenBalance = stakedNTokenBalanceAfter;
        stakedSupply.totalSupply = stakedSupply.totalSupply.add(sNTokensToMint);
        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.add(nTokensToStake);
        _setNTokenStaker(account, currencyId, staker);
        _setStakedNTokenSupply(currencyId, stakedSupply);
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
    function signalUnstake(
        address account,
        uint16 currencyId,
        uint256 snTokensToUnstake,
        uint256 blockTime
    ) internal {
        uint256 unstakeMaturity = getCurrentMaturity(blockTime);

        // Require that we are within the designated unstaking window, this is so that when we go into
        // rolling vaults forward, we have a collection of the entire balance of tokens that have been
        // signalled that they want to unstake. The unstake signal window begins 28 days before the maturity
        // and ends 14 days before the maturity.
        require(
            unstakeMaturity.sub(Constants.UNSTAKE_SIGNAL_WINDOW_BEGIN_OFFSET) <= blockTime &&
            blockTime <= unstakeMaturity.sub(Constants.UNSTAKE_SIGNAL_WINDOW_END_OFFSET),
            "Not in Signal Window"
        );
        (uint256 prevUnstakeMaturity, /* uint256 snTokensToUnstake */, uint256 snTokenDeposit) = getStakerUnstakeSignal(account, currencyId);
        nTokenStaker memory staker = getNTokenStaker(account, currencyId);
        if (prevUnstakeMaturity == unstakeMaturity) {
            // If the staker is resetting their signal on the current maturity then we refund the deposit
            // in full and they will set a new deposit based on their new signal.
            staker.stakedNTokenBalance = staker.stakedNTokenBalance.add(snTokenDeposit);
        }

        // Assert that the required balance exists.
        require(snTokensToUnstake <= staker.stakedNTokenBalance);
        // Withhold some amount of snTokens as a deposit for unstaking. If the user does come back to unstake
        // this deposit will be credited back to their balance. If they do not unstake then the deposit will
        // be "lost" and essentially become protocol owned liquidity.
        snTokenDeposit = snTokensToUnstake.mul(Constants.UNSTAKE_DEPOSIT_RATE).div(uint256(Constants.RATE_PRECISION));
        staker.stakedNTokenBalance = staker.stakedNTokenBalance.sub(snTokenDeposit);

        setStakerUnstakeSignal(account, currencyId, unstakeMaturity, snTokensToUnstake, snTokenDeposit);
        // incrementSnTokensSignalledForUnstaking()
        
        // Updates the staker's nToken balance
        _setNTokenStaker(account, currencyId, staker);
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
        (uint256 unstakeMaturity, uint256 snTokensToUnstake, uint256 snTokenDeposit) = getStakerUnstakeSignal(account, currencyId);
        // Require that we are in the unstaking window and that the account has signalled they
        // will unstake during this time.
        uint256 tRef = DateTime.getReferenceTime(blockTime);
        require(
            unstakeMaturity == tRef &&
            // The current time must be inside the unstaking window which begins 24 hours after the maturity and ends 7
            // days later (8 days after the maturity).
            tRef.add(Constants.UNSTAKE_WINDOW_BEGIN_OFFSET) <= blockTime &&
            blockTime <= tRef.add(Constants.UNSTAKE_WINDOW_END_OFFSET) &&
            tokensToUnstake <= snTokensToUnstake
        );

        nTokenStaker memory staker = getNTokenStaker(account, currencyId);
        StakedNTokenSupply memory stakedSupply = getStakedNTokenSupply(currencyId);

        // Return the snTokenDeposit to the staker since they are unstaking during the correct period
        uint256 depositRefund = snTokenDeposit.mul(tokensToUnstake).div(snTokensToUnstake);
        staker.stakedNTokenBalance = staker.stakedNTokenBalance.add(depositRefund);
        setStakerUnstakeSignal(account, currencyId, unstakeMaturity,
            snTokensToUnstake.sub(tokensToUnstake),
            snTokenDeposit.sub(depositRefund)
        );

        // Mint all the cash profits to nTokens if that has not occurred
        StakedNTokenMaturity memory snTokenMaturity = getStakedNTokenMaturity(currencyId, unstakeMaturity);

        // Decrement the tokens to unstake. This should never underflow but if it does then something has
        // gone wrong in the accounting.
        snTokenMaturity.snTokensSignalledForUnstaking = snTokenMaturity.snTokensSignalledForUnstaking
            .sub(tokensToUnstake);

        if (snTokenMaturity.totalCashProfits > 0) {
            // This will mark that the previous maturity has cleared its profits. No more profits
            // will be allocated to the unstake maturity.
            _mintNTokenProfits(currencyId, snTokenMaturity, stakedSupply, unstakeMaturity, blockTime);
        }

        // Set the snToken maturity state here
        _setStakedNTokenMaturity(currencyId, unstakeMaturity, snTokenMaturity);

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
     * @notice Levered vaults will pay fees to the staked nToken in the form of asset cash in the
     * same currency, these profits will be held in storage until they are minted as nTokens on demand
     * or during the unstaking maturity when unstakers attempt to exit.
     * @param currencyId the currency of the nToken
     * @param assetAmountInternal amount of asset tokens the fee is paid in
     * @param blockTime current block time
     */
    function updateStakedNTokenProfits(
        uint16 currencyId,
        int256 assetAmountInternal,
        uint256 blockTime
    ) internal {
        uint256 unstakeMaturity = getCurrentMaturity(blockTime);
        StakedNTokenMaturity memory snTokenMaturity = getStakedNTokenMaturity(currencyId, unstakeMaturity);
        if (assetAmountInternal >= 0) {
            // Adds the fee to the profits
            snTokenMaturity.totalCashProfits = snTokenMaturity.totalCashProfits.add(uint256(assetAmountInternal));
        } else {
            // The fee may be negative in the case it is a refund
            snTokenMaturity.totalCashProfits = snTokenMaturity.totalCashProfits.sub(uint256(assetAmountInternal.neg()));
        }
        _setStakedNTokenMaturity(currencyId, unstakeMaturity, snTokenMaturity);
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
        uint256 maturity,
        uint256 blockTime
    ) internal returns (int256 actualNTokensRedeemed, int256 assetCashRaised) {
        require(assetCashRequired > 0 && nTokensToRedeem > 0);
        // First attempt to withdraw asset cash from profits that have not been minted into nTokens
        StakedNTokenMaturity memory snTokenMaturity = getStakedNTokenMaturity(currencyId, maturity);

        // NOTE: uint256 conversion overflows checked above
        if (snTokenMaturity.totalCashProfits > uint256(assetCashRequired)) {
            // In this case we have sufficient cash in the profits and we don't need to redeem
            snTokenMaturity.totalCashProfits = snTokenMaturity.totalCashProfits.sub(uint256(assetCashRequired));
            _setStakedNTokenMaturity(currencyId, maturity, snTokenMaturity);
            return (0, assetCashRequired);
        } else if (snTokenMaturity.totalCashProfits > 0) {
            // In this case we net off the required amount from the total profits and zero them out. We know that
            // this subtraction will not go negative because assetCashRequired > 0 and assetCashRequired >= totalCashProfits
            // at this point.
            assetCashRequired = assetCashRequired.subNoNeg(snTokenMaturity.totalCashProfits.toInt());
            snTokenMaturity.totalCashProfits = 0;
            _setStakedNTokenMaturity(currencyId, maturity, snTokenMaturity);
        }

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

    function _mintNTokenProfits(
        uint16 currencyId,
        StakedNTokenMaturity memory snTokenMaturity,
        StakedNTokenSupply memory stakedSupply,
        uint256 maturity,
        uint256 blockTime
    ) internal {
        // TODO: do we need to emit a transfer event here
        uint256 nTokensMinted = nTokenMintAction.nTokenMint(
            currencyId, snTokenMaturity.totalCashProfits.toInt()
        ).toUint();
        _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, nTokensMinted.toInt());

        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.add(nTokensMinted);
        snTokenMaturity.totalCashProfits = 0;

        if (maturity <= blockTime) {
            // If we've cleared cash profits and we've also gone past maturity, we can set the
            // hasClearedPreviousProfits on the next staked nToken maturity storage. This lets
            // the protocol know that it does not need to check the cash balance on this maturity
            // for present value calculations
            uint256 nextMaturity = maturity.add(Constants.QUARTER);
            StakedNTokenMaturity memory snTokenNextMaturity = getStakedNTokenMaturity(currencyId, nextMaturity);
            snTokenNextMaturity.hasClearedPreviousProfits = true;
            _setStakedNTokenMaturity(currencyId, nextMaturity, snTokenNextMaturity);
        }
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

        fromStaker.stakedNTokenBalance = fromStakerBalanceAfter;
        toStaker.stakedNTokenBalance = toStakerBalanceAfter;

        _setNTokenStaker(from, currencyId, fromStaker);
        _setNTokenStaker(to, currencyId, toStaker);
        // Set the staked supply since accumulators have updated
        _setStakedNTokenSupply(currencyId, stakedSupply);
    }

    function getSNTokenPresentValue(
        uint16 currencyId,
        StakedNTokenSupply memory stakedSupply,
        StakedNTokenMaturity memory snTokenMaturity,
        uint256 blockTime
    ) internal view returns (
        uint256 stakedNTokenAssetPV,
        uint256 stakedNTokenValueInNTokens,
        AssetRateParameters memory assetRate
    ) {
        nTokenPortfolio memory nToken;
        nTokenHandler.loadNTokenPortfolioView(nToken, currencyId);

        uint256 totalAssetPV = nTokenCalculations.getNTokenAssetPV(nToken, blockTime).toUint();
        uint256 totalSupply = nToken.totalSupply.toUint();

        stakedNTokenAssetPV = stakedSupply.nTokenBalance
            .mul(totalAssetPV)
            .div(totalSupply)
            .add(snTokenMaturity.totalCashProfits);

        stakedNTokenValueInNTokens = snTokenMaturity.totalCashProfits
            .mul(totalSupply)
            .div(totalAssetPV)
            .add(stakedSupply.nTokenBalance);

        assetRate = nToken.cashGroup.assetRate;
    }


    function _calculateSNTokenToMint(
        uint16 currencyId,
        uint256 nTokensToStake,
        StakedNTokenSupply memory stakedSupply,
        uint256 blockTime
    ) internal returns (uint256 sNTokenToMint) {
        uint256 currentMaturity = getCurrentMaturity(blockTime);
        StakedNTokenMaturity memory snTokenMaturity = getStakedNTokenMaturity(currencyId, currentMaturity);

        if (!snTokenMaturity.hasClearedPreviousProfits) {
            uint256 previousMaturity = DateTime.getReferenceTime(blockTime);
            StakedNTokenMaturity memory snTokenPrevMaturity = getStakedNTokenMaturity(currencyId, previousMaturity);
            // stakedSupply is updated with the nTokens minted from profits in the previous maturity
            _mintNTokenProfits(currencyId, snTokenPrevMaturity, stakedSupply, previousMaturity, blockTime);
            _setStakedNTokenMaturity(currencyId, previousMaturity, snTokenPrevMaturity);
        }

        if (stakedSupply.totalSupply == 0) {
            sNTokenToMint = nTokensToStake;
        } else {
            (
                /* int256 stakedNTokenAssetPV */,
                uint256 stakedNTokenValueInNTokens,
                /* assetRate */
            ) = getSNTokenPresentValue(currencyId, stakedSupply, snTokenMaturity, blockTime);
            sNTokenToMint = stakedSupply.totalSupply.mul(nTokensToStake).div(stakedNTokenValueInNTokens);
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
     * @param netNTokenSupplyChange amount of nTokens supply change
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
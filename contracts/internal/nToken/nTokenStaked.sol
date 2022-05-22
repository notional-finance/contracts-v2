// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../global/LibStorage.sol";
import "../../global/Constants.sol";
import "../markets/DateTime.sol";
import "./nTokenHandler.sol";
import "../../external/actions/nTokenMintAction.sol";
import "../../external/actions/nTokenRedeemAction.sol";

import {StakedNTokenSupply, StakedNTokenSupplyLib} from "./staking/StakedNTokenSupply.sol";
import {nTokenStaker, nTokenStakerLib} from "./staking/nTokenStaker.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

library nTokenStaked {
    using StakedNTokenSupplyLib for StakedNTokenSupply;
    using SafeUint256 for uint256;
    using SafeInt256 for int256;

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

        nTokenStakerLib.updateStakerBalance(account, currencyId, snTokensToMint.toInt(), accumulatedNOTE);
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


        nTokenStaker memory staker = nTokenStakerLib.getStaker(account, currencyId);
        
        /************ TODO: review inside here ***********************/
        // TODO: need to properly accumulate incentives based on the deposit

        (uint256 prevUnstakeMaturity, /* uint256 snTokensToUnstake */, uint256 snTokenDeposit) = getStakerUnstakeSignal(account, currencyId);
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
        // _updateTokensSignalledForUnstaking(currencyId, unstakeMaturity, snTokensToUnstake.toInt());
        /************ TODO: review inside here ***********************/
        
        // Updates the staker's nToken balance
        // staker.setStaker(account, currencyId);
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

        // Return the snTokenDeposit to the staker since they are unstaking during the correct period
        uint256 depositRefund = snTokenDeposit.mul(tokensToUnstake).div(snTokensToUnstake);
        int256 netStakerBalanceChange = tokensToUnstake.toInt().neg().add(depositRefund.toInt());

        setStakerUnstakeSignal(account, currencyId, unstakeMaturity,
            snTokensToUnstake.sub(tokensToUnstake),
            snTokenDeposit.sub(depositRefund)
        );

        StakedNTokenSupply memory stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);
        if (stakedSupply.totalCashProfits > 0) {
            // Mint nToken profits if this has not yet occurred. Minting nToken profits will be allowed
            // once the unstaking window opens. If we mint cash profits before we have settled all vaults
            // it may be that we do not have sufficient profits to refund vault accounts that want to exit
            // their vault positions early.
            _mintNTokenProfits(currencyId, stakedSupply, blockTime);
        }

        // This is the share of the overall nToken balance that the staked nToken has a claim on
        nTokenClaim = stakedSupply.nTokenBalance.mul(tokensToUnstake).div(stakedSupply.totalSupply);

        // Updates the accumulators and sets the storage values
        uint256 accumulatedNOTE = stakedSupply.updateAccumulatedNOTE(currencyId, blockTime, 0);

        // Update the staker's balance and incentive counters
        nTokenStakerLib.updateStakerBalance(account, currencyId, netStakerBalanceChange, accumulatedNOTE);

        // Update balances and set state
        stakedSupply.totalSupply = stakedSupply.totalSupply.sub(tokensToUnstake);
        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.sub(nTokenClaim);
        stakedSupply.setStakedNTokenSupply(currencyId);

        // Decrement the tokens to unstake. This should never underflow but if it does then something has
        // gone wrong in the accounting.
        // _updateTokensSignalledForUnstaking(currencyId, unstakeMaturity, tokensToUnstake.toInt().neg());
    }

    /**
     * @notice Levered vaults will pay fees to the staked nToken in the form of asset cash in the
     * same currency, these profits will be held in storage until they are minted as nTokens after maturity.
     * Profits are held until that point to ensure that there is sufficient cash to refund vault accounts
     * a portion of their fees if they exit early.
     * @param currencyId the currency of the nToken
     * @param netFeePaid positive if the fee is paid to the staked nToken, negative if it is a refund
     * @param blockTime current block time
     */
    function updateStakedNTokenProfits(
        uint16 currencyId,
        int256 netFeePaid,
        uint256 blockTime
    ) internal {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        int256 totalCashProfits = int256(uint256(s.totalCashProfits));
        totalCashProfits = totalCashProfits.add(netFeePaid);
        // This ensures that the total cash profits is both positive and does not overflow uint80
        s.totalCashProfits = totalCashProfits.toUint().toUint80();
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
        StakedNTokenSupply memory stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);

        // NOTE: uint256 conversion overflows checked above
        if (stakedSupply.totalCashProfits > uint256(assetCashRequired)) {
            // In this case we have sufficient cash in the profits and we don't need to redeem
            assetCashRequired = 0;
            stakedSupply.totalCashProfits = stakedSupply.totalCashProfits.sub(uint256(assetCashRequired));
        } else if (stakedSupply.totalCashProfits > 0) {
            // In this case we net off the required amount from the total profits and zero them out. We know that
            // this subtraction will not go negative because assetCashRequired > 0 and assetCashRequired >= totalCashProfits
            // at this point.
            assetCashRequired = assetCashRequired.subNoNeg(stakedSupply.totalCashProfits.toInt());
            stakedSupply.totalCashProfits = 0;
        }

        if (assetCashRequired > 0) {
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

            stakedSupply.updateAccumulatedNOTE(currencyId, blockTime, actualNTokensRedeemed.neg());
            stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.sub(uint256(actualNTokensRedeemed)); // overflow checked above
        }

        stakedSupply.setStakedNTokenSupply(currencyId);
    }

    function _mintNTokenProfits(
        uint16 currencyId,
        StakedNTokenSupply memory stakedSupply,
        uint256 blockTime
    ) internal {
        // // TODO: do we need to emit a transfer event here
        // uint256 nTokensMinted = nTokenMintAction.nTokenMint(
        //     currencyId, stakedSupply.totalCashProfits.toInt()
        // ).toUint();
        // _updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, nTokensMinted.toInt());

        // stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.add(nTokensMinted);
        // stakedSupply.totalCashProfits = 0;

        // if (maturity <= blockTime) {
        //     // If we've cleared cash profits and we've also gone past maturity, we can set the
        //     // hasClearedPreviousProfits on the next staked nToken maturity storage. This lets
        //     // the protocol know that it does not need to check the cash balance on this maturity
        //     // for present value calculations
        //     uint256 nextMaturity = maturity.add(Constants.QUARTER);
        //     StakedNTokenMaturity memory snTokenNextMaturity = getStakedNTokenMaturity(currencyId, nextMaturity);
        //     snTokenNextMaturity.hasClearedPreviousProfits = true;
        //     _setStakedNTokenMaturity(currencyId, nextMaturity, snTokenNextMaturity);
        // }
    }

    /**************** Getter and Setter Methods *********************/

    /// @notice the staked nToken proxy address is only set by governance when it is deployed
    function getStakedNTokenAddress(uint16 currencyId) internal view returns (address) {
        mapping(uint256 => StakedNTokenAddressStorage) storage store = LibStorage.getStakedNTokenAddress();
        return store[currencyId].stakedNTokenAddress;
    }

}
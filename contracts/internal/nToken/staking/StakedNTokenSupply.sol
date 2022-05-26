// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import {
    StakedNTokenSupply,
    StakedNTokenSupplyStorage,
    StakedNTokenIncentivesStorage,
    StakedNTokenAddressStorage
} from "../../../global/Types.sol";
import {Constants} from "../../../global/Constants.sol";
import {nTokenSupply} from "../nTokenSupply.sol";
import {AssetRate, AssetRateParameters} from "../../markets/AssetRate.sol";
import {nTokenPortfolio, nTokenHandler} from "../nTokenHandler.sol";
import {nTokenCalculations} from "../nTokenCalculations.sol";
import {LibStorage} from "../../../global/LibStorage.sol";
import {nTokenMintAction} from "../../../external/actions/nTokenMintAction.sol";
import {nTokenRedeemAction} from "../../../external/actions/nTokenRedeemAction.sol";

import {SafeInt256} from "../../../math/SafeInt256.sol";
import {SafeUint256} from "../../../math/SafeUint256.sol";

library StakedNTokenSupplyLib {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice the staked nToken proxy address is only set by governance when it is deployed
    function getStakedNTokenAddress(uint16 currencyId) internal view returns (address) {
        mapping(uint256 => StakedNTokenAddressStorage) storage store = LibStorage.getStakedNTokenAddress();
        return store[currencyId].stakedNTokenAddress;
    }

    function setStakedNTokenAddress(uint16 currencyId, address tokenAddress) internal returns (address) {
        StakedNTokenAddressStorage storage s = LibStorage.getStakedNTokenAddress()[currencyId];
        // The token address cannot change once set.
        require(s.stakedNTokenAddress == address(0)); // dev: cannot reset ntoken address

        s.stakedNTokenAddress = tokenAddress;
    }

    /// @notice Gets the current staked nToken supply
    function getStakedNTokenSupply(uint16 currencyId) internal view returns (StakedNTokenSupply memory stakedSupply) {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        stakedSupply.totalSupply = s.totalSupply;
        stakedSupply.nTokenBalance = s.nTokenBalance;
        stakedSupply.totalCashProfits = s.totalCashProfits;
    }

    function setStakedNTokenSupply(StakedNTokenSupply memory stakedSupply, uint16 currencyId) internal {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        s.totalSupply = stakedSupply.totalSupply.toUint88();
        s.nTokenBalance = stakedSupply.nTokenBalance.toUint88();
        s.totalCashProfits = stakedSupply.totalCashProfits.toUint80();
    }

    /// @notice This can only be called by governance to update the emission rate for staked nTokens
    function setStakedNTokenEmissions(
        uint16 currencyId,
        uint32 totalAnnualStakedEmission,
        uint256 blockTime
    ) internal {
        // No nToken supply change
        updateAccumulatedNOTE(getStakedNTokenSupply(currencyId), currencyId, blockTime, 0);

        mapping(uint256 => StakedNTokenIncentivesStorage) storage store = LibStorage.getStakedNTokenIncentives();
        StakedNTokenIncentivesStorage storage s = store[currencyId];

        // Sanity check that emissions rate is not specified in 1e8 terms.
        require(totalAnnualStakedEmission < Constants.INTERNAL_TOKEN_PRECISION, "Invalid rate");
        s.totalAnnualStakedEmission = totalAnnualStakedEmission;
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
    function updateAccumulatedNOTE(
        StakedNTokenSupply memory stakedSupply,
        uint16 currencyId,
        uint256 blockTime,
        int256 netNTokenSupplyChange
    ) internal returns (uint256 totalAccumulatedNOTEPerStaked) {
        mapping(uint256 => StakedNTokenIncentivesStorage) storage store = LibStorage.getStakedNTokenIncentives();
        StakedNTokenIncentivesStorage storage s = store[currencyId];

        // Read these values from storage
        totalAccumulatedNOTEPerStaked = s.totalAccumulatedNOTEPerStaked;
        uint256 lastAccumulatedTime = s.lastAccumulatedTime;
        uint256 totalAnnualStakedEmission = s.totalAnnualStakedEmission;
        uint256 lastBaseAccumulatedNOTEPerNToken = s.lastBaseAccumulatedNOTEPerNToken;

        // Update the accumulators from the underlying nTokens accumulated
        (
            uint256 baseNOTEPerStaked,
            uint256 baseAccumulatedNOTEPerNToken
        ) = _updateBaseAccumulatedNOTE(
            stakedSupply, currencyId, blockTime, lastBaseAccumulatedNOTEPerNToken, netNTokenSupplyChange
        );

        // Uses the same calculation from the nToken to determine how many additional NOTEs to emit
        // to snToken holders.
        uint256 additionalNOTEPerStaked = nTokenSupply.calculateAdditionalNOTEPerSupply(
            stakedSupply.totalSupply,
            lastAccumulatedTime,
            totalAnnualStakedEmission,
            blockTime
        );

        totalAccumulatedNOTEPerStaked = totalAccumulatedNOTEPerStaked.add(baseNOTEPerStaked).add(additionalNOTEPerStaked);

        // Update the incentives in storage
        s.lastAccumulatedTime = blockTime.toUint32();
        s.totalAccumulatedNOTEPerStaked = totalAccumulatedNOTEPerStaked.toUint112();
        s.lastBaseAccumulatedNOTEPerNToken = baseAccumulatedNOTEPerNToken.toUint112();
    }

    /**
     * @notice baseAccumulatedNOTEPerStaked needs to be updated every time either the nTokenBalance
     * or totalSupply of staked NOTE changes. Also accumulates incentives on the nToken.
     * @dev Updates the stakedSupply memory object but does not set storage.
     * @param stakedSupply variables that apply to the sNToken supply
     * @param currencyId currency id of the nToken
     * @param blockTime current block time
     * @param netNTokenSupplyChange passed into the changeNTokenSupply method in the case that the totalSupply
     * of nTokens has changed, this has no effect on the current accumulated NOTE
     * @return baseNOTEPerStaked the underlying incentives to the nToken rebased for the staked nToken supply
     * @return baseAccumulatedNOTEPerNToken stored as a reference for updating the snToken accumulator
     */
    function _updateBaseAccumulatedNOTE(
        StakedNTokenSupply memory stakedSupply,
        uint16 currencyId,
        uint256 blockTime,
        uint256 lastBaseAccumulatedNOTEPerNToken,
        int256 netNTokenSupplyChange
    ) private returns (
        uint256 baseNOTEPerStaked,
        uint256 baseAccumulatedNOTEPerNToken
    ) {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        // This will get the most current accumulated NOTE Per nToken.
        baseAccumulatedNOTEPerNToken = nTokenSupply.changeNTokenSupply(nTokenAddress, netNTokenSupplyChange, blockTime);

        // The accumulator is always increasing, therefore this value should always be greater than or equal
        // to zero.
        uint256 increaseInAccumulatedNOTE = baseAccumulatedNOTEPerNToken.sub(lastBaseAccumulatedNOTEPerNToken);
        
        if (stakedSupply.totalSupply > 0) {
            // Convert the increase from a perNToken basis to a per sNToken basis:
            // (NOTE / nToken) * (nToken / sNToken) = NOTE / sNToken
            baseNOTEPerStaked = increaseInAccumulatedNOTE
                .mul(stakedSupply.nTokenBalance)
                .div(stakedSupply.totalSupply);
        }
    }

    /// @notice Returns the present value of the staked nToken using the stateful version of the asset rate
    function getSNTokenPresentValueStateful(
        StakedNTokenSupply memory stakedSupply,
        uint16 currencyId,
        uint256 blockTime
    ) internal returns (
        uint256 valueInAssetCash,
        uint256 valueInNTokens,
        AssetRateParameters memory assetRate
    ) {
        nTokenPortfolio memory nToken;
        nTokenHandler.loadNTokenPortfolioStateful(nToken, currencyId);
        return getSNTokenPresentValue(stakedSupply, nToken, currencyId, blockTime);
    }

    /// @notice Returns the present value of the staked nToken using the view version of the asset rate
    function getSNTokenPresentValueView(
        StakedNTokenSupply memory stakedSupply,
        uint16 currencyId,
        uint256 blockTime
    ) internal view returns (
        uint256 valueInAssetCash,
        uint256 valueInNTokens,
        AssetRateParameters memory assetRate
    ) {
        nTokenPortfolio memory nToken;
        nTokenHandler.loadNTokenPortfolioView(nToken, currencyId);
        return getSNTokenPresentValue(stakedSupply, nToken, currencyId, blockTime);
    }

    /// @notice Returns the present value of the staked nToken in asset cash terms as well as in nToken terms. Includes
    /// profits held in asset cash on the staked nToken and the underlying balance of nTokens.
    /// @param stakedSupply the staked ntoken supply factors
    /// @param currencyId staked nToken currency id
    /// @param blockTime current block time
    /// @return valueInAssetCash the present value of the staked nToken in asset cash terms
    /// @return valueInNTokens the present value of the staked nToken in nToken terms
    /// @return assetRate used for further denomination conversions
    function getSNTokenPresentValue(
        StakedNTokenSupply memory stakedSupply,
        nTokenPortfolio memory nToken,
        uint16 currencyId,
        uint256 blockTime
    ) internal view returns (
        uint256 valueInAssetCash,
        uint256 valueInNTokens,
        AssetRateParameters memory assetRate
    ) {
        uint256 totalAssetPV = nTokenCalculations.getNTokenAssetPV(nToken, blockTime).toUint();
        // NOTE: once instantiated, the nToken total supply cannot drop to zero by definition
        uint256 totalSupply = nToken.totalSupply.toUint();

        // assetCash = nTokenAssetPV * nTokenBalance / totalSupply + totalCashProfits
        valueInAssetCash = stakedSupply.nTokenBalance
            .mul(totalAssetPV)
            .div(totalSupply)
            .add(stakedSupply.totalCashProfits);

        // nToken = totalCashProfits * totalSupply / nTokenAssetPV + nTokenBalance
        valueInNTokens = stakedSupply.totalCashProfits
            .mul(totalSupply)
            .div(totalAssetPV)
            .add(stakedSupply.nTokenBalance);

        assetRate = nToken.cashGroup.assetRate;
    }

    function calculateSNTokenToMintStateful(
        StakedNTokenSupply memory stakedSupply,
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 blockTime
    ) internal returns (uint256 sNTokenToMint) {
        if (stakedSupply.totalSupply == 0) {
            sNTokenToMint = nTokensToStake;
        } else {
            (/* */, uint256 valueInNTokens, /* */) = getSNTokenPresentValueStateful(stakedSupply, currencyId, blockTime);
            // The total snTokens to mint is:
            // snTokenToMint = totalSupply * nTokensToStake / valueInNTokens
            sNTokenToMint = stakedSupply.totalSupply.mul(nTokensToStake).div(valueInNTokens);
        }
    }

    /**
     * @notice Levered vaults will pay fees to the staked nToken in the form of asset cash in the
     * same currency, these profits will be held in storage until they are minted as nTokens after maturity.
     * Profits are held until that point to ensure that there is sufficient cash to refund vault accounts
     * a portion of their fees if they exit early.
     * @param currencyId the currency of the nToken
     * @param netFeePaid positive if the fee is paid to the staked nToken, negative if it is a refund
     */
    function updateStakedNTokenProfits(uint16 currencyId, int256 netFeePaid) internal {
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

            updateAccumulatedNOTE(stakedSupply, currencyId, blockTime, actualNTokensRedeemed.neg());
            stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.sub(uint256(actualNTokensRedeemed)); // overflow checked above
        }

        setStakedNTokenSupply(stakedSupply, currencyId);
    }
}
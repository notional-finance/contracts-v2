// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../internal/nToken/nTokenStaked.sol";

contract MockNTokenStaked {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    function setupIncentives(
        uint16 currencyId,
        uint32 baseEmissionRate,
        uint32 termEmissionRate,
        uint32 blockTime
    ) external {
        nTokenSupply.setIncentiveEmissionRate(address(0), baseEmissionRate, blockTime);
        nTokenStaked.setStakedNTokenEmissions(currencyId, termEmissionRate, blockTime);
    }

    function getNTokenClaim(uint16 currencyId, address account) public view returns (uint256) {
        StakedNTokenSupply memory stakedSupply = nTokenStaked.getStakedNTokenSupply(currencyId);
        nTokenStaker memory staker = nTokenStaked.getNTokenStaker(account, currencyId);

        if (stakedSupply.totalSupply == 0) return 0;

        return (stakedSupply.nTokenBalance * staker.stakedNTokenBalance) / (stakedSupply.totalSupply);
    }

    function setStakedNTokenSupply(
        uint16 currencyId,
        StakedNTokenSupplyStorage memory s
    ) external {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        store[currencyId] = s;
    }

    function setNTokenStaker(
        address account,
        uint16 currencyId,
        nTokenStakerStorage memory s
    ) external {
        mapping(address => mapping(uint256 => nTokenStakerStorage)) storage store = LibStorage.getNTokenStaker();
        store[account][currencyId] = s;
    }

    function getNTokenStaker(
        address account,
        uint16 currencyId
    ) external view returns (nTokenStaker memory staker) {
        return nTokenStaked.getNTokenStaker(account, currencyId);
    }

    function getStakedNTokenSupply(
        uint16 currencyId
    ) external view returns (StakedNTokenSupply memory stakedSupply) {
        return nTokenStaked.getStakedNTokenSupply(currencyId);
    }

    function stakeNToken(
        address account,
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 blockTime
    ) external returns (uint256 sNTokensToMint) {
        changeNTokenSupply(int256(nTokensToStake), blockTime);
        return nTokenStaked.stakeNToken(account, currencyId, nTokensToStake, blockTime);
    }

    function unstakeNToken(
        address account,
        uint16 currencyId,
        uint256 tokensToUnstake,
        uint256 blockTime
    ) external returns (uint256 nTokenClaim) {
        return nTokenStaked.unstakeNToken(account, currencyId, tokensToUnstake, blockTime);
    }

    function payFeeToStakedNToken(
        uint16 currencyId,
        uint256 assetAmountInternal,
        uint256 blockTime
    ) external {
        return nTokenStaked.payFeeToStakedNToken(currencyId, assetAmountInternal, blockTime);
    }

    function changeNTokenSupply(
        int256 netChange,
        uint256 blockTime
    ) public {
        nTokenSupply.changeNTokenSupply(address(0), netChange, blockTime);
    }

    function simulateRedeemNToken(
        uint16 currencyId,
        int256 nTokensToRedeem,
        int256 assetCashRequired,
        int256 _assetCashRaised,
        uint256 blockTime
    ) external returns (int256 actualNTokensRedeemed, int256 assetCashRaised) {
        // Simulates a redemption since nTokenRedeemAction will revert unless it is set up properly
        require(assetCashRequired > 0 && nTokensToRedeem > 0);

        StakedNTokenSupply memory stakedSupply = nTokenStaked.getStakedNTokenSupply(currencyId);
        // overflow is checked above on nTokensToRedeem
        require(uint256(nTokensToRedeem) <= stakedSupply.nTokenBalance, "Insufficient nTokens");

        actualNTokensRedeemed = nTokensToRedeem;
        // XXX: this line is commented out to simulate the redemption
        // assetCashRaised = nTokenRedeemAction.nTokenRedeemViaBatch(currencyId, nTokensToRedeem);
        assetCashRaised = _assetCashRaised;
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

        // This updates the base accumulated NOTE and the nToken supply. Term staking has not changed
        // so we do not update those accumulated incentives. The netNTokenSupply change is negative since we
        // have redeemed nTokens
        nTokenStaked._updateBaseAccumulatedNOTE(currencyId, blockTime, stakedSupply, actualNTokensRedeemed.neg());
        stakedSupply.nTokenBalance = stakedSupply.nTokenBalance.sub(uint256(actualNTokensRedeemed)); // overflow checked above
        nTokenStaked._setStakedNTokenSupply(currencyId, stakedSupply);
    }

    function transferStakedNToken(
        address from,
        address to,
        uint16 currencyId,
        uint256 amount,
        uint256 blockTime
    ) external {
        return nTokenStaked.transferStakedNToken(from, to, currencyId, amount, blockTime);
    }

    function updateAccumulatedNOTEIncentives(uint16 currencyId, uint256 blockTime) external returns (uint256) {
        StakedNTokenSupply memory stakedSupply = nTokenStaked.getStakedNTokenSupply(currencyId);
        nTokenStaked._updateAccumulatedNOTEIncentives(currencyId, blockTime, stakedSupply, 0);
        nTokenStaked._setStakedNTokenSupply(currencyId, stakedSupply);
        return stakedSupply.totalAccumulatedNOTEPerStaked;
    }
}
// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../internal/nToken/nTokenStaked.sol";

contract MockNTokenStaked {
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

    function setStakedMaturityIncentives(
        uint16 currencyId,
        uint256 unstakeMaturity,
        StakedMaturityIncentivesStorage memory s
    ) external {
        mapping(uint256 => mapping(uint256 => StakedMaturityIncentivesStorage)) storage store = LibStorage.getStakedMaturityIncentives();
        store[currencyId][unstakeMaturity] = s;
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

    function getStakedMaturityIncentivesFromRef(uint16 currencyId, uint256 tRef) 
        external view returns (StakedMaturityIncentive[] memory) {
        return nTokenStaked.getStakedMaturityIncentivesFromRef(currencyId, tRef);
    }

    function stakeNToken(
        address account,
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 unstakeMaturity,
        uint256 blockTime
    ) external returns (uint256 sNTokensToMint) {
        return nTokenStaked.stakeNToken(account, currencyId, nTokensToStake, unstakeMaturity, blockTime);
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
        int256 assetAmountInternal,
        uint256 blockTime
    ) external returns (int256 nTokensMinted) {
        return nTokenStaked.payFeeToStakedNToken(currencyId, assetAmountInternal, blockTime);
    }

    function redeemNTokenToCoverShortfall(
        uint16 currencyId,
        int256 nTokensToRedeem,
        int256 assetCashRequired,
        uint256 blockTime
    ) external returns (int256 netNTokenChange, int256 assetCashRaised) {
        return nTokenStaked.redeemNTokenToCoverShortfall(currencyId, nTokensToRedeem, assetCashRequired, blockTime);
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

    function updateAccumulatedNOTEIncentives(
        uint16 currencyId,
        uint256 blockTime
    ) external returns (uint256 baseAccumulatedNOTEPerStaked) {
        StakedNTokenSupply memory stakedSupply = nTokenStaked.getStakedNTokenSupply(currencyId);
        return nTokenStaked._updateAccumulatedNOTEIncentives(
            currencyId,
            blockTime,
            stakedSupply
        );
    }
}
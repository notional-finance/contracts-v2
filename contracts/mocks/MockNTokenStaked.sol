// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../global/Types.sol";
import "../internal/nToken/staking/nTokenStaker.sol";
import "../internal/nToken/staking/StakedNTokenSupply.sol";
import {SafeInt256} from "../math/SafeInt256.sol";
import {SafeUint256} from "../math/SafeUint256.sol";

contract MockNTokenStaked {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        mapping(uint256 => AssetRateStorage) storage assetStore = LibStorage.getAssetRateStorage();
        assetStore[id] = rs;
    }

    function setupIncentives(
        uint16 currencyId,
        uint32 baseEmissionRate,
        uint32 termEmissionRate,
        uint32 blockTime
    ) external {
        nTokenSupply.setIncentiveEmissionRate(address(0), baseEmissionRate, blockTime);
        StakedNTokenSupplyLib.setStakedNTokenEmissions(currencyId, termEmissionRate, blockTime);
    }

    function mintNTokens(uint16 currencyId, int256 assetCashDeposit, uint256 blockTime) public {
        int256 nTokensMinted = nTokenMintAction.nTokenMint(currencyId, assetCashDeposit);
        nTokenSupply.changeNTokenSupply(address(0), nTokensMinted, blockTime);
    }

    function getStaker(address account, uint16 currencyId) external view returns (nTokenStaker memory staker) {
        return nTokenStakerLib.getStaker(account, currencyId);
    }

    function setStakedNTokenSupply(uint16 currencyId, StakedNTokenSupplyStorage memory s) external {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        store[currencyId] = s;
    }

    function getStakedSupply(uint16 currencyId) public view returns (StakedNTokenSupply memory stakedSupply) {
        return StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);
    }

    function getStakedIncentives(uint16 currencyId) public view returns (StakedNTokenIncentivesStorage memory) {
        mapping(uint256 => StakedNTokenIncentivesStorage) storage store = LibStorage.getStakedNTokenIncentives();
        return store[currencyId];
    }

    function getUnstakeSignal(address account, uint16 currencyId, uint256 blockTime) public view returns (
        uint256 unstakeMaturity,
        uint256 snTokensToUnstake,
        uint256 snTokenDeposit,
        uint256 totalUnstakeSignal
    ) { 
        (unstakeMaturity, snTokensToUnstake, snTokenDeposit) = nTokenStakerLib.getUnstakeSignal(account, currencyId);
        uint256 maturity = nTokenStakerLib.getCurrentMaturity(blockTime);

        nTokenTotalUnstakeSignalStorage storage t = LibStorage.getStakedNTokenTotalUnstakeSignal()[currencyId][maturity];
        totalUnstakeSignal = t.totalUnstakeSignal;
    }

    function stakeNToken(
        address account,
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 blockTime
    ) external returns (uint256 sNTokensToMint) {
        return nTokenStakerLib.stakeNToken(account, currencyId, nTokensToStake, blockTime);
    }

    function getSNTokenPresentValue(uint16 currencyId, uint256 blockTime) public view returns (
        uint256 valueInAssetCash,
        uint256 valueInNTokens,
        AssetRateParameters memory assetRate
    ) {
        return StakedNTokenSupplyLib.getSNTokenPresentValueView(getStakedSupply(currencyId), currencyId, blockTime);
    }

    function calculateSNTokenToMint(
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 blockTime
    ) public returns (uint256 sNTokenToMint) {
        return StakedNTokenSupplyLib.calculateSNTokenToMintStateful(
            getStakedSupply(currencyId), currencyId, nTokensToStake, blockTime
        );
    }

    function setUnstakeSignal(
        address account,
        uint16 currencyId,
        uint256 snTokensToUnstake,
        uint256 blockTime
    ) external {
        nTokenStakerLib.setUnstakeSignal(account, currencyId, snTokensToUnstake, blockTime);
    }

    function unstakeNToken(
        address account,
        uint16 currencyId,
        uint256 tokensToUnstake,
        uint256 blockTime
    ) external returns (uint256 nTokenClaim) {
        return nTokenStakerLib.unstakeNToken(account, currencyId, tokensToUnstake, blockTime);
    }

    function updateStakedNTokenProfits(uint16 currencyId, int256 assetAmountInternal) external {
        return StakedNTokenSupplyLib.updateStakedNTokenProfits(currencyId, assetAmountInternal);
    }
}
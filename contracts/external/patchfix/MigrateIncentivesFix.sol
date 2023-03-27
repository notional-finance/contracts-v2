// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/nToken/nTokenHandler.sol";
import "../../global/LibStorage.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract MigrateIncentivesFix  {

    uint16 private constant ETH = 1;
    uint16 private constant DAI = 2;
    uint16 private constant USDC = 3;
    uint16 private constant WBTC = 4;

    function _patchFixIncentives() internal {
        uint256 blockTime = block.timestamp;
        MigrateIncentivesLib._migrateIncentives(ETH, blockTime);
        MigrateIncentivesLib._migrateIncentives(DAI, blockTime);
        MigrateIncentivesLib._migrateIncentives(USDC, blockTime);
        MigrateIncentivesLib._migrateIncentives(WBTC, blockTime);
    }
}

library MigrateIncentivesLib {
    using SafeMath for uint256;

    event IncentivesMigrated(
        uint16 currencyId,
        uint256 migrationEmissionRate,
        uint256 finalIntegralTotalSupply,
        uint256 migrationTime
    );

    /// @notice Stores off the old incentive factors at the specified block time and then initializes the new
    /// incentive factors.
    function _migrateIncentives(uint16 currencyId, uint256 blockTime) internal {
        address tokenAddress = nTokenHandler.nTokenAddress(currencyId);
        mapping(address => nTokenTotalSupplyStorage_deprecated) storage store = LibStorage.getDeprecatedNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage_deprecated storage d_nTokenStorage = store[tokenAddress];

        uint256 totalSupply = d_nTokenStorage.totalSupply;
        uint256 integralTotalSupply = d_nTokenStorage.integralTotalSupply;
        uint256 lastSupplyChangeTime = d_nTokenStorage.lastSupplyChangeTime;

        // Set up the new storage slot
        _initializeNewSupplyStorage(tokenAddress, totalSupply, blockTime);

        integralTotalSupply = _calculateFinalIntegralTotalSupply(
            totalSupply,
            integralTotalSupply,
            lastSupplyChangeTime,
            blockTime
        );

        // prettier-ignore
        (
            /* currencyId */,
            uint256 emissionRatePerYear,
            /* initializedTime */,
            /* assetArrayLength */,
            /* parameters */
        ) = nTokenHandler.getNTokenContext(tokenAddress);
        require(emissionRatePerYear <= type(uint96).max);

        // Now we store the final integral total supply and the migration emission rate after this these values
        // will not change. Override the totalSupply to store the emissionRatePerYear at this point. We will not
        // use the totalSupply after this.
        d_nTokenStorage.totalSupply = uint96(emissionRatePerYear);
        // Overflows checked in _calculateFinalIntegralSupply
        d_nTokenStorage.integralTotalSupply = uint128(integralTotalSupply);
        d_nTokenStorage.lastSupplyChangeTime = uint32(blockTime);
    
        emit IncentivesMigrated(
            currencyId,
            emissionRatePerYear,
            integralTotalSupply,
            blockTime
        );
    }

    function _initializeNewSupplyStorage(
        address tokenAddress,
        uint256 totalSupply,
        uint256 blockTime
    ) private {
        mapping(address => nTokenTotalSupplyStorage) storage store = LibStorage.getNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage storage nTokenStorage = store[tokenAddress];
        uint96 _totalSupply = nTokenStorage.totalSupply;
        uint256 _accumulatedNOTEPerNToken = nTokenStorage.accumulatedNOTEPerNToken;
        uint256 _lastAccumulatedTime = nTokenStorage.lastAccumulatedTime;

        // Storage must be zero'd out, we cannot re-initialize this slot once done
        require(_totalSupply == 0 && _accumulatedNOTEPerNToken == 0 && _lastAccumulatedTime == 0);

        require(totalSupply <= type(uint96).max);
        require(blockTime <= type(uint32).max);
        nTokenStorage.totalSupply = uint96(totalSupply);
        nTokenStorage.lastAccumulatedTime = uint32(blockTime);
    }

    function _calculateFinalIntegralTotalSupply(
        uint256 totalSupply,
        uint256 integralTotalSupply,
        uint256 lastSupplyChangeTime,
        uint256 blockTime
    ) private pure returns (uint256) {
        // Initialize last supply change time if it has not been set.
        if (lastSupplyChangeTime == 0) lastSupplyChangeTime = blockTime;
        require(blockTime >= lastSupplyChangeTime); // dev: invalid block time

        // Add to the integral total supply the total supply of tokens multiplied by the time that the total supply
        // has been the value. This will part of the numerator for the average total supply calculation during
        // minting incentives.
        integralTotalSupply = integralTotalSupply.add(totalSupply.mul(blockTime - lastSupplyChangeTime));

        require(integralTotalSupply >= 0 && integralTotalSupply < type(uint128).max); // dev: integral total supply overflow
        require(blockTime < type(uint32).max); // dev: last supply change supply overflow

        return integralTotalSupply;
    }

}
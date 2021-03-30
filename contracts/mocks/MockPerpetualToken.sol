// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../storage/StorageLayoutV1.sol";

contract MockPerpetualToken is StorageLayoutV1 {

    function setIncentiveEmissionRate(
        address tokenAddress,
        uint32 newEmissionsRate
    ) external {
        PerpetualToken.setIncentiveEmissionRate(tokenAddress, newEmissionsRate);
    }

    function getPerpetualTokenContext(
        address tokenAddress
    ) external view returns (uint, uint, uint, uint8, uint) {
        (
            uint currencyId,
            uint totalSupply,
            uint incentiveRate,
            uint8 assetArrayLength,
            uint lastInitializedTime
        ) = PerpetualToken.getPerpetualTokenContext(tokenAddress);
        assert(PerpetualToken.getPerpetualTokenAddress(currencyId) == tokenAddress);

        return (currencyId, totalSupply, incentiveRate, assetArrayLength, lastInitializedTime);
    }

    function getPerpetualTokenAddress(
        uint currencyId
    ) external view returns (address) {
        address tokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        (
            uint currencyIdStored,
            /* uint totalSupply */,
            /* incentiveRate */,
            /* assetArrayLength */,
            /* lastInitializedTime */
        ) = PerpetualToken.getPerpetualTokenContext(tokenAddress);
        assert(currencyIdStored == currencyId);

        return tokenAddress;
    }

    function setArrayLengthAndInitializedTime(
        address tokenAddress,
        uint8 arrayLength,
        uint lastInitializedTime
    ) external {
        PerpetualToken.setArrayLengthAndInitializedTime(tokenAddress, arrayLength, lastInitializedTime);
    }

    function changePerpetualTokenSupply(
        address tokenAddress,
        int netChange
    ) external {
        PerpetualToken.changePerpetualTokenSupply(tokenAddress, netChange);
    }

    function setPerpetualTokenAddress(
        uint16 currencyId,
        address tokenAddress
    ) external {
        PerpetualToken.setPerpetualTokenAddress(currencyId, tokenAddress);

        // Test the assertions
        this.getPerpetualTokenAddress(currencyId);
        this.getPerpetualTokenContext(tokenAddress);
    }

    function getDepositParameters(
        uint currencyId,
        uint maxMarketIndex
    ) external view returns (int[] memory, int[] memory) {
        return PerpetualToken.getDepositParameters(currencyId, maxMarketIndex);
    }

    function setDepositParameters(
        uint currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) external {
        PerpetualToken.setDepositParameters(currencyId, depositShares, leverageThresholds);
    }

    function getInitializationParameters(
        uint currencyId,
        uint maxMarketIndex
    ) external view returns (int[] memory, int[] memory) {
        return PerpetualToken.getInitializationParameters(currencyId, maxMarketIndex);
    }

    function setInitializationParameters(
        uint currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) external {
        PerpetualToken.setInitializationParameters(currencyId, rateAnchors, proportions);
    }

    function getPerpetualTokenPV(
        uint currencyId,
        uint blockTime
    ) external view returns (int) {
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioView(
            currencyId
        );

        (int assetPv, /* ifCashBitmap */ ) = PerpetualToken.getPerpetualTokenPV(
            perpToken,
            blockTime
        );

        return assetPv;
    }
}
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

    function getPerpetualTokenContext(address tokenAddress)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            bytes6
        )
    {
        (
            uint256 currencyId,
            uint256 totalSupply,
            uint256 incentiveRate,
            uint256 lastInitializedTime,
            bytes6 parameters
        ) = PerpetualToken.getPerpetualTokenContext(tokenAddress);
        assert(PerpetualToken.nTokenAddress(currencyId) == tokenAddress);

        return (
            currencyId,
            totalSupply,
            incentiveRate,
            lastInitializedTime,
            parameters
        );
    }

    function nTokenAddress(uint256 currencyId) external view returns (address) {
        address tokenAddress = PerpetualToken.nTokenAddress(currencyId);
        (uint256 currencyIdStored, , , , ) =
            /* uint totalSupply */
            /* incentiveRate */
            /* lastInitializedTime */
            /* parameters */
            PerpetualToken.getPerpetualTokenContext(tokenAddress);
        assert(currencyIdStored == currencyId);

        return tokenAddress;
    }

    function setArrayLengthAndInitializedTime(
        address tokenAddress,
        uint8 arrayLength,
        uint256 lastInitializedTime
    ) external {
        PerpetualToken.setArrayLengthAndInitializedTime(
            tokenAddress,
            arrayLength,
            lastInitializedTime
        );
    }

    function changePerpetualTokenSupply(address tokenAddress, int256 netChange)
        external
    {
        PerpetualToken.changePerpetualTokenSupply(tokenAddress, netChange);
    }

    function setPerpetualTokenAddress(uint16 currencyId, address tokenAddress)
        external
    {
        PerpetualToken.setPerpetualTokenAddress(currencyId, tokenAddress);

        // Test the assertions
        this.nTokenAddress(currencyId);
        this.getPerpetualTokenContext(tokenAddress);
    }

    function getDepositParameters(uint256 currencyId, uint256 maxMarketIndex)
        external
        view
        returns (int256[] memory, int256[] memory)
    {
        return PerpetualToken.getDepositParameters(currencyId, maxMarketIndex);
    }

    function setDepositParameters(
        uint256 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) external {
        PerpetualToken.setDepositParameters(
            currencyId,
            depositShares,
            leverageThresholds
        );
    }

    function getInitializationParameters(
        uint256 currencyId,
        uint256 maxMarketIndex
    ) external view returns (int256[] memory, int256[] memory) {
        return
            PerpetualToken.getInitializationParameters(
                currencyId,
                maxMarketIndex
            );
    }

    function setInitializationParameters(
        uint256 currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) external {
        PerpetualToken.setInitializationParameters(
            currencyId,
            rateAnchors,
            proportions
        );
    }

    function getPerpetualTokenPV(uint256 currencyId, uint256 blockTime)
        external
        view
        returns (int256)
    {
        PerpetualTokenPortfolio memory perpToken =
            PerpetualToken.buildPerpetualTokenPortfolioView(currencyId);

        (
            int256 assetPv, /* ifCashBitmap */

        ) = PerpetualToken.getPerpetualTokenPV(perpToken, blockTime);

        return assetPv;
    }

    function updatePerpetualTokenCollateralParameters(
        uint16 currencyId,
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage
    ) external {
        address perpTokenAddress = PerpetualToken.nTokenAddress(currencyId);
        require(perpTokenAddress != address(0), "Invalid currency");

        PerpetualToken.setPerpetualTokenCollateralParameters(
            perpTokenAddress,
            residualPurchaseIncentive10BPS,
            pvHaircutPercentage,
            residualPurchaseTimeBufferHours,
            cashWithholdingBuffer10BPS,
            liquidationHaircutPercentage
        );
    }
}

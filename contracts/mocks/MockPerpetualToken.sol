// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../storage/StorageLayoutV1.sol";

contract MockPerpetualToken is StorageLayoutV1 {

    function perpetualTokenCurrencyId(
        address tokenAddress
    ) external view returns (uint) {
        uint currencyId = PerpetualToken.perpetualTokenCurrencyId(tokenAddress);
        assert(PerpetualToken.getPerpetualTokenAddress(currencyId) == tokenAddress);

        return currencyId;
    }

    function getPerpetualTokenAddress(
        uint currencyId
    ) external view returns (address) {
        address tokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        assert(PerpetualToken.perpetualTokenCurrencyId(tokenAddress) == currencyId);

        return tokenAddress;
    }

    function setPerpetualTokenAddress(
        uint currencyId,
        address tokenAddress
    ) external {
        PerpetualToken.setPerpetualTokenAddress(currencyId, tokenAddress);

        // Test the assertions
        this.getPerpetualTokenAddress(currencyId);
        this.perpetualTokenCurrencyId(tokenAddress);
    }

    function getDepositParameters(
        uint currencyId,
        uint maxMarketIndex
    // ) external view returns (bytes32, bytes32) {
    ) external view returns (uint[] memory, uint[] memory) {
        return PerpetualToken.getDepositParameters(currencyId, maxMarketIndex);
    }

    function setDepositParameters(
        uint currencyId,
        uint24[] calldata depositShares,
        uint24[] calldata leverageThresholds
    ) external {
        PerpetualToken.setDepositParameters(currencyId, depositShares, leverageThresholds);
    }

    function getInitializationParameters(
        uint currencyId,
        uint maxMarketIndex
    ) external view returns (uint[] memory, uint[] memory) {
        return PerpetualToken.getInitializationParameters(currencyId, maxMarketIndex);
    }

    function setInitializationParameters(
        uint currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) external {
        PerpetualToken.setInitializationParameters(currencyId, rateAnchors, proportions);
    }
}
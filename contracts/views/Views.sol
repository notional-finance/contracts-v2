// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/ExchangeRate.sol";
import "../common/CashGroup.sol";
import "../common/AssetRate.sol";
import "../common/PerpetualToken.sol";
import "../storage/StorageLayoutV1.sol";

contract Views is StorageLayoutV1 {

    function getMaxCurrencyId() external view returns (uint16) {
        return maxCurrencyId;
    }

    function getCurrency(uint16 currencyId) external view returns (CurrencyStorage memory) {
        return currencyMapping[currencyId];
    }

    function getETHRateStorage(uint16 currencyId) external view returns (ETHRateStorage memory) {
        return underlyingToETHRateMapping[currencyId];
    }

    function getETHRate(uint16 currencyId) external view returns (ETHRate memory) {
        return ExchangeRate.buildExchangeRate(currencyId);
    }

    function getCurrencyAndRate(uint16 currencyId) external view returns (CurrencyStorage memory, ETHRate memory) {
        return (
            currencyMapping[currencyId],
            ExchangeRate.buildExchangeRate(currencyId)
        );
    }

    function getCashGroup(uint16 currencyId) external view returns (CashGroupParameterStorage memory) {
        return cashGroupMapping[currencyId];
    }

    function getAssetRateStorage(uint16 currencyId) external view returns (AssetRateStorage memory) {
        return assetToUnderlyingRateMapping[currencyId];
    }

    function getAssetRate(uint16 currencyId) external view returns (AssetRateParameters memory) {
        return AssetRate.buildAssetRate(currencyId);
    }

    function getCashGroupAndRate(
        uint16 currencyId
    ) external view returns (CashGroupParameterStorage memory, AssetRateParameters memory) {
        CashGroupParameterStorage memory cg = cashGroupMapping[currencyId];
        if (cg.maxMarketIndex == 0) {
            // No markets listed for the currency id
            return (cg, AssetRateParameters(address(0), 0, 0));
        }

        return (cg, AssetRate.buildAssetRate(currencyId));
    }

    function getInitializationParameters(uint16 currencyId) external view returns (int[] memory, int[] memory) {
        return PerpetualToken.getInitializationParameters(currencyId, 9);
    }

    function getPerpetualDepositParameters(uint16 currencyId) external view returns (int[] memory, int[] memory) {
        return PerpetualToken.getDepositParameters(currencyId, 9);
    }

    function getPerpetualTokenAddress(uint16 currencyId) external view returns (address) {
        return PerpetualToken.getPerpetualTokenAddress(currencyId);
    }

    function getOwner() external view returns (address) { return owner; }

    // function getAllCurrencyData() external view returns (CashGroupParameterStorage memory);
}
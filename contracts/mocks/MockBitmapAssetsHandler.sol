// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/BitmapAssetsHandler.sol";
import "../common/AssetRate.sol";
import "../storage/StorageLayoutV1.sol";

contract MockBitmapAssetsHandler is StorageLayoutV1 {

    function setAssetRateMapping(
        uint id,
        AssetRateStorage calldata rs
    ) external {
        assetToUnderlyingRateMapping[id] = rs;
    }

    function buildAssetRate(
        uint id
    ) external view returns (AssetRateParameters memory) {
        return AssetRate.buildAssetRate(id);
    }

    function getifCashAsset(
        address account,
        uint currencyId,
        uint maturity
    ) public view returns (int) {
        return ifCashMapping[account][currencyId][maturity];
    }

    function getAssetsBitmap(
        address account,
        uint currencyId
    ) public view returns (bytes memory) {
        return BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
    }

    function setAssetsBitmap(
        address account,
        uint currencyId,
        bytes memory assetsBitmap
    ) public {
        return BitmapAssetsHandler.setAssetsBitmap(account, currencyId, assetsBitmap);
    }

    function setifCashAsset(
        address account,
        uint currencyId,
        uint maturity,
        uint nextMaturingAsset,
        int notional,
        bytes memory assetsBitmap
    ) public returns (bytes memory) {
        return BitmapAssetsHandler.setifCashAsset(
            account,
            currencyId,
            maturity,
            nextMaturingAsset,
            notional,
            assetsBitmap
        );
    }

    function getifCashNetPresentValue(
        address account,
        uint currencyId,
        uint nextMaturingAsset,
        uint blockTime,
        bytes memory assetsBitmap,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) public view returns (int) {
        return BitmapAssetsHandler.getifCashNetPresentValue(
            account,
            currencyId,
            nextMaturingAsset,
            blockTime,
            assetsBitmap,
            cashGroup,
            markets,
            riskAdjusted
        );
    }

    function getMaturityFromBitNum(
        uint blockTime,
        uint bitNum
    ) public pure returns (uint) {
        return CashGroup.getMaturityFromBitNum(blockTime, bitNum);
    }

    function getBitNumFromMaturity(
        uint blockTime,
        uint maturity
    ) public pure returns (uint, bool) {
        return CashGroup.getBitNumFromMaturity(blockTime, maturity);
    }

    function getPresentValue(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        int notional,
        uint maturity,
        uint blockTime
    ) public view returns (int) {
        uint oracleRate = CashGroup.getOracleRate(
            cashGroup,
            markets,
            maturity,
            blockTime
        );

        return AssetHandler.getPresentValue(notional, maturity, blockTime, oracleRate);
    }

    function getRiskAdjustedPresentValue(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        int notional,
        uint maturity,
        uint blockTime
    ) public view returns (int) {
        uint oracleRate = CashGroup.getOracleRate(
            cashGroup,
            markets,
            maturity,
            blockTime
        );

        return AssetHandler.getRiskAdjustedPresentValue(cashGroup, notional, maturity, blockTime, oracleRate);
    }
}
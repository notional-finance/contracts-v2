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

    function setCashGroup(
        uint id,
        CashGroupParameterStorage calldata cg
    ) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function buildCashGroupView(
        uint currencyId
    ) public view returns (
        CashGroupParameters memory,
        MarketParameters[] memory
    ) {
        return CashGroup.buildCashGroupView(currencyId);
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
    ) public view returns (bytes32) {
        return BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
    }

    function setAssetsBitmap(
        address account,
        uint currencyId,
        bytes32 assetsBitmap
    ) public {
        return BitmapAssetsHandler.setAssetsBitmap(account, currencyId, assetsBitmap);
    }

    function setifCashAsset(
        address account,
        uint currencyId,
        uint maturity,
        uint nextSettleTime,
        int notional,
        bytes32 assetsBitmap
    ) public returns (bytes32) {
        return BitmapAssetsHandler.setifCashAsset(
            account,
            currencyId,
            maturity,
            nextSettleTime,
            notional,
            assetsBitmap
        );
    }

    function getifCashNetPresentValue(
        address account,
        uint currencyId,
        uint nextSettleTime,
        uint blockTime,
        bytes32 assetsBitmap,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) public view returns (int) {
        return BitmapAssetsHandler.getifCashNetPresentValue(
            account,
            currencyId,
            nextSettleTime,
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

    function getifCashArray(
        address account,
        uint currencyId,
        uint nextSettleTime
    ) external view returns (PortfolioAsset[] memory) {
        return BitmapAssetsHandler.getifCashArray(account, currencyId, nextSettleTime);
    }
}
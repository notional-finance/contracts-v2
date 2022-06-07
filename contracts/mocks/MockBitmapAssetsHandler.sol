// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/markets/Market.sol";
import "../internal/portfolio/BitmapAssetsHandler.sol";
import "../internal/markets/AssetRate.sol";
import "../global/StorageLayoutV1.sol";

contract MockBitmapAssetsHandler is StorageLayoutV1 {
    using Market for MarketParameters;

    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        mapping(uint256 => AssetRateStorage) storage assetStore = LibStorage.getAssetRateStorage();
        assetStore[id] = rs;
    }

    function setCashGroup(uint256 id, CashGroupSettings calldata cg) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function buildCashGroupView(uint16 currencyId)
        public
        view
        returns (CashGroupParameters memory)
    {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function setMarketStorage(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) public {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function getifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) public view returns (int256) {
        return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity);
    }

    function getAssetsBitmap(address account, uint256 currencyId) public view returns (bytes32) {
        return BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
    }

    function setAssetsBitmap(
        address account,
        uint256 currencyId,
        bytes32 assetsBitmap
    ) public {
        return BitmapAssetsHandler.setAssetsBitmap(account, currencyId, assetsBitmap);
    }

    function addifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 nextSettleTime,
        int256 notional
    ) public returns (bytes32, int256) {
        int256 finalNotional = BitmapAssetsHandler.addifCashAsset(
            account,
            currencyId,
            maturity,
            nextSettleTime,
            notional
        );
        bytes32 bitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);

        return (bitmap, finalNotional);
    }

    function getifCashNetPresentValue(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        CashGroupParameters memory cashGroup,
        bool riskAdjusted
    ) public view returns (int256, bool) {
        return
            BitmapAssetsHandler.getifCashNetPresentValue(
                account,
                currencyId,
                nextSettleTime,
                blockTime,
                cashGroup,
                riskAdjusted
            );
    }

    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        public
        pure
        returns (uint256)
    {
        return DateTime.getMaturityFromBitNum(blockTime, bitNum);
    }

    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        public
        pure
        returns (uint256, bool)
    {
        return DateTime.getBitNumFromMaturity(blockTime, maturity);
    }

    function getPresentValue(
        CashGroupParameters memory cashGroup,
        int256 notional,
        uint256 maturity,
        uint256 blockTime
    ) public view returns (int256) {
        uint256 oracleRate = CashGroup.calculateOracleRate(cashGroup, maturity, blockTime);

        return AssetHandler.getPresentfCashValue(notional, maturity, blockTime, oracleRate);
    }

    function getRiskAdjustedPresentValue(
        CashGroupParameters memory cashGroup,
        int256 notional,
        uint256 maturity,
        uint256 blockTime
    ) public view returns (int256) {
        uint256 oracleRate = CashGroup.calculateOracleRate(cashGroup, maturity, blockTime);

        return
            AssetHandler.getRiskAdjustedPresentfCashValue(
                cashGroup,
                notional,
                maturity,
                blockTime,
                oracleRate
            );
    }

    function getifCashArray(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime
    ) external view returns (PortfolioAsset[] memory) {
        return BitmapAssetsHandler.getifCashArray(account, currencyId, nextSettleTime);
    }

    function totalBitsSet(
        bytes32 bitmap
    ) external pure returns (uint256) {
        return Bitmap.totalBitsSet(bitmap);
    }

    function isBitSet(
        bytes32 bitmap,
        uint256 bitNum
    ) external pure returns (bool) {
        return Bitmap.isBitSet(bitmap, bitNum);
    }
}

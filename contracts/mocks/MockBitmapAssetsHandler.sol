// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/portfolio/BitmapAssetsHandler.sol";
import "../internal/markets/AssetRate.sol";
import "../global/StorageLayoutV1.sol";

contract MockBitmapAssetsHandler is StorageLayoutV1 {
    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setCashGroup(uint256 id, CashGroupParameterStorage calldata cg) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function buildCashGroupView(uint256 currencyId)
        public
        view
        returns (CashGroupParameters memory, MarketParameters[] memory)
    {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function getifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) public view returns (int256) {
        bytes32 slot = BitmapAssetsHandler.getifCashSlot(account, currencyId, maturity);
        int256 notional;
        assembly {
            notional := sload(slot)
        }
        return notional;
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
        int256 notional,
        bytes32 assetsBitmap
    ) public returns (bytes32, int256) {
        return
            BitmapAssetsHandler.addifCashAsset(
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
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        bytes32 assetsBitmap,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) public view returns (int256, bool) {
        return
            BitmapAssetsHandler.getifCashNetPresentValue(
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
        MarketParameters[] memory markets,
        int256 notional,
        uint256 maturity,
        uint256 blockTime
    ) public view returns (int256) {
        uint256 oracleRate = CashGroup.getOracleRate(cashGroup, markets, maturity, blockTime);

        return AssetHandler.getPresentValue(notional, maturity, blockTime, oracleRate);
    }

    function getRiskAdjustedPresentValue(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        int256 notional,
        uint256 maturity,
        uint256 blockTime
    ) public view returns (int256) {
        uint256 oracleRate = CashGroup.getOracleRate(cashGroup, markets, maturity, blockTime);

        return
            AssetHandler.getRiskAdjustedPresentValue(
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
}

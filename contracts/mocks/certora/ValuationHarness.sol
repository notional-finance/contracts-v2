// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/markets/DateTime.sol";
import "../../internal/markets/CashGroup.sol";
import "../../internal/valuation/AssetHandler.sol";
import "../../internal/portfolio/BitmapAssetsHandler.sol";
import "../../math/Bitmap.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract ValuationHarness {
    using SafeMath for uint256;
    using CashGroup for CashGroupParameters;
    using Bitmap for bytes32;

    CashGroupParameters symbolicCashGroup;
    MarketParameters symbolicMarket;
    AccountContext symbolicAccountContext;

    function getMaturityAtMarketIndex(uint256 marketIndex, uint256 blockTime)
        external
        pure
        returns (uint256)
    {
        return DateTime.getReferenceTime(blockTime).add(DateTime.getTradedMarket(marketIndex));
    }

    function calculateOracleRate(uint256 maturity, uint256 blockTime)
        external
        view
        returns (uint256)
    {
        return symbolicCashGroup.calculateOracleRate(maturity, blockTime);
    }

    function getMarketValues()
        external
        view
        returns (
            uint256 totalfCash,
            uint256 totalAssetCash,
            uint256 totalLiquidity,
            uint256 maturity
        )
    {
        require(symbolicMarket.totalfCash >= 0);
        require(symbolicMarket.totalAssetCash >= 0);
        require(symbolicMarket.totalLiquidity >= 0);

        totalfCash = uint256(symbolicMarket.totalfCash);
        totalAssetCash = uint256(symbolicMarket.totalAssetCash);
        totalLiquidity = uint256(symbolicMarket.totalLiquidity);
        maturity = symbolicMarket.maturity;
    }

    function getLiquidityHaircut(uint256 assetType) external view returns (uint256) {
        return symbolicCashGroup.getLiquidityHaircut(assetType);
    }

    function getPresentValue(
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) external view returns (int256) {
        return AssetHandler.getPresentValue(notional, maturity, blockTime, oracleRate);
    }

    function getRiskAdjustedPresentValue(
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) external view returns (int256) {
        return
            AssetHandler.getRiskAdjustedPresentValue(
                symbolicCashGroup,
                notional,
                maturity,
                blockTime,
                oracleRate
            );
    }

    function getLiquidityTokenValue(
        int256 fCashNotional,
        uint256 tokens,
        uint256 assetType,
        uint256 blockTime,
        bool riskAdjusted
    ) external view returns (int256, int256) {
        require(tokens > 0 && tokens <= 2**255 - 1);

        PortfolioAsset[] memory assets;
        uint256 index;
        if (fCashNotional != 0) {
            assets = new PortfolioAsset[](2);
            assets[0].currencyId = 1;
            assets[0].assetType = Constants.FCASH_ASSET_TYPE;
            assets[0].maturity = symbolicMarket.maturity;
            assets[0].notional = fCashNotional;
            index = 1;
        }

        assets[index].currencyId = 1;
        assets[index].assetType = assetType;
        assets[index].maturity = symbolicMarket.maturity;
        assets[index].notional = int256(tokens);

        return
            AssetHandler.getLiquidityTokenValue(
                index,
                symbolicCashGroup,
                symbolicMarket,
                assets,
                blockTime,
                riskAdjusted
            );
    }

    function checkPortfolioSorted(address account) external view returns (bool) {
        PortfolioAsset[] memory assets = PortfolioHandler.getSortedPortfolio(
            account,
            symbolicAccountContext.assetArrayLength
        );
        for (uint256 i; i < assets.length; i++) {
            if (i == 0) continue;
            assert(assets[i - 1].currencyId <= assets[i].currencyId);
            assert(assets[i - 1].maturity <= assets[i].maturity);
            assert(assets[i - 1].assetType <= assets[i].assetType);
        }
    }

    function getPortfolioCurrencyIdAtIndex(address account, uint256 index)
        external
        view
        returns (uint256)
    {
        PortfolioAsset[] memory assets = PortfolioHandler.getSortedPortfolio(
            account,
            symbolicAccountContext.assetArrayLength
        );
        return assets[index].currencyId;
    }

    function getNetCashGroupValue(
        address account,
        uint256 portfolioIndex,
        uint256 blockTime
    ) external view returns (int256, uint256) {
        PortfolioAsset[] memory assets = PortfolioHandler.getSortedPortfolio(
            account,
            symbolicAccountContext.assetArrayLength
        );
        return
            AssetHandler.getNetCashGroupValue(
                assets,
                symbolicCashGroup,
                symbolicMarket,
                blockTime,
                portfolioIndex
            );
    }

    function getifCashNetPresentValue(
        address account,
        uint256 blockTime,
        bool riskAdjusted
    ) external view returns (int256) {
        require(symbolicAccountContext.nextSettleTime >= blockTime);
        bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(
            account,
            symbolicAccountContext.bitmapCurrencyId
        );

        // prettier-ignore
        (int256 pv, /* hasDebt */) =
            BitmapAssetsHandler.getifCashNetPresentValue(
                account,
                symbolicAccountContext.bitmapCurrencyId,
                symbolicAccountContext.nextSettleTime,
                blockTime,
                assetsBitmap,
                symbolicCashGroup,
                riskAdjusted
            );

        return pv;
    }

    function getNumBitmapAssets(address account) external view returns (int256) {
        bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(
            account,
            symbolicAccountContext.bitmapCurrencyId
        );

        // Return int256 for comparison
        return int256(assetsBitmap.totalBitsSet());
    }
}

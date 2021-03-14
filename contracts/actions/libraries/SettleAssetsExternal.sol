// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../storage/PortfolioHandler.sol";
import "../../storage/SettleAssets.sol";

library SettleAssetsExternal {
    
    function settleAssetsView(
        address account,
        uint newAssetsHint,
        uint blockTime
    ) external view returns (PortfolioState memory, SettleAmount[] memory) {
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(account, newAssetsHint);
        SettleAmount[] memory settleAmounts = SettleAssets.getSettleAssetContextView(portfolioState, blockTime);

        return (portfolioState, settleAmounts);
    }

    function settleAssetsStateful(
        address account,
        uint newAssetsHint
    ) external returns (PortfolioState memory, SettleAmount[] memory) {
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(account, newAssetsHint);
        SettleAmount[] memory settleAmounts = SettleAssets.getSettleAssetContextStateful(portfolioState, block.timestamp);

        return (portfolioState, settleAmounts);
    }

    function settleBitmappedAccountView(
        address account,
        uint currencyId,
        uint nextMaturingAsset,
        uint blockTime
    ) external view returns (int) {
        PortfolioAsset[] memory ifCashAssets = BitmapAssetsHandler.getifCashArray(account, currencyId, nextMaturingAsset);
        uint[] memory sortedIndex = new uint[](ifCashAssets.length);
        // ifCash assets are already sorted
        for (uint i; i < sortedIndex.length; i++) sortedIndex[i] = i;

        PortfolioState memory portfolioState = PortfolioState({
            storedAssets: ifCashAssets,
            newAssets: new PortfolioAsset[](0),
            lastNewAssetIndex: 0,
            storedAssetLength: ifCashAssets.length,
            sortedIndex: sortedIndex
        });


        SettleAmount[] memory settleAmounts = SettleAssets.getSettleAssetContextView(portfolioState, blockTime);

        return settleAmounts[0].netCashChange;
    }

    function settleBitmappedAccountStateful(
        address account,
        uint currencyId,
        uint nextMaturingAsset
    ) external returns (bytes32, int) {
        return SettleAssets.settleBitmappedCashGroup(
            account,
            currencyId,
            nextMaturingAsset,
            block.timestamp
        );
    }
}
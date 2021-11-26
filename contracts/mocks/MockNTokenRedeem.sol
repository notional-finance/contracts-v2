// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../internal/nTokenHandler.sol";
import "../external/actions/nTokenRedeemAction.sol";

contract MockNTokenRedeemPure is nTokenRedeemAction {
    using Bitmap for bytes32;

    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        external pure returns (uint256, bool) {
        return DateTime.getBitNumFromMaturity(blockTime, maturity);
    }

    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        external pure returns (uint256) {
        return DateTime.getMaturityFromBitNum(blockTime, bitNum);
    }

    function setfCash(
        uint16 currencyId,
        address tokenAddress,
        uint256 maturity,
        uint256 lastInitializedTime,
        int256 fCash
    ) external {
        BitmapAssetsHandler.addifCashAsset(
            tokenAddress,
            currencyId,
            maturity,
            lastInitializedTime,
            fCash
        );
    }

    function test_getifCashBits(
        address tokenAddress,
        uint256 currencyId,
        uint256 lastInitializedTime,
        uint256 blockTime,
        uint256 maxMarketIndex
    ) external view returns (bytes32 ifCashBits) {
        ifCashBits = nTokenHandler.getifCashBits(tokenAddress, currencyId, lastInitializedTime, blockTime);
        uint256 bitNum = ifCashBits.getNextBitNum();

        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(blockTime, bitNum);
            // Test that we only receive ifcash here
            assert (DateTime.isValidMarketMaturity(maxMarketIndex, maturity, blockTime));

            ifCashBits = ifCashBits.setBit(bitNum, false);
            bitNum = ifCashBits.getNextBitNum();
        }
    }

    function reduceifCashAssetsProportional(
        address account,
        uint256 currencyId,
        uint256 lastInitializedTime,
        int256 tokensToRedeem,
        int256 totalSupply,
        bytes32 assetsBitmap
    ) public returns (PortfolioAsset[] memory) {
        return _reduceifCashAssetsProportional(
            account,
            currencyId,
            lastInitializedTime,
            tokensToRedeem,
            totalSupply,
            assetsBitmap
        );
    }

    function addResidualsToAssets(
        nTokenPortfolio memory nToken,
        PortfolioAsset[] memory newifCashAssets,
        int256[] memory netfCash
    ) public pure returns (PortfolioAsset[] memory finalfCashAssets) {
        return _addResidualsToAssets(nToken, newifCashAssets, netfCash);
    }
}

contract MockNTokenRedeem is nTokenRedeemAction {
    using nTokenHandler for nTokenPortfolio;
    using Market for MarketParameters;
    using PortfolioHandler for PortfolioState;

    function setCashGroup(uint256 id, CashGroupSettings calldata cg, AssetRateStorage calldata rs) external {
        CashGroup.setCashGroupStorage(id, cg);

        mapping(uint256 => AssetRateStorage) storage assetStore = LibStorage.getAssetRateStorage();
        assetStore[id] = rs;
    }

    function setMarketStorage(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) external {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function setfCash(
        uint16 currencyId,
        address tokenAddress,
        uint256 maturity,
        uint256 lastInitializedTime,
        int256 fCash
    ) external {
        BitmapAssetsHandler.addifCashAsset(
            tokenAddress,
            currencyId,
            maturity,
            lastInitializedTime,
            fCash
        );
    }

    function setNToken(
        uint16 currencyId,
        address tokenAddress,
        PortfolioState memory liquidityTokens,
        uint96 totalSupply,
        int256 cashBalance,
        uint256 lastInitializedTime
    ) external {
        nTokenHandler.setNTokenAddress(currencyId, tokenAddress);

        // Total Supply
        mapping(address => nTokenTotalSupplyStorage) storage store = LibStorage.getNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage storage nTokenStorage = store[tokenAddress];
        nTokenStorage.totalSupply = totalSupply;

        // Cash Balance
        BalanceHandler.setBalanceStorageForNToken(tokenAddress, currencyId, cashBalance);

        // Liquidity Tokens
        liquidityTokens.storeAssets(tokenAddress);
        nTokenHandler.setArrayLengthAndInitializedTime(
            tokenAddress,
            uint8(liquidityTokens.storedAssets.length),
            lastInitializedTime
        );

    }

    function getLiquidityTokenWithdraw(
        nTokenPortfolio memory nToken,
        int256 nTokensToRedeem,
        uint256 blockTime,
        bytes32 ifCashBits
    ) internal view returns (int256[] memory, int256[] memory) {
        return nTokenHandler.getLiquidityTokenWithdraw(
            nToken,
            nTokensToRedeem,
            blockTime,
            ifCashBits
        );
    }

    function getNToken(uint16 currencyId) external view returns (nTokenPortfolio memory nToken) {
        nToken.loadNTokenPortfolioView(currencyId);
    }

    function getNTokenMarketValue(nTokenPortfolio memory nToken, uint256 blockTime)
        public
        view
        returns (
            int256 totalAssetValue,
            int256[] memory netAssetValueInMarket,
            int256[] memory netfCash
        )
    {
        return nTokenHandler.getNTokenMarketValue(nToken, blockTime);
    }

    function redeem(
        uint16 currencyId,
        int256 tokensToRedeem,
        bool sellTokenAssets,
        bool acceptResidualAssets,
        uint256 blockTime
    ) public returns (int256, bool, PortfolioAsset[] memory) {
        return _redeem(currencyId, tokensToRedeem, sellTokenAssets, acceptResidualAssets, blockTime);
    }
}
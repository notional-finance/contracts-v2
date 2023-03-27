// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/nToken/nTokenHandler.sol";
import "../../internal/nToken/nTokenCalculations.sol";
import "../../internal/markets/InterestRateCurve.sol";
import "../../external/actions/nTokenRedeemAction.sol";
import "./MockSettingsLib.sol";
import "./AbstractSettingsRouter.sol";

contract MockNTokenRedeemPure {
    using Bitmap for bytes32;

    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        external pure returns (uint256, bool) {
        return DateTime.getBitNumFromMaturity(blockTime, maturity);
    }

    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        external pure returns (uint256) {
        return DateTime.getMaturityFromBitNum(blockTime, bitNum);
    }

    function setAssetsBitmap(
        address tokenAddress,
        uint256 currencyId,
        bytes32 assetsBitmap
    ) external {
        BitmapAssetsHandler.setAssetsBitmap(tokenAddress, currencyId, assetsBitmap);
    }

    function test_getNTokenifCashBits(
        address tokenAddress,
        uint256 currencyId,
        uint256 lastInitializedTime,
        uint256 blockTime,
        uint256 maxMarketIndex
    ) external view {
        bytes32 ifCashBits = nTokenCalculations.getNTokenifCashBits(tokenAddress, currencyId, lastInitializedTime, blockTime, maxMarketIndex);
        uint256 bitNum = ifCashBits.getNextBitNum();

        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(lastInitializedTime, bitNum);
            // Test that we only receive ifcash here
            require(!DateTime.isValidMarketMaturity(maxMarketIndex, maturity, lastInitializedTime));

            ifCashBits = ifCashBits.setBit(bitNum, false);
            bitNum = ifCashBits.getNextBitNum();
        }
    }

    function addResidualsToAssets(
        PortfolioAsset[] memory liquidityTokens,
        PortfolioAsset[] memory newifCashAssets,
        int256[] memory netfCash
    ) public pure returns (PortfolioAsset[] memory finalfCashAssets) {
        return nTokenRedeemAction._addResidualsToAssets(liquidityTokens, newifCashAssets, netfCash);
    }
}

contract MockNTokenRedeem is AbstractSettingsRouter {
    using nTokenHandler for nTokenPortfolio;

    event Redeem(int256 primeCash, bool hasResidual, PortfolioAsset[] assets);

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) {}

    function getNToken(uint16 currencyId) external view returns (nTokenPortfolio memory nToken) {
        nToken.loadNTokenPortfolioView(currencyId);
    }

    function reduceifCashAssetsProportional(
        address tokenAddress,
        uint16 currencyId,
        uint256 lastInitializedTime,
        int256 tokensToRedeem,
        int256 totalSupply
    ) public returns (PortfolioAsset[] memory) {
        bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(tokenAddress, currencyId);

        return nTokenRedeemAction._reduceifCashAssetsProportional(
            tokenAddress,
            currencyId,
            lastInitializedTime,
            tokensToRedeem,
            totalSupply,
            assetsBitmap
        );
    }


    function getLiquidityTokenWithdraw(
        nTokenPortfolio memory nToken,
        int256 nTokensToRedeem,
        uint256 blockTime,
        bytes32 ifCashBits
    ) public view returns (int256[] memory, int256[] memory) {
        return nTokenCalculations.getLiquidityTokenWithdraw(
            nToken,
            nTokensToRedeem,
            blockTime,
            ifCashBits
        );
    }

    function getNTokenMarketValue(nTokenPortfolio memory nToken, uint256 blockTime)
        public view returns (int256 totalAssetValue, int256[] memory netfCash)
    {
        return nTokenCalculations.getNTokenMarketValue(nToken, blockTime);
    }

    function redeem(
        uint16 currencyId,
        int256 tokensToRedeem,
        bool sellTokenAssets,
        bool acceptResidualAssets
    ) public returns (int256, bool, PortfolioAsset[] memory) {
        (int256 primeCash, PortfolioAsset[] memory assets)  = nTokenRedeemAction._redeem(
            msg.sender, currencyId, tokensToRedeem, sellTokenAssets, acceptResidualAssets
        );

        emit Redeem(primeCash, assets.length > 0, assets);
        return (primeCash, assets.length > 0, assets);
    }

}
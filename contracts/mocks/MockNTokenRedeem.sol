// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/nToken/nTokenHandler.sol";
import "../internal/nToken/nTokenCalculations.sol";
import "../external/actions/nTokenRedeemAction.sol";

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

    function reduceifCashAssetsProportional(
        address account,
        uint256 currencyId,
        uint256 lastInitializedTime,
        int256 tokensToRedeem,
        int256 totalSupply,
        bytes32 assetsBitmap
    ) public returns (PortfolioAsset[] memory) {
        return nTokenRedeemAction._reduceifCashAssetsProportional(
            account,
            currencyId,
            lastInitializedTime,
            tokensToRedeem,
            totalSupply,
            assetsBitmap
        );
    }

    function addResidualsToAssets(
        PortfolioAsset[] memory liquidityTokens,
        PortfolioAsset[] memory newifCashAssets,
        int256[] memory netfCash
    ) public pure returns (PortfolioAsset[] memory finalfCashAssets) {
        return nTokenRedeemAction._addResidualsToAssets(liquidityTokens, newifCashAssets, netfCash);
    }
}

contract MockNTokenRedeemBase {
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
        if (nTokenHandler.nTokenAddress(currencyId) == address(0)) {
            nTokenHandler.setNTokenAddress(currencyId, tokenAddress);
        }

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
            uint8(liquidityTokens.newAssets.length),
            lastInitializedTime
        );
    }

    function getNToken(uint16 currencyId) external view returns (nTokenPortfolio memory nToken) {
        nToken.loadNTokenPortfolioView(currencyId);
    }

}

contract MockNTokenRedeem1 is MockNTokenRedeemBase {

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
}

contract MockNTokenRedeem2 is MockNTokenRedeemBase {
    event Redeem(int256 assetCash, bool hasResidual, PortfolioAsset[] assets);

    function redeem(
        uint16 currencyId,
        int256 tokensToRedeem,
        bool sellTokenAssets,
        bool acceptResidualAssets,
        uint256 blockTime
    ) public returns (int256, bool, PortfolioAsset[] memory) {
        (
            int256 assetCash,
            bool hasResidual,
            PortfolioAsset[] memory assets
        )  = nTokenRedeemAction._redeem(currencyId, tokensToRedeem, sellTokenAssets, acceptResidualAssets, blockTime);

        emit Redeem(assetCash, hasResidual, assets);

        return (assetCash, hasResidual, assets);
    }

    function getfCashNotional(
        address account,
        uint16 currencyId,
        uint256 maturity
    ) external view returns (int256) {
        return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity);
    }

    /// @notice Returns the assets bitmap for an account
    function getAssetsBitmap(address account, uint16 currencyId)
        external
        view
        returns (bytes32)
    {
        return BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
    }

    function getMarket(
        uint16 currencyId,
        uint256 maturity,
        uint256 settlementDate,
        uint256 blockTime
    )
        external
        view
        returns (MarketParameters memory)
    {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        Market.loadMarketWithSettlementDate(
            market,
            currencyId,
            maturity,
            blockTime,
            true,
            CashGroup.getRateOracleTimeWindow(cashGroup),
            settlementDate
        );

        return market;
    }

}
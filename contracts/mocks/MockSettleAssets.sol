// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/AccountContextHandler.sol";
import "../internal/portfolio/BitmapAssetsHandler.sol";
import "../global/StorageLayoutV1.sol";
import "../internal/settlement/SettlePortfolioAssets.sol";
import "../internal/settlement/SettleBitmapAssets.sol";

contract MockSettleAssets is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;
    using AccountContextHandler for AccountContext;
    event BlockTime(uint256 blockTime, bool mustSettle);

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function getifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) public view returns (int256) {
        return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity);
    }

    function getAccountContext(address account) external view returns (AccountContext memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function setAssetArray(address account, PortfolioAsset[] memory a) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory state;
        state.newAssets = a;
        state.lastNewAssetIndex = a.length - 1;
        accountContext.storeAssetsAndUpdateContext(account, state, false);
        accountContext.setAccountContext(account);
    }

    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        require(id <= maxCurrencyId, "invalid currency id");
        mapping(uint256 => AssetRateStorage) storage assetStore = LibStorage.getAssetRateStorage();
        assetStore[id] = rs;
    }

    function setMarketState(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) external {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function getSettlementMarket(
        uint256 currencyId,
        uint256 maturity,
        uint256 settlementDate
    ) external view returns (MarketParameters memory s) {
        Market.loadSettlementMarket(s, currencyId, maturity, settlementDate);
    }

    function getSettlementRate(uint256 currencyId, uint256 maturity)
        external
        view
        returns (AssetRateParameters memory)
    {
        AssetRateParameters memory rate = AssetRate.buildSettlementRateView(currencyId, maturity);
        return rate;
    }

    function getAssetArray(address account) external view returns (PortfolioAsset[] memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
    }

    function setAccountContext(address account, AccountContext memory a) external {
        a.setAccountContext(account);
    }

    function setAssetBitmap(
        address account,
        uint256 id,
        bytes32 bitmap
    ) external {
        BitmapAssetsHandler.setAssetsBitmap(account, id, bitmap);
    }

    function setifCash(
        address account,
        uint256 currencyId,
        uint256 maturity,
        int256 notional,
        uint256 nextSettleTime
    ) external {
        BitmapAssetsHandler.addifCashAsset(
            account,
            currencyId,
            maturity,
            nextSettleTime,
            notional
        );
    }

    function setSettlementRate(
        uint256 currencyId,
        uint256 maturity,
        uint128 rate,
        uint8 underlyingDecimalPlaces
    ) external {
        uint256 blockTime = block.timestamp;
        mapping(uint256 => mapping(uint256 => SettlementRateStorage)) storage store = LibStorage.getSettlementRateStorage();
        SettlementRateStorage storage rateStorage = store[currencyId][maturity];
        rateStorage.blockTime = uint40(blockTime);
        rateStorage.settlementRate = rate;
        rateStorage.underlyingDecimalPlaces = underlyingDecimalPlaces;
    }

    event SettleAmountsCompleted(SettleAmount[] settleAmounts);

    function settlePortfolio(address account, uint256 blockTime) public {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory pState =
            PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);

        SettleAmount[] memory settleAmount =
            SettlePortfolioAssets.settlePortfolio(pState, blockTime);

        // This will change the stored asset array
        accountContext.storeAssetsAndUpdateContext(account, pState, false);
        accountContext.setAccountContext(account);

        emit SettleAmountsCompleted(settleAmount);
    }

    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        public
        pure
        returns (uint256)
    {
        uint256 maturity = DateTime.getMaturityFromBitNum(blockTime, bitNum);
        assert(maturity > blockTime);

        return maturity;
    }

    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        public
        pure
        returns (uint256, bool)
    {
        return DateTime.getBitNumFromMaturity(blockTime, maturity);
    }

    bytes32 public newBitmapStorage;
    int256 public totalAssetCash;

    function _settleBitmappedCashGroup(
        address account,
        uint256 currencyId,
        bytes32 bitmap,
        uint256 nextSettleTime,
        uint256 blockTime
    ) public {
        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, bitmap);

        (int256 newAssetCash, /* uint256 blockTimeUTC0 */) =
            SettleBitmapAssets.settleBitmappedCashGroup(
                account,
                currencyId,
                nextSettleTime,
                blockTime
            );

        newBitmapStorage = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
        totalAssetCash = newAssetCash;
    }

    function getAssetsBitmap(address account, uint256 currencyId) public view returns (bytes32) {
        return BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
    }

    function settleAccount(address account, uint256 currencyId, uint256 nextSettleTime, uint256 blockTime) external returns (int256, uint256) {
        (int256 newAssetCash, uint256 blockTimeUTC0) = SettleBitmapAssets.settleBitmappedCashGroup(
            account,
            currencyId,
            nextSettleTime,
            blockTime
        );

        return (newAssetCash, blockTimeUTC0);
    }

    function getifCashArray(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime
    ) external view returns (PortfolioAsset[] memory) {
        return BitmapAssetsHandler.getifCashArray(account, currencyId, nextSettleTime);
    }

    function getNextBitNum(bytes32 bitmap) external pure returns (uint256) {
        return Bitmap.getNextBitNum(bitmap);
    }

}

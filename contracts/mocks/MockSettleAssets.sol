// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/AccountContextHandler.sol";
import "../internal/portfolio/BitmapAssetsHandler.sol";
import "../global/StorageLayoutV1.sol";
import "../internal/settlement/SettleAssets.sol";

contract MockSettleAssets is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;
    using AccountContextHandler for AccountStorage;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function getifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) public view returns (int256) {
        return ifCashMapping[account][currencyId][maturity];
    }

    function setAssetArray(address account, PortfolioAsset[] memory a) external {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory state;
        state.newAssets = a;
        state.lastNewAssetIndex = a.length - 1;
        accountContext.storeAssetsAndUpdateContext(account, state);
        accountContext.setAccountContext(account);
    }

    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        require(id <= maxCurrencyId, "invalid currency id");
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setMarketState(
        uint256 currencyId,
        uint256 settlementDate,
        uint256 maturity,
        MarketParameters memory ms
    ) external {
        ms.storageSlot = Market.getSlot(currencyId, settlementDate, maturity);
        // ensure that state gets set
        ms.storageState = 0xFF;
        ms.setMarketStorage();
    }

    function getSettlementMarket(
        uint256 currencyId,
        uint256 maturity,
        uint256 settlementDate
    ) external view returns (SettlementMarket memory) {
        return Market.getSettlementMarket(currencyId, maturity, settlementDate);
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
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        return PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
    }

    function setAccountContext(address account, AccountStorage memory a) external {
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
        uint256 id,
        uint256 maturity,
        int256 notional
    ) external {
        ifCashMapping[account][id][maturity] = notional;
    }

    function setSettlementRate(
        uint256 currencyId,
        uint256 maturity,
        uint128 rate,
        uint8 underlyingDecimalPlaces
    ) external {
        uint256 blockTime = block.timestamp;
        bytes32 slot = keccak256(abi.encode(currencyId, maturity, "assetRate.settlement"));
        bytes32 data =
            (bytes32(blockTime) |
                (bytes32(uint256(rate)) << 40) |
                (bytes32(uint256(underlyingDecimalPlaces)) << 168));

        assembly {
            sstore(slot, data)
        }
    }

    function _getSettleAssetContextView(address account, uint256 blockTime)
        public
        view
        returns (SettleAmount[] memory, PortfolioState memory)
    {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory pStateView =
            PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        SettleAmount[] memory settleAmounts =
            SettleAssets.getSettleAssetContextView(pStateView, blockTime);

        return (settleAmounts, pStateView);
    }

    function testSettleAssetArray(address account, uint256 blockTime)
        public
        returns (SettleAmount[] memory)
    {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory pStateView =
            PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        PortfolioState memory pState =
            PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);

        SettleAmount[] memory settleAmountView =
            SettleAssets.getSettleAssetContextView(pStateView, blockTime);
        SettleAmount[] memory settleAmount =
            SettleAssets.getSettleAssetContextStateful(pState, blockTime);

        require(pStateView.storedAssetLength == pState.storedAssetLength); // dev: stored asset length equal
        require(pStateView.storedAssets.length == pState.storedAssets.length); // dev: stored asset array length equal
        // Assert that portfolio state is equal
        for (uint256 i; i < pStateView.storedAssets.length; i++) {
            require(pStateView.storedAssets[i].currencyId == pState.storedAssets[i].currencyId); // dev: asset currency id
            require(pStateView.storedAssets[i].assetType == pState.storedAssets[i].assetType); // dev: asset type
            require(pStateView.storedAssets[i].maturity == pState.storedAssets[i].maturity); // dev: maturity
            require(pStateView.storedAssets[i].notional == pState.storedAssets[i].notional); // dev: notional
            require(pStateView.storedAssets[i].storageState == pState.storedAssets[i].storageState); // dev: storage state
        }

        // This will change the stored asset array
        accountContext.storeAssetsAndUpdateContext(account, pState);
        accountContext.setAccountContext(account);

        // Assert that balance context is equal
        require(settleAmountView.length == settleAmount.length); // dev: settle amount length
        for (uint256 i; i < settleAmountView.length; i++) {
            require(settleAmountView[i].currencyId == settleAmount[i].currencyId); // dev: settle amount currency id
            require(settleAmountView[i].netCashChange == settleAmount[i].netCashChange); // dev: settle amount net cash change
        }

        return settleAmount;
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

        (bytes32 newBitmap, int256 newAssetCash) =
            SettleAssets.settleBitmappedCashGroup(account, currencyId, nextSettleTime, blockTime);

        newBitmapStorage = newBitmap;
        totalAssetCash = newAssetCash;
    }

    function _settleBitmappedAsset(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        uint256 bitNum,
        bytes32 bits
    ) public returns (bytes32, int256) {
        return
            SettleAssets.settleBitmappedAsset(
                account,
                currencyId,
                nextSettleTime,
                blockTime,
                bitNum,
                bits
            );
    }

    function _splitBitmap(bytes32 bitmap) public pure returns (SplitBitmap memory) {
        return Bitmap.splitAssetBitmap(bitmap);
    }

    function _combineBitmap(SplitBitmap memory bitmap) public pure returns (bytes32) {
        return Bitmap.combineAssetBitmap(bitmap);
    }

    function _remapBitSection(
        uint256 nextSettleTime,
        uint256 blockTimeUTC0,
        uint256 bitOffset,
        uint256 bitTimeLength,
        SplitBitmap memory bitmap,
        bytes32 bits
    ) public pure returns (SplitBitmap memory, bytes32) {
        bytes32 newBits =
            SettleAssets.remapBitSection(
                nextSettleTime,
                blockTimeUTC0,
                bitOffset,
                bitTimeLength,
                bitmap,
                bits
            );

        return (bitmap, newBits);
    }
}

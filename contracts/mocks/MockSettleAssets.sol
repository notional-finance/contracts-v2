// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/AccountContextHandler.sol";
import "../storage/BitmapAssetsHandler.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/SettleAssets.sol";

contract MockSettleAssets is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;
    using AccountContextHandler for AccountStorage;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function getifCashAsset(
        address account,
        uint currencyId,
        uint maturity
    ) public view returns (int) {
        return ifCashMapping[account][currencyId][maturity];
    }

    function setAssetArray(
        address account,
        AssetStorage[] memory a
    ) external {
        // Clear array
        delete assetArrayMapping[account];

        AssetStorage[] storage s = assetArrayMapping[account];
        for (uint i; i < a.length; i++) {
            s.push(a[i]);
        }
    }

    function setAssetRateMapping(
        uint id,
        AssetRateStorage calldata rs
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setMarketState(
        uint currencyId,
        uint settlementDate,
        uint maturity,
        MarketParameters memory ms
    ) external {
        ms.storageSlot = Market.getSlot(currencyId, settlementDate, maturity);
        // ensure that state gets set
        ms.storageState = 0xFF;
        ms.setMarketStorage();
    }

    function getSettlementMarket(
        uint currencyId,
        uint maturity,
        uint settlementDate
    ) external view returns (SettlementMarket memory) {
        return Market.getSettlementMarket(currencyId, maturity, settlementDate);
    }

    function getSettlementRate(
        uint currencyId,
        uint maturity
    ) external view returns (AssetRateParameters memory) {
        AssetRateParameters memory rate = AssetRate.buildSettlementRateView(currencyId, maturity);
        return rate;
    }

    function getAssetArray(address account) external view returns (AssetStorage[] memory) {
        return assetArrayMapping[account];
    }

    function setAccountContext(
        address account,
        AccountStorage memory a
    ) external {
        a.setAccountContext(account);
    }

    function setAssetBitmap(
        address account,
        uint id,
        bytes32 bitmap
    ) external {
        BitmapAssetsHandler.setAssetsBitmap(account, id, bitmap);
    }

    function setifCash(
        address account,
        uint id,
        uint maturity,
        int notional
    ) external {
        ifCashMapping[account][id][maturity] = notional;
    }

    function setSettlementRate(
        uint currencyId,
        uint maturity,
        uint128 rate,
        uint8 underlyingDecimalPlaces
    ) external {
        uint blockTime = block.timestamp;
        bytes32 slot = keccak256(abi.encode(currencyId, maturity, "assetRate.settlement"));
        bytes32 data = (
            bytes32(blockTime) |
            bytes32(uint(rate)) << 40 |
            bytes32(uint(underlyingDecimalPlaces)) << 168
        );

        assembly { sstore(slot, data) }
    }

    function _getSettleAssetContextView(
        address account,
        uint blockTime
    ) public view returns (SettleAmount[] memory, PortfolioState memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory pStateView = PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        SettleAmount[] memory settleAmounts = SettleAssets.getSettleAssetContextView(pStateView, blockTime);

        return (settleAmounts, pStateView);
    }

    function testSettleAssetArray(
        address account,
        uint blockTime
    ) public returns (SettleAmount[] memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory pStateView = PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        PortfolioState memory pState = PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);

        SettleAmount[] memory settleAmountView = SettleAssets.getSettleAssetContextView(pStateView, blockTime);
        SettleAmount[] memory settleAmount = SettleAssets.getSettleAssetContextStateful(pState, blockTime);

        require(pStateView.storedAssetLength == pState.storedAssetLength); // dev: stored asset length equal
        require(pStateView.storedAssets.length == pState.storedAssets.length); // dev: stored asset array length equal
        // Assert that portfolio state is equal
        for (uint i; i < pStateView.storedAssets.length; i++) {
            require(pStateView.storedAssets[i].currencyId == pState.storedAssets[i].currencyId); // dev: asset currency id
            require(pStateView.storedAssets[i].assetType == pState.storedAssets[i].assetType); // dev: asset type
            require(pStateView.storedAssets[i].maturity == pState.storedAssets[i].maturity); // dev: maturity
            require(pStateView.storedAssets[i].notional == pState.storedAssets[i].notional); // dev: notional
            require(pStateView.storedAssets[i].storageState == pState.storedAssets[i].storageState); // dev: storage state
        }

        // This will change the stored asset array
        pState.storeAssets(account, accountContext);

        // Assert that balance context is equal
        require(settleAmountView.length == settleAmount.length); // dev: settle amount length
        for (uint i; i < settleAmountView.length; i++) {
            require(settleAmountView[i].currencyId == settleAmount[i].currencyId); // dev: settle amount currency id
            require(settleAmountView[i].netCashChange == settleAmount[i].netCashChange); // dev: settle amount net cash change
        }

        return settleAmount;
    }

    function getMaturityFromBitNum(
        uint blockTime,
        uint bitNum
    ) public pure returns (uint) {
        uint maturity = CashGroup.getMaturityFromBitNum(blockTime, bitNum);
        assert(maturity > blockTime);

        return maturity;
    }

    function getBitNumFromMaturity(
        uint blockTime,
        uint maturity 
    ) public pure returns (uint, bool) {
        return CashGroup.getBitNumFromMaturity(blockTime, maturity);
    }

    bytes32 public newBitmapStorage;
    int public totalAssetCash;

    function _settleBitmappedCashGroup(
        address account,
        uint currencyId,
        bytes32 bitmap,
        uint nextMaturingAsset,
        uint blockTime
    ) public {
        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, bitmap);

        (bytes32 newBitmap, int newAssetCash) = SettleAssets.settleBitmappedCashGroup(
            account,
            currencyId,
            nextMaturingAsset,
            blockTime
        );

        newBitmapStorage = newBitmap;
        totalAssetCash = newAssetCash;
    }

    function _settleBitmappedAsset(
        address account,
        uint currencyId,
        uint nextMaturingAsset,
        uint blockTime,
        uint bitNum,
        bytes32 bits
    ) public returns (bytes32, int) {
        return SettleAssets.settleBitmappedAsset(
            account,
            currencyId,
            nextMaturingAsset,
            blockTime,
            bitNum,
            bits
        );
    }

    function _splitBitmap(
        bytes32 bitmap
    ) public pure returns (SplitBitmap memory) {
        return Bitmap.splitfCashBitmap(bitmap);
    }

    function _combineBitmap(
        SplitBitmap memory bitmap
    ) public pure returns (bytes32) {
        return Bitmap.combinefCashBitmap(bitmap);
    }

    function _remapBitSection(
        uint nextMaturingAsset,
        uint blockTimeUTC0,
        uint bitOffset,
        uint bitTimeLength,
        SplitBitmap memory bitmap,
        bytes32 bits
    ) public pure returns (SplitBitmap memory, bytes32) {
        bytes32 newBits = SettleAssets.remapBitSection(
            nextMaturingAsset,
            blockTimeUTC0,
            bitOffset,
            bitTimeLength,
            bitmap,
            bits
        );

        return (bitmap, newBits);
    }

}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/BitmapAssetsHandler.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/SettleAssets.sol";

contract MockSettleAssets is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;

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
        MarketParameters memory ms,
        uint settlementDate
    ) external {
        ms.setMarketStorage(settlementDate);
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
        (AssetRateParameters memory rate, /* */, /* */) = AssetRate.buildSettlementRateView(currencyId, maturity);
        return rate;
    }

    function getAssetArray(address account) external view returns (AssetStorage[] memory) {
        return assetArrayMapping[account];
    }

    function setAccountContext(
        address account,
        AccountStorage memory a
    ) external {
        accountContextMapping[account] = a;
    }

    function setAssetBitmap(
        address account,
        uint id,
        bytes memory bitmap
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
        uint16[] calldata currencyIds,
        uint blockTime
    ) public view returns (
        BalanceState[] memory,
        AccountStorage memory
    ) {
        AccountStorage memory aContextView = accountContextMapping[account];
        PortfolioState memory pStateView = PortfolioHandler.buildPortfolioState(account, 0);
        BalanceState[] memory bContextView = BalanceHandler.buildBalanceStateArray(account, currencyIds, aContextView);

        SettleAssets.getSettleAssetContextView(
            account,
            pStateView,
            aContextView,
            bContextView,
            blockTime
        );

        return (bContextView, aContextView);
    }

    function testSettleAssetArray(
        address account,
        uint16[] calldata currencyIds,
        uint blockTime
    ) public returns (
        BalanceState[] memory,
        AccountStorage memory
    ) {
        AccountStorage memory aContextView = accountContextMapping[account];
        PortfolioState memory pStateView = PortfolioHandler.buildPortfolioState(account, 0);
        BalanceState[] memory bContextView = BalanceHandler.buildBalanceStateArray(account, currencyIds, aContextView);
        AccountStorage memory aContext = accountContextMapping[account];
        PortfolioState memory pState = PortfolioHandler.buildPortfolioState(account, 0);
        BalanceState[] memory bContext = BalanceHandler.buildBalanceStateArray(account, currencyIds, aContext);

        SettleAssets.getSettleAssetContextView(
            account,
            pStateView,
            aContextView,
            bContextView,
            blockTime
        );

        SettleAssets.getSettleAssetContextStateful(
            account,
            pState,
            aContext,
            bContext,
            blockTime
        );

        assert(pStateView.storedAssetLength == pState.storedAssetLength);
        assert(pStateView.storedAssets.length == pState.storedAssets.length);
        // Assert that portfolio state is equal
        for (uint i; i < pStateView.storedAssets.length; i++) {
            assert(pStateView.storedAssets[i].currencyId == pState.storedAssets[i].currencyId);
            assert(pStateView.storedAssets[i].assetType == pState.storedAssets[i].assetType);
            assert(pStateView.storedAssets[i].maturity == pState.storedAssets[i].maturity);
            assert(pStateView.storedAssets[i].notional == pState.storedAssets[i].notional);
            assert(pStateView.storedAssets[i].storageState == pState.storedAssets[i].storageState);
        }

        // This will change the stored asset array
        pState.storeAssets(assetArrayMapping[account]);

        // Assert that balance context is equal
        assert(bContextView.length == bContext.length);
        for (uint i; i < bContextView.length; i++) {
            assert(bContextView[i].currencyId == bContext[i].currencyId);
            assert(bContextView[i].storedCashBalance == bContext[i].storedCashBalance);
            assert(bContextView[i].storedPerpetualTokenBalance == bContext[i].storedPerpetualTokenBalance);
            assert(bContextView[i].netCashChange == bContext[i].netCashChange);
        }

        return (bContext, aContext);
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

    bytes public newBitmapStorage;
    int public totalAssetCash;

    function _settleBitmappedCashGroup(
        address account,
        uint currencyId,
        bytes memory bitmap,
        uint nextMaturingAsset,
        uint blockTime
    ) public {
        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, bitmap);

        (bytes memory newBitmap, int newAssetCash) = SettleAssets.settleBitmappedCashGroup(
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
        bytes memory bitmap
    ) public pure returns (SplitBitmap memory) {
        return Bitmap.splitfCashBitmap(bitmap);
    }

    function _combineBitmap(
        SplitBitmap memory bitmap
    ) public pure returns (bytes memory) {
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

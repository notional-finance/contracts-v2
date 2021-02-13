// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageReader.sol";
import "./PortfolioHandler.sol";
import "./BalanceHandler.sol";
import "../common/AssetHandler.sol";
import "../common/AssetRate.sol";
import "../math/SafeInt256.sol";

contract SettleAssets is StorageReader {
    using SafeInt256 for int;
    using AssetRate for AssetRateParameters;
    using Bitmap for bytes;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;

    bytes32 internal constant ZERO = 0x0;
    bytes32 internal constant MSB_BIG_ENDIAN = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /**
     * @notice Provisions a balance context array for settling assets
     */
    function getSettleAssetBalanceContext(
        PortfolioState memory portfolioState,
        uint blockTime
    ) internal pure returns (BalanceState[] memory) {
        uint currenciesSettled;
        uint lastCurrencyId;
        // This is required for iteration
        portfolioState.calculateSortedIndex();

        for (uint i; i < portfolioState.sortedIndex.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[portfolioState.sortedIndex[i]];
            if (asset.getSettlementDate() > blockTime) continue;
            // Assume that this is sorted by cash group and maturity, currencyId = 0 is unused so this
            // will work for the first asset
            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                currenciesSettled++;
            }
        }

        // TODO: get the actual balance context here
        return new BalanceState[](currenciesSettled);
    }

    /**
     * @notice Shared calculation for liquidity token settlement
     */
    function calculateMarketStorage(
        PortfolioAsset memory asset
    ) internal view returns (int, int, SettlementMarket memory) {
        // 2x Storage Read
        SettlementMarket memory market = Market.getSettlementMarket(
            asset.currencyId,
            asset.maturity,
            asset.getSettlementDate()
        );

        int fCash = int(market.totalfCash).mul(asset.notional).div(market.totalLiquidity);
        int cashClaim = int(market.totalCurrentCash).mul(asset.notional).div(market.totalLiquidity);

        require(fCash <= market.totalfCash, "S: fCash overflow");
        require(cashClaim <= market.totalCurrentCash, "S: cash overflow");
        require(asset.notional <= market.totalLiquidity, "S: liquidity overflow");
        market.totalfCash = market.totalfCash - fCash;
        market.totalCurrentCash = market.totalCurrentCash - cashClaim;
        market.totalLiquidity = market.totalLiquidity - asset.notional;

        return (
            cashClaim,
            fCash,
            market
        );
    }

    /**
     * @notice Settles a liquidity token which requires getting the claims on both cash and fCash,
     * converting the fCash portion to cash at the settlement rate.
     */
    function settleLiquidityToken(
        PortfolioAsset memory asset,
        AssetRateParameters memory settlementRate
    ) internal view returns (int, SettlementMarket memory) {
        (int cashClaim, int fCash, SettlementMarket memory market) =
            calculateMarketStorage(asset);

        int assetCash = cashClaim.add(settlementRate.convertInternalFromUnderlying(fCash));

        return (assetCash, market);
    }

    /**
     * @notice Settles a liquidity token to idiosyncratic fCash
     */
    function settleLiquidityTokenTofCash(
        PortfolioState memory portfolioState,
        uint index
    ) internal view returns (int, SettlementMarket memory) {
        PortfolioAsset memory asset = portfolioState.storedAssets[index];
        (int cashClaim, int fCash, SettlementMarket memory market) =
            calculateMarketStorage(asset);

        if (fCash == 0) {
            // Skip some calculations
            portfolioState.deleteAsset(index);
        } else {
            // If the liquidity token's maturity is still in the future then we change the entry to be
            // an idiosyncratic fCash entry with the net fCash amount.
            portfolioState.storedAssets[index].assetType = AssetHandler.FCASH_ASSET_TYPE;
            portfolioState.storedAssets[index].notional = fCash;
            portfolioState.storedAssets[index].storageState = AssetStorageState.Update;
        }

        return (cashClaim, market);
    }

    /**
     * @notice View version of settle asset with a call to getSettlementRateView, the reason here is that
     * in the stateful version we will set the settlement rate if it is not set.
     */
    function getSettleAssetContextView(
        address account,
        PortfolioState memory portfolioState,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal view returns (BalanceState[] memory) {
        BalanceState[] memory balanceState = getSettleAssetBalanceContext(portfolioState, blockTime);
        AssetRateParameters memory settlementRate;
        BalanceState memory currentContext;
        uint currencyIndex;
        uint lastCurrencyId;
        uint lastMaturity;

        for (uint i; i < portfolioState.sortedIndex.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[portfolioState.sortedIndex[i]];
            if (asset.getSettlementDate() > blockTime) continue;

            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                lastMaturity = 0;
                // Storage Read inside getBalanceContext
                balanceState[currencyIndex] = BalanceHandler.buildBalanceState(
                    account,
                    lastCurrencyId,
                    accountContext.activeCurrencies
                );
                currentContext = balanceState[currencyIndex];
                currencyIndex++;
            }

            // Settlement rates are used to convert fCash and fCash claims back into assetCash values. This means
            // that settlement rates are required whenever fCash matures and when liquidity tokens' **fCash claims**
            // mature. fCash claims on liquidity tokens settle at asset.maturity, not the settlement date
            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
                // Storage Read inside getSettlementRateView
                settlementRate = getSettlementRateView(asset.currencyId, asset.maturity);
            }

            int assetCash;
            if (asset.assetType == AssetHandler.FCASH_ASSET_TYPE) {
                assetCash = settlementRate.convertInternalFromUnderlying(asset.notional);
                portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                if (asset.maturity > blockTime) {
                    (assetCash, /* */) = settleLiquidityTokenTofCash(
                        portfolioState,
                        portfolioState.sortedIndex[i]
                    );
                } else {
                    (assetCash, /* */) = settleLiquidityToken(
                        asset,
                        settlementRate
                    );
                    portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
                }
            }

            currentContext.netCashChange = currentContext.netCashChange.add(assetCash);
        }

        return balanceState;
    }

    /**
     * @notice Stateful version of settle asset, the only difference is the call to getSettlementRateStateful
     */
    function getSettleAssetContextStateful(
        address account,
        PortfolioState memory portfolioState,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal returns (BalanceState[] memory) {
        BalanceState[] memory balanceState = getSettleAssetBalanceContext(portfolioState, blockTime);
        AssetRateParameters memory settlementRate;
        BalanceState memory currentContext;
        uint currencyIndex;
        uint lastCurrencyId;
        uint lastMaturity;

        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[portfolioState.sortedIndex[i]];
            // TODO: This method calls `getSettlementDate` multiple times, reduce that
            if (asset.getSettlementDate() > blockTime) continue;

            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                lastMaturity = 0;
                // Storage Read
                balanceState[currencyIndex] = BalanceHandler.buildBalanceState(
                    account,
                    lastCurrencyId, 
                    accountContext.activeCurrencies
                );
                currentContext = balanceState[currencyIndex];
                currencyIndex++;
            }

            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
                // Storage Read / Write inside getSettlementRateStateful
                settlementRate = getSettlementRateStateful(asset.currencyId, asset.maturity, blockTime);
            }

            int assetCash;
            if (asset.assetType == AssetHandler.FCASH_ASSET_TYPE) {
                assetCash = settlementRate.convertInternalFromUnderlying(asset.notional);
                portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                // Deal with stack issues
                // TODO: optimize these functions to reduce stack usage and thereby reduce code size
                assetCash = settleLiquidityTokenStateful(
                    asset,
                    portfolioState,
                    settlementRate,
                    i,
                    blockTime
                );
            }

            currentContext.netCashChange = currentContext.netCashChange.add(assetCash);
        }

        return balanceState;
    }

    /** @notice Deals with stack issues above */
    function settleLiquidityTokenStateful(
        PortfolioAsset memory asset,
        PortfolioState memory portfolioState,
        AssetRateParameters memory settlementRate,
        uint i,
        uint blockTime
    ) internal returns (int) {
        int assetCash;
        SettlementMarket memory market;
        if (asset.maturity > blockTime) {
            (assetCash, market) = settleLiquidityTokenTofCash(
                portfolioState,
                portfolioState.sortedIndex[i]
            );
        } else {
            (assetCash, market) = settleLiquidityToken(
                asset,
                settlementRate
            );
            portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
        }

        // 2x storage write
        Market.setSettlementMarket(
            asset.currencyId,
            asset.maturity,
            asset.getSettlementDate(),
            market
        );

        return assetCash;
    }


    /**
     * @dev View version of getSettlementRate, if settlement rate is not set will fetch the most current rate.
     */
    function getSettlementRateView(
        uint currencyId,
        uint maturity
    ) internal view returns (AssetRateParameters memory) {
        // Storage Read
        SettlementRateStorage memory settlementRate = assetToUnderlyingSettlementRateMapping[currencyId][maturity];

        // Rate has not been set so we fetch the latest exchange rate
        if (settlementRate.timestamp == 0) {
            // Storage Read
            return AssetRate.buildAssetRate(currencyId);
        }

        return AssetRate.buildSettlementRate(settlementRate.rate);
    }

    /**
     * @dev View version of getSettlementRate, if settlement rate is not set will set it. Ideally, settlement rates
     * are set as close to maturity as possible but this may not always be possible. As long as all assets at a maturity
     * use the same settlement rate then we know that all balances will net out appropriately.
     */
    function getSettlementRateStateful(
        uint currencyId,
        uint maturity,
        uint blockTime
    ) internal returns (AssetRateParameters memory) {
        // Storage Read
        SettlementRateStorage memory settlementRate = assetToUnderlyingSettlementRateMapping[currencyId][maturity];

        // Rate has not been set so we fetch the latest exchange rate and set it
        if (settlementRate.timestamp == 0) {
            AssetRateParameters memory assetRate = AssetRate.buildAssetRate(currencyId);

            require(blockTime != 0 && blockTime <= type(uint40).max, "S: invalid timestamp");
            require(assetRate.rate > 0 && assetRate.rate <= type(uint128).max, "S: rate overflow");
            
            // Storage Write
            assetToUnderlyingSettlementRateMapping[currencyId][maturity] = SettlementRateStorage({
                rateDecimalPlaces: assetRate.rateDecimalPlaces,
                timestamp: uint40(blockTime),
                rate: uint128(assetRate.rate)
            });
            // TODO: emit event here

            return assetRate;
        }

        return AssetRate.buildSettlementRate(settlementRate.rate);
    }

    /**
     * @notice Stateful settlement function to settle a bitmapped asset. Deletes the
     * asset from storage after calculating it.
     */
    function settleBitmappedAsset(
        address account,
        uint currencyId,
        uint nextMaturingAsset,
        uint blockTime,
        uint bitNum,
        bytes32 bits
    ) internal returns (bytes32, int) {
        int assetCash;

        if ((bits & MSB_BIG_ENDIAN) == MSB_BIG_ENDIAN) {
            uint maturity = CashGroup.getMaturityFromBitNum(nextMaturingAsset, bitNum);
            // Storage Read
            int ifCash = ifCashMapping[account][currencyId][maturity];
            // Storage Read / Write
            AssetRateParameters memory rate = getSettlementRateStateful(
                currencyId,
                maturity,
                blockTime
            );
            assetCash = rate.convertInternalFromUnderlying(ifCash);
            // Storage Delete
            delete ifCashMapping[account][currencyId][maturity];
        }

        bits = bits << 1;

        return (bits, assetCash);
    }

    /**
     * @notice Given a bitmap for a cash group and timestamps, will settle all assets
     * that have matured and remap the bitmap to correspond to the current time.
     */
    function settleBitmappedCashGroup(
        address account,
        uint currencyId,
        bytes memory bitmap,
        uint nextMaturingAsset,
        uint blockTime
    ) internal returns (bytes memory, int) {
        int totalAssetCash;
        SplitBitmap memory splitBitmap = bitmap.splitfCashBitmap();
        uint blockTimeUTC0 = CashGroup.getTimeUTC0(blockTime);
        // This blockTimeUTC0 will be set to the new "nextMaturingAsset", this will refer to the
        // new next bit
        (uint lastSettleBit, /* isValid */) = CashGroup.getBitNumFromMaturity(nextMaturingAsset, blockTimeUTC0);
        if (lastSettleBit == 0) return (bitmap, totalAssetCash);

        // NOTE: bitNum is 1-indexed
        for (uint bitNum = 1; bitNum <= lastSettleBit; bitNum++) {
            if (bitNum <= CashGroup.WEEK_BIT_OFFSET) {
                if (splitBitmap.dayBits == ZERO) {
                    // No more bits set in day bits, continue to the next set of bits
                    bitNum = CashGroup.WEEK_BIT_OFFSET;
                    continue;
                }

                int assetCash;
                (splitBitmap.dayBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    splitBitmap.dayBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            if (bitNum <= CashGroup.MONTH_BIT_OFFSET) {
                if (splitBitmap.weekBits == ZERO) {
                    bitNum = CashGroup.MONTH_BIT_OFFSET;
                    continue;
                }

                int assetCash;
                (splitBitmap.weekBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    splitBitmap.weekBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            if (bitNum <= CashGroup.QUARTER_BIT_OFFSET) {
                if (splitBitmap.monthBits == ZERO) {
                    bitNum = CashGroup.QUARTER_BIT_OFFSET;
                    continue;
                }

                int assetCash;
                (splitBitmap.monthBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    splitBitmap.monthBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            // Check 1-indexing here
            if (bitNum <= 256) {
                if (splitBitmap.quarterBits == ZERO) {
                    break;
                }

                int assetCash;
                (splitBitmap.quarterBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    splitBitmap.quarterBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }
        }

        remapBitmap(
            splitBitmap,
            nextMaturingAsset,
            blockTimeUTC0,
            lastSettleBit
        );
        bitmap = Bitmap.combinefCashBitmap(splitBitmap);

        return (bitmap, totalAssetCash);
    }

    function remapBitmap(
        SplitBitmap memory splitBitmap,
        uint nextMaturingAsset,
        uint blockTimeUTC0,
        uint lastSettleBit
    ) internal pure {
        if (splitBitmap.weekBits != ZERO && lastSettleBit < CashGroup.MONTH_BIT_OFFSET) {
            // Ensures that if part of the week portion is settled we still remap the remaining part
            // starting from the lastSettleBit. Skips if the lastSettleBit is past the offset
            uint bitOffset = lastSettleBit > CashGroup.WEEK_BIT_OFFSET ? lastSettleBit : CashGroup.WEEK_BIT_OFFSET;
            splitBitmap.weekBits = remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0,
                bitOffset,
                CashGroup.WEEK,
                splitBitmap,
                splitBitmap.weekBits
            );
        }

        if (splitBitmap.monthBits != ZERO  && lastSettleBit < CashGroup.QUARTER_BIT_OFFSET) {
            uint bitOffset = lastSettleBit > CashGroup.MONTH_BIT_OFFSET ? lastSettleBit : CashGroup.MONTH_BIT_OFFSET;
            splitBitmap.monthBits = remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0,
                bitOffset,
                CashGroup.MONTH,
                splitBitmap,
                splitBitmap.monthBits
            );
        }

        if (splitBitmap.quarterBits != ZERO && lastSettleBit < 256) {
            uint bitOffset = lastSettleBit > CashGroup.QUARTER_BIT_OFFSET ? lastSettleBit : CashGroup.QUARTER_BIT_OFFSET;
            splitBitmap.quarterBits = remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0,
                bitOffset,
                CashGroup.QUARTER,
                splitBitmap,
                splitBitmap.quarterBits
            );
        }
    }

    /**
     * @dev Given a section of the bitmap, will remap active bits to a lower part of the bitmap.
     */
    function remapBitSection(
        uint nextMaturingAsset,
        uint blockTimeUTC0,
        uint bitOffset,
        uint bitTimeLength,
        SplitBitmap memory splitBitmap,
        bytes32 bits
    ) internal pure returns (bytes32) {
        // The first bit of the section is just above the bitOffset
        uint firstBitRef = CashGroup.getMaturityFromBitNum(nextMaturingAsset, bitOffset + 1);
        uint newFirstBitRef = CashGroup.getMaturityFromBitNum(blockTimeUTC0, bitOffset + 1);
        // NOTE: this will truncate the decimals
        uint bitsToShift = (newFirstBitRef - firstBitRef) / bitTimeLength;

        for (uint i; i < bitsToShift; i++) {
            if (bits == ZERO) break;

            if ((bits & MSB_BIG_ENDIAN) == MSB_BIG_ENDIAN) {
                // Map this into the lower section of the bitmap
                uint maturity = firstBitRef + i * bitTimeLength;
                (uint newBitNum, bool isValid) = CashGroup.getBitNumFromMaturity(blockTimeUTC0, maturity);
                require(isValid, "S: invalid maturity");

                if (newBitNum <= CashGroup.WEEK_BIT_OFFSET) {
                    // Shifting down into the day bits
                    bytes32 bitMask = MSB_BIG_ENDIAN >> (newBitNum - 1);
                    splitBitmap.dayBits = splitBitmap.dayBits | bitMask;
                } else if (newBitNum <= CashGroup.MONTH_BIT_OFFSET) {
                    // Shifting down into the week bits
                    bytes32 bitMask = MSB_BIG_ENDIAN >> (newBitNum - CashGroup.WEEK_BIT_OFFSET - 1);
                    splitBitmap.weekBits = splitBitmap.weekBits | bitMask;
                } else if (newBitNum <= CashGroup.QUARTER_BIT_OFFSET) {
                    // Shifting down into the month bits
                    bytes32 bitMask = MSB_BIG_ENDIAN >> (newBitNum - CashGroup.MONTH_BIT_OFFSET - 1);
                    splitBitmap.monthBits = splitBitmap.monthBits | bitMask;
                } else {
                    revert("S: error in shift");
                }
            }

            bits = bits << 1;
        }

        return bits;
    }

}

contract MockSettleAssets is SettleAssets {
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
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
        RateStorage calldata rs
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
        assetBitmapMapping[account][id] = bitmap;
    }

    function setifCash(
        address account,
        uint id,
        uint maturity,
        int notional
    ) external {
        ifCashMapping[account][id][maturity] = notional;
    }

    function setBalance(
        address account,
        uint id,
        BalanceStorage calldata bs
    ) external {
        accountBalanceMapping[account][id] = bs;
    }

    function setSettlementRate(
        uint id,
        uint maturity,
        SettlementRateStorage calldata sr
    ) external {
        assetToUnderlyingSettlementRateMapping[id][maturity] = sr;
    }

    function _getSettleAssetContextView(
        address account,
        uint blockTime
    ) public view returns (
        BalanceState[] memory,
        AccountStorage memory
    ) {
        (AccountStorage memory aContextView,
            PortfolioState memory pStateView) = getInitializeContext(account, blockTime, 0);

        BalanceState[] memory bContextView = getSettleAssetContextView(
            account,
            pStateView,
            aContextView,
            blockTime
        );

        return (bContextView, aContextView);
    }

    function testSettleAssetArray(
        address account,
        uint blockTime
    ) public returns (
        BalanceState[] memory,
        AccountStorage memory
    ) {
        (AccountStorage memory aContextView,
            PortfolioState memory pStateView) = getInitializeContext(account, blockTime, 0);
        (AccountStorage memory aContext,
            PortfolioState memory pState) = getInitializeContext(account, blockTime, 0);

        BalanceState[] memory bContextView = getSettleAssetContextView(
            account,
            pStateView,
            aContextView,
            blockTime
        );

        BalanceState[] memory bContext = getSettleAssetContextStateful(
            account,
            pState,
            aContext,
            blockTime
        );

        // assert(aContext.activeCurrencies == aContextView.activeCurrencies);
        // assert(aContext.nextMaturingAsset == aContextView.nextMaturingAsset);
        // assert(aContext.nextMaturingAsset > blockTime);

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
    ) public returns (bytes memory, int) {
        (bytes memory newBitmap, int newAssetCash) = settleBitmappedCashGroup(
            account,
            currencyId,
            bitmap,
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
        return settleBitmappedAsset(
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
        bytes32 newBits = remapBitSection(
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
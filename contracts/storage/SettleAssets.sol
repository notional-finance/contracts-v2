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
    ) internal view returns (int, int, MarketStorage memory, uint80) {
        // Storage Read
        MarketStorage memory marketStorage = marketStateMapping[asset.currencyId][asset.maturity];
        // Storage Read
        int totalLiquidity = marketTotalLiquidityMapping[asset.currencyId][asset.maturity];

        int fCash = int(marketStorage.totalfCash).mul(asset.notional).div(totalLiquidity);
        int cashClaim = int(marketStorage.totalCurrentCash).mul(asset.notional).div(totalLiquidity);

        require(fCash <= int(marketStorage.totalfCash), "S: fCash overflow");
        require(cashClaim <= int(marketStorage.totalCurrentCash), "S: cash overflow");
        require(asset.notional <= totalLiquidity, "S: liquidity overflow");
        marketStorage.totalfCash = marketStorage.totalfCash - uint80(fCash);
        marketStorage.totalCurrentCash = marketStorage.totalCurrentCash - uint80(cashClaim);

        return (
            cashClaim,
            fCash,
            marketStorage,
            // No truncation, totalLiquidity is stored as uint80
            uint80(totalLiquidity - asset.notional)
        );
    }

    /**
     * @notice Settles a liquidity token which requires getting the claims on both cash and fCash,
     * converting the fCash portion to cash at the settlement rate.
     */
    function settleLiquidityToken(
        PortfolioAsset memory asset,
        AssetRateParameters memory settlementRate
    ) internal view returns (int, MarketStorage memory, uint80) {
        (int cashClaim, int fCash, MarketStorage memory marketStorage, uint80 totalLiquidity) =
            calculateMarketStorage(asset);

        int assetCash = cashClaim.add(settlementRate.convertInternalFromUnderlying(fCash));

        return (
            assetCash,
            marketStorage,
            totalLiquidity
        );
    }

    /**
     * @notice Settles a liquidity token to idiosyncratic fCash
     */
    function settleLiquidityTokenTofCash(
        PortfolioState memory portfolioState,
        uint index
    ) internal view returns (int, MarketStorage memory, uint80) {
        PortfolioAsset memory asset = portfolioState.storedAssets[index];
        (int cashClaim, int fCash, MarketStorage memory marketStorage, uint80 totalLiquidity) =
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

        return (
            cashClaim,
            marketStorage,
            totalLiquidity
        );
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
                balanceState[currencyIndex] = BalanceHandler.buildBalanceState(account, lastCurrencyId, accountContext);
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
                    (assetCash, /* */, /* */) = settleLiquidityTokenTofCash(
                        portfolioState,
                        portfolioState.sortedIndex[i]
                    );
                } else {
                    (assetCash, /* */, /* */) = settleLiquidityToken(
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
            if (asset.getSettlementDate() > blockTime) continue;

            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                lastMaturity = 0;
                // Storage Read
                balanceState[currencyIndex] = BalanceHandler.buildBalanceState(account, lastCurrencyId, accountContext);
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
        MarketStorage memory marketState;
        uint80 totalLiquidity;
        if (asset.maturity > blockTime) {
            (assetCash, marketState, totalLiquidity) = settleLiquidityTokenTofCash(
                portfolioState,
                portfolioState.sortedIndex[i]
            );
        } else {
            (assetCash, marketState, totalLiquidity) = settleLiquidityToken(
                asset,
                settlementRate
            );
            portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
        }

        // In stateful we update the market as well.
        // Storage Write
        marketStateMapping[asset.currencyId][asset.maturity] = marketState;
        // Storage Write
        marketTotalLiquidityMapping[asset.currencyId][asset.maturity] = totalLiquidity;

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
        (
            bytes32 dayBits,
            bytes32 weekBits,
            bytes32 monthBits,
            bytes32 quarterBits
        ) = bitmap.splitfCashBitmap();
        uint blockTimeUTC0 = CashGroup.getTimeUTC0(blockTime);
        // This blockTimeUTC0 will be set to the new "nextMaturingAsset", this will refer to the
        // new next bit
        // TODO: check 1-indexing here
        uint lastSettleBit = CashGroup.getBitNumFromMaturity(nextMaturingAsset, blockTimeUTC0);

        // NOTE: bitNum is 1-indexed
        for (uint bitNum = 1; bitNum < lastSettleBit; bitNum++) {
            if (bitNum < CashGroup.WEEK_BIT_OFFSET) {
                if (dayBits == ZERO) {
                    // No more bits set in day bits, continue to the next set of bits
                    bitNum = CashGroup.WEEK_BIT_OFFSET;
                    continue;
                }

                (dayBits, totalAssetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    dayBits
                );
            }

            if (bitNum < CashGroup.MONTH_BIT_OFFSET) {
                if (weekBits == ZERO) {
                    bitNum = CashGroup.MONTH_BIT_OFFSET;
                    continue;
                }

                (weekBits, totalAssetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    weekBits
                );
            }

            if (bitNum < CashGroup.QUARTER_BIT_OFFSET) {
                if (monthBits == ZERO) {
                    bitNum = CashGroup.QUARTER_BIT_OFFSET;
                    continue;
                }

                (monthBits, totalAssetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    monthBits
                );
            }

            // Check 1-indexing here
            if (bitNum <= 256) {
                if (quarterBits == ZERO) {
                    break;
                }

                (quarterBits, totalAssetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    quarterBits
                );
            }
        }

        bitmap = Bitmap.combinefCashBitmap(dayBits, weekBits, monthBits, quarterBits);
        if (weekBits != ZERO && lastSettleBit < CashGroup.WEEK_BIT_OFFSET) {
            remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0,
                CashGroup.WEEK_BIT_OFFSET,
                CashGroup.WEEK,
                bitmap,
                weekBits
            );
        }

        if (monthBits != ZERO && lastSettleBit < CashGroup.MONTH_BIT_OFFSET) {
            remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0,
                CashGroup.MONTH_BIT_OFFSET,
                CashGroup.MONTH,
                bitmap,
                monthBits
            );
        }

        if (quarterBits != ZERO && lastSettleBit < CashGroup.QUARTER_BIT_OFFSET) {
            remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0,
                CashGroup.QUARTER_BIT_OFFSET,
                CashGroup.QUARTER,
                bitmap,
                quarterBits
            );
        }

        return (bitmap, totalAssetCash);
    }

    /**
     * @dev Given a section of the bitmap, will remap active bits to a lower part of the bitmap.
     */
    function remapBitSection(
        uint nextMaturingAsset,
        uint blockTimeUTC0,
        uint bitOffset,
        uint bitTimeLength,
        bytes memory bitmap,
        bytes32 bits
    ) internal pure {
        uint firstBitRef = CashGroup.getMaturityFromBitNum(nextMaturingAsset, bitOffset);
        uint newFirstBitRef = CashGroup.getMaturityFromBitNum(blockTimeUTC0, bitOffset);
        uint bitsToShift = (newFirstBitRef - firstBitRef) / bitTimeLength;

        for (uint i; i < bitsToShift; i++) {
            if (bits == ZERO) break;

            if ((bits & MSB_BIG_ENDIAN) == MSB_BIG_ENDIAN) {
                // Map this into the lower section of the bitmap
                uint maturity = firstBitRef + i * bitOffset;
                uint newBitNum = CashGroup.getBitNumFromMaturity(blockTimeUTC0, maturity);
                bitmap.setBit(newBitNum, true);
            }

            bits = bits << 1;
        }
    }

}

contract MockSettleAssets is SettleAssets {
    using PortfolioHandler for PortfolioState;

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
        uint id,
        uint maturity,
        MarketStorage calldata ms,
        uint80 totalLiquidity
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        marketStateMapping[id][maturity] = ms;
        marketTotalLiquidityMapping[id][maturity] = totalLiquidity;
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

}
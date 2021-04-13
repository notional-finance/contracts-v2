// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../AccountContextHandler.sol";
import "../markets/AssetRate.sol";
import "../markets/CashGroup.sol";
import "../valuation/AssetHandler.sol";
import "../PerpetualToken.sol";
import "../../math/Bitmap.sol";
import "../../math/SafeInt256.sol";
import "../../global/Constants.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library BitmapAssetsHandler {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using Bitmap for bytes32;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;

    uint256 internal constant IFCASH_STORAGE_SLOT = 3;

    function getAssetsBitmap(address account, uint256 currencyId) internal view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(account, currencyId, "assets.bitmap"));
        bytes32 data;
        assembly {
            data := sload(slot)
        }
        return data;
    }

    function setAssetsBitmap(
        address account,
        uint256 currencyId,
        bytes32 assetsBitmap
    ) internal {
        bytes32 slot = keccak256(abi.encode(account, currencyId, "assets.bitmap"));
        assembly {
            sstore(slot, assetsBitmap)
        }
    }

    function getifCashSlot(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    maturity,
                    keccak256(
                        abi.encode(currencyId, keccak256(abi.encode(account, IFCASH_STORAGE_SLOT)))
                    )
                )
            );
    }

    function getifCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) internal view returns (int256) {
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        int256 notional;
        assembly {
            notional := sload(fCashSlot)
        }
        return notional;
    }

    function addMultipleifCashAssets(
        address account,
        AccountStorage memory accountContext,
        PortfolioAsset[] memory assets
    ) internal {
        uint256 currencyId = accountContext.bitmapCurrencyId;
        require(currencyId != 0); // dev: invalid account in set ifcash assets
        bytes32 ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);

        for (uint256 i; i < assets.length; i++) {
            if (assets[i].notional == 0) continue;
            require(assets[i].currencyId == currencyId); // dev: invalid asset in set ifcash assets
            require(assets[i].assetType == AssetHandler.FCASH_ASSET_TYPE); // dev: invalid asset in set ifcash assets
            int256 finalNotional;

            (ifCashBitmap, finalNotional) = addifCashAsset(
                account,
                currencyId,
                assets[i].maturity,
                accountContext.nextSettleTime,
                assets[i].notional,
                ifCashBitmap
            );

            if (finalNotional < 0)
                accountContext.hasDebt =
                    accountContext.hasDebt |
                    AccountContextHandler.HAS_ASSET_DEBT;
        }

        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, ifCashBitmap);
    }

    /**
     * @notice Add an ifCash asset in the bitmap and mapping. Updates the bitmap in memory
     * but not in storage.
     */
    function addifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 nextSettleTime,
        int256 notional,
        bytes32 assetsBitmap
    ) internal returns (bytes32, int256) {
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        (uint256 bitNum, bool isExact) = CashGroup.getBitNumFromMaturity(nextSettleTime, maturity);
        require(isExact); // dev: invalid maturity in set ifcash asset

        if (assetsBitmap.isBitSet(bitNum)) {
            // Bit is set so we read and update the notional amount
            int256 existingNotional;
            assembly {
                existingNotional := sload(fCashSlot)
            }
            existingNotional = existingNotional.add(notional);
            assembly {
                sstore(fCashSlot, existingNotional)
            }

            // If the new notional is zero then turn off the bit
            if (existingNotional == 0) {
                assetsBitmap = assetsBitmap.setBit(bitNum, false);
            }

            return (assetsBitmap, existingNotional);
        }

        // Bit is not set so we turn it on and update the mapping directly, no read required.
        assembly {
            sstore(fCashSlot, notional)
        }
        assetsBitmap = assetsBitmap.setBit(bitNum, true);

        return (assetsBitmap, notional);
    }

    function getPresentValue(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) internal view returns (int256) {
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        int256 notional;
        assembly {
            notional := sload(fCashSlot)
        }

        // In this case the asset has matured and the total value is set
        if (maturity <= blockTime) return notional;

        uint256 oracleRate = cashGroup.getOracleRate(markets, maturity, blockTime);
        if (riskAdjusted) {
            return
                AssetHandler.getRiskAdjustedPresentValue(
                    cashGroup,
                    notional,
                    maturity,
                    blockTime,
                    oracleRate
                );
        }

        return AssetHandler.getPresentValue(notional, maturity, blockTime, oracleRate);
    }

    /**
     * @notice Get the net present value of all the ifCash assets
     */
    function getifCashNetPresentValue(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        bytes32 assetsBitmap,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) internal view returns (int256, bool) {
        int256 totalValueUnderlying;
        uint256 bitNum = 1;
        bool hasDebt;

        while (assetsBitmap != 0) {
            if (assetsBitmap & Constants.MSB == Constants.MSB) {
                uint256 maturity = CashGroup.getMaturityFromBitNum(nextSettleTime, bitNum);
                int256 pv =
                    getPresentValue(
                        account,
                        currencyId,
                        maturity,
                        blockTime,
                        cashGroup,
                        markets,
                        riskAdjusted
                    );
                totalValueUnderlying = totalValueUnderlying.add(pv);

                if (pv < 0) hasDebt = true;
            }

            assetsBitmap = assetsBitmap << 1;
            bitNum += 1;
        }

        return (totalValueUnderlying, hasDebt);
    }

    function getifCashArray(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime
    ) internal view returns (PortfolioAsset[] memory) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        uint256 bitNum = 1;
        index = 0;

        while (assetsBitmap != 0) {
            if (assetsBitmap & Constants.MSB == Constants.MSB) {
                uint256 maturity = CashGroup.getMaturityFromBitNum(nextSettleTime, bitNum);
                int256 notional;
                {
                    bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
                    assembly {
                        notional := sload(fCashSlot)
                    }
                }

                assets[index].currencyId = currencyId;
                assets[index].maturity = maturity;
                assets[index].assetType = AssetHandler.FCASH_ASSET_TYPE;
                assets[index].notional = notional;
                index += 1;
            }

            assetsBitmap = assetsBitmap << 1;
            bitNum += 1;
        }

        return assets;
    }

    /**
     * @notice Used to reduce a perpetual token ifCash assets portfolio proportionately when redeeming
     * perpetual tokens to its underlying assets.
     */
    function reduceifCashAssetsProportional(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        int256 tokensToRedeem,
        int256 totalSupply
    ) internal returns (PortfolioAsset[] memory) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        uint256 bitNum = 1;
        index = 0;

        while (assetsBitmap != 0) {
            if (assetsBitmap & Constants.MSB == Constants.MSB) {
                uint256 maturity = CashGroup.getMaturityFromBitNum(nextSettleTime, bitNum);
                bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
                int256 notional;
                assembly {
                    notional := sload(fCashSlot)
                }

                int256 notionalToTransfer = notional.mul(tokensToRedeem).div(totalSupply);
                notional = notional.sub(notionalToTransfer);
                assembly {
                    sstore(fCashSlot, notional)
                }

                assets[index].currencyId = currencyId;
                assets[index].maturity = maturity;
                assets[index].assetType = AssetHandler.FCASH_ASSET_TYPE;
                assets[index].notional = notionalToTransfer;
                index += 1;
            }

            assetsBitmap = assetsBitmap << 1;
            bitNum += 1;
        }

        // If the entire token supply is redeemed then the assets bitmap will have been reduced to zero.
        // Because solidity truncates division there will always be dust left unless the entire supply is
        // redeemed.
        if (tokensToRedeem == totalSupply) {
            setAssetsBitmap(account, currencyId, 0x00);
        }

        return assets;
    }

    /**
     * @notice If a perpetual token incurs a negative fCash residual as a result of lending, this means
     * that we are going to need to withold some amount of cash so that market makers can purchase and
     * clear the debts off the balance sheet.
     */
    function getPerpetualTokenNegativefCashWithholding(
        PerpetualTokenPortfolio memory perpToken,
        uint256 blockTime,
        bytes32 assetsBitmap
    ) internal view returns (int256) {
        int256 totalCashWithholding;
        uint256 bitNum = 1;
        // This buffer is denominated in 10 basis point increments. It is used to shift the withholding rate to ensure
        // that sufficient cash is withheld for negative fCash balances.
        uint256 oracleRateBuffer =
            uint256(uint8(perpToken.parameters[PerpetualToken.CASH_WITHHOLDING_BUFFER])) *
                10 *
                Market.BASIS_POINT;

        while (assetsBitmap != 0) {
            if (assetsBitmap & Constants.MSB == Constants.MSB) {
                uint256 maturity =
                    CashGroup.getMaturityFromBitNum(perpToken.lastInitializedTime, bitNum);
                int256 notional =
                    getifCashNotional(
                        perpToken.tokenAddress,
                        perpToken.cashGroup.currencyId,
                        maturity
                    );

                // Withholding only applies for negative cash balances
                if (notional < 0) {
                    // This is only calculated during initialize markets action, therefore we get the market
                    // index referenced in the previous quarter because the markets array refers to previous
                    // markets in this case.
                    (uint256 marketIndex, bool idiosyncratic) =
                        perpToken.cashGroup.getMarketIndex(maturity, blockTime - CashGroup.QUARTER);
                    // NOTE: If idiosyncratic cash survives a quarter without being purchased this will fail
                    require(!idiosyncratic); // dev: fail on market index

                    uint256 oracleRate = perpToken.markets[marketIndex - 1].oracleRate;
                    if (oracleRateBuffer > oracleRate) {
                        oracleRate = 0;
                    } else {
                        oracleRate = oracleRate.sub(oracleRateBuffer);
                    }

                    totalCashWithholding = totalCashWithholding.sub(
                        AssetHandler.getPresentValue(notional, maturity, blockTime, oracleRate)
                    );
                }
            }

            assetsBitmap = assetsBitmap << 1;
            bitNum += 1;
        }

        return perpToken.cashGroup.assetRate.convertInternalFromUnderlying(totalCashWithholding);
    }
}

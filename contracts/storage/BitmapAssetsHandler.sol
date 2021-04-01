// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/AssetRate.sol";
import "../common/CashGroup.sol";
import "../common/AssetHandler.sol";
import "../common/PerpetualToken.sol";
import "../math/Bitmap.sol";
import "../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library BitmapAssetsHandler {
    using SafeMath for uint;
    using SafeInt256 for int;
    using Bitmap for bytes32;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;

    uint internal constant IFCASH_STORAGE_SLOT = 3;

    function getAssetsBitmap(
        address account,
        uint currencyId
    ) internal view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(account, currencyId, "assets.bitmap"));
        bytes32 data;
        assembly { data := sload(slot) }
        return data;
    }

    function setAssetsBitmap(
        address account,
        uint currencyId,
        bytes32 assetsBitmap
    ) internal {
        bytes32 slot = keccak256(abi.encode(account, currencyId, "assets.bitmap"));
        assembly { sstore(slot, assetsBitmap) }
    }

    function getifCashSlot(
        address account,
        uint currencyId,
        uint maturity
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(maturity,
            keccak256(abi.encode(currencyId,
                keccak256(abi.encode(account, IFCASH_STORAGE_SLOT))
            ))
        ));
    }

    function getifCashNotional(
        address account,
        uint currencyId,
        uint maturity
    ) internal view returns (int) {
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        int notional;
        assembly { notional := sload(fCashSlot) }
        return notional;
    }

    /**
     * @notice Set an ifCash asset in the bitmap and mapping. Updates the bitmap in memory but not in storage.
     */
    function setifCashAsset(
        address account,
        uint currencyId,
        uint maturity,
        uint nextSettleTime,
        int notional,
        bytes32 assetsBitmap
    ) internal returns (bytes32) {
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        (uint bitNum, bool isExact) = CashGroup.getBitNumFromMaturity(nextSettleTime, maturity);
        require(isExact); // dev: invalid maturity in set ifcash asset

        if (assetsBitmap.isBitSet(bitNum)) {
            // Bit is set so we read and update the notional amount
            int existingNotional;
            assembly { existingNotional := sload(fCashSlot) }
            existingNotional = existingNotional.add(notional);
            assembly { sstore(fCashSlot, existingNotional) }

            // If the new notional is zero then turn off the bit
            if (existingNotional == 0) {
                assetsBitmap = assetsBitmap.setBit(bitNum, false);
            }
        } else {
            // Bit is not set so we turn it on and update the mapping directly, no read required.
            assembly { sstore(fCashSlot, notional) }
            assetsBitmap = assetsBitmap.setBit(bitNum, true);
        }

        return assetsBitmap;
    }

    function getPresentValue(
        address account,
        uint currencyId,
        uint maturity,
        uint blockTime,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) internal view returns (int) {
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        int notional;
        assembly { notional := sload(fCashSlot) }

        // In this case the asset has matured and the total value is set
        if (maturity <= blockTime) return notional;

        uint oracleRate = cashGroup.getOracleRate(markets, maturity, blockTime);
        if (riskAdjusted) {
            return AssetHandler.getRiskAdjustedPresentValue(
                cashGroup,
                notional,
                maturity,
                blockTime,
                oracleRate
            );
        }

        return AssetHandler.getPresentValue(
            notional,
            maturity,
            blockTime,
            oracleRate
        );
    }

    /**
     * @notice Get the net present value of all the ifCash assets
     */
    function getifCashNetPresentValue(
        address account,
        uint currencyId,
        uint nextSettleTime,
        uint blockTime,
        bytes32 assetsBitmap,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) internal view returns (int, bool) {
        int totalValueUnderlying;
        uint bitNum = 1;
        bool hasDebt;

        while (assetsBitmap != 0) {
            if (assetsBitmap & Bitmap.MSB == Bitmap.MSB) {
                uint maturity = CashGroup.getMaturityFromBitNum(nextSettleTime, bitNum);
                int pv = getPresentValue(
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
        uint currencyId,
        uint nextSettleTime
    ) internal view returns (PortfolioAsset[] memory) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        uint bitNum = 1;
        index = 0;

        while (assetsBitmap != 0) {
            if (assetsBitmap & Bitmap.MSB == Bitmap.MSB) {
                uint maturity = CashGroup.getMaturityFromBitNum(nextSettleTime, bitNum);
                int notional;
                {
                    bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
                    assembly { notional := sload(fCashSlot) }
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
        uint currencyId,
        uint nextSettleTime,
        int tokensToRedeem,
        int totalSupply
    ) internal returns (PortfolioAsset[] memory) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        uint bitNum = 1;
        index = 0;

        while (assetsBitmap != 0) {
            if (assetsBitmap & Bitmap.MSB == Bitmap.MSB) {
                uint maturity = CashGroup.getMaturityFromBitNum(nextSettleTime, bitNum);
                bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
                int notional;
                assembly { notional := sload(fCashSlot) }

                int notionalToTransfer = notional.mul(tokensToRedeem).div(totalSupply);
                notional = notional.sub(notionalToTransfer);
                assembly { sstore(fCashSlot, notional) }

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
        uint blockTime,
        bytes32 assetsBitmap
    ) internal view returns (int) {
        int totalCashWithholding;
        uint bitNum = 1;
        // This buffer is denominated in 10 basis point increments. It is used to shift the withholding rate to ensure
        // that sufficient cash is withheld for negative fCash balances.
        uint oracleRateBuffer = uint(uint8(perpToken.parameters[PerpetualToken.CASH_WITHHOLDING_BUFFER])) * 10 * Market.BASIS_POINT;

        while (assetsBitmap != 0) {
            if (assetsBitmap & Bitmap.MSB == Bitmap.MSB) {
                uint maturity = CashGroup.getMaturityFromBitNum(perpToken.lastInitializedTime, bitNum);
                int notional = getifCashNotional(perpToken.tokenAddress, perpToken.cashGroup.currencyId, maturity);

                if (notional < 0) {
                    (
                        uint marketIndex,
                        bool idiosyncratic
                    ) = perpToken.cashGroup.getMarketIndex(maturity, blockTime - CashGroup.QUARTER);
                    require(!idiosyncratic); // dev: fail on market index
                    uint oracleRate = perpToken.markets[marketIndex - 1].oracleRate;
                    oracleRate = oracleRate.add(oracleRateBuffer);

                    totalCashWithholding = totalCashWithholding.sub(AssetHandler.getPresentValue(
                        notional,
                        maturity,
                        blockTime,
                        oracleRate
                    ));
                }
            }

            assetsBitmap = assetsBitmap << 1;
            bitNum += 1;
        }

        return perpToken.cashGroup.assetRate.convertInternalFromUnderlying(totalCashWithholding);
    }
}
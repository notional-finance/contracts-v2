// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "../math/ABDKMath64x64.sol";
import "./CashGroup.sol";
import "./AssetRate.sol";
import "../storage/PortfolioHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

enum AssetStorageState {
    NoChange,
    Update,
    Delete
}

struct PortfolioAsset {
    // Asset currency id
    uint currencyId;
    uint maturity;
    // Asset type, fCash or liquidity token.
    uint assetType;
    // fCash amount or liquidity token amount
    int notional;
    // The state of the asset for when it is written to storage
    AssetStorageState storageState;
}

library AssetHandler {
    using SafeMath for uint256;
    using SafeInt256 for int;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;

    uint internal constant FCASH_ASSET_TYPE = 1;
    uint internal constant LIQUIDITY_TOKEN_INDEX1 = 2;
    uint internal constant LIQUIDITY_TOKEN_INDEX2 = 3;
    uint internal constant LIQUIDITY_TOKEN_INDEX3 = 4;
    uint internal constant LIQUIDITY_TOKEN_INDEX4 = 5;
    uint internal constant LIQUIDITY_TOKEN_INDEX5 = 6;
    uint internal constant LIQUIDITY_TOKEN_INDEX6 = 7;
    uint internal constant LIQUIDITY_TOKEN_INDEX7 = 8;
    uint internal constant LIQUIDITY_TOKEN_INDEX8 = 9;
    uint internal constant LIQUIDITY_TOKEN_INDEX9 = 10;

    function isLiquidityToken(uint assetType) internal pure returns (bool) {
        return assetType >= LIQUIDITY_TOKEN_INDEX1 && assetType <= LIQUIDITY_TOKEN_INDEX9;
    }

    /**
     * @notice Liquidity tokens settle every 90 days (not at the designated maturity). This method
     * calculates the settlement date for any PortfolioAsset.
     */
    function getSettlementDate(
        PortfolioAsset memory asset
    ) internal pure returns (uint) {
        return getSettlementDateViaAssetType(asset.assetType, asset.maturity);
    }

    function getSettlementDateViaAssetType(
        uint assetType,
        uint maturity
    ) internal pure returns (uint) {
        require(assetType > 0 && assetType <= LIQUIDITY_TOKEN_INDEX9); // dev: settlement date invalid asset type
        // 3 month tokens and fCash tokens settle at maturity
        if (assetType <= LIQUIDITY_TOKEN_INDEX1) return maturity;

        uint marketLength = CashGroup.getTradedMarket(assetType - 1);
        // Liquidity tokens settle at tRef + 90 days. The formula to get a maturity is:
        // maturity = tRef + marketLength
        // Here we calculate:
        // tRef = maturity - marketLength + 90 days
        return maturity.sub(marketLength).add(CashGroup.QUARTER);
    }

    /**
     * @notice Returns the compound rate given an oracle rate and a time to maturity. The formula is:
     * notional * e^(-rate * timeToMaturity).
     */
    function getDiscountFactor(
        uint timeToMaturity,
        uint oracleRate
    ) internal pure returns (int) {
        int128 expValue = ABDKMath64x64.fromUInt(
            oracleRate.mul(timeToMaturity).div(Market.IMPLIED_RATE_TIME)
        );
        expValue = ABDKMath64x64.div(expValue, Market.RATE_PRECISION_64x64);
        expValue = ABDKMath64x64.exp(expValue * -1);
        expValue = ABDKMath64x64.mul(expValue, Market.RATE_PRECISION_64x64);
        int discountFactor = ABDKMath64x64.toInt(expValue);

        return discountFactor;
    }

    /**
     * @notice Present value of an fCash asset without any risk adjustments.
     */
    function getPresentValue(
        int notional,
        uint maturity,
        uint blockTime,
        uint oracleRate
    ) internal pure returns (int) {
        if (notional == 0) return 0;

        uint timeToMaturity = maturity.sub(blockTime);
        int discountFactor = getDiscountFactor(timeToMaturity, oracleRate);

        require(discountFactor <= Market.RATE_PRECISION); // dev: get present value invalid discount factor
        return notional.mul(discountFactor).div(Market.RATE_PRECISION);
    }

    /**
     * @notice Present value of an fCash asset with risk adjustments. Positive fCash value will be discounted more
     * heavily than the oracle rate given and vice versa for negative fCash.
     */
    function getRiskAdjustedPresentValue(
        CashGroupParameters memory cashGroup,
        int notional,
        uint maturity,
        uint blockTime,
        uint oracleRate
    ) internal pure returns (int) {
        if (notional == 0) return 0;
        uint timeToMaturity = maturity.sub(blockTime);

        int discountFactor;
        if (notional > 0) {
            discountFactor = getDiscountFactor(timeToMaturity, oracleRate.add(cashGroup.getfCashHaircut()));
        } else {
            uint debtBuffer = cashGroup.getDebtBuffer();
            // If the adjustment exceeds the oracle rate we floor the value of the fCash
            // at the notional value. We don't want to require the account to hold more than
            // absolutely required.
            if (debtBuffer >= oracleRate) return notional;

            discountFactor = getDiscountFactor(timeToMaturity, oracleRate - debtBuffer);
        }

        require(discountFactor <= Market.RATE_PRECISION); // dev: get risk adjusted pv, invalid discount factor
        return notional.mul(discountFactor).div(Market.RATE_PRECISION);
    }

    /**
     * @notice Returns the unhaircut claims on cash and fCash by the liquidity token.
     *
     * @return (assetCash, fCash)
     */
    function getCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState
    ) internal pure returns (int, int) {
        require(isLiquidityToken(liquidityToken.assetType) && liquidityToken.notional > 0); // dev: invalid asset, get cash claims

        int assetCash = marketState.totalCurrentCash
            .mul(liquidityToken.notional)
            .div(marketState.totalLiquidity);

        int fCash = marketState.totalfCash
            .mul(liquidityToken.notional)
            .div(marketState.totalLiquidity);

        return (assetCash, fCash);
    }

    function calcToken(
        int numerator,
        int tokens,
        int haircut,
        int liquidity
    ) private pure returns (int) {
        return numerator
            .mul(tokens)
            .mul(haircut)
            .div(CashGroup.TOKEN_HAIRCUT_DECIMALS)
            .div(liquidity);
    }

    /**
     * @notice Returns the haircut claims on cash and fCash
     *
     * @return (assetCash, fCash)
     */
    function getHaircutCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup,
        uint blockTime
    ) internal pure returns (int, int) {
        require(isLiquidityToken(liquidityToken.assetType) && liquidityToken.notional > 0); // dev: invalid asset get haircut cash claims

        require(liquidityToken.currencyId == cashGroup.currencyId); // dev: haircut cash claims, currency id mismatch
        uint timeToMaturity = liquidityToken.maturity.sub(blockTime);
        // This won't overflow, the liquidity token haircut is stored as an uint8
        int haircut = int(cashGroup.getLiquidityHaircut(liquidityToken.assetType));

        int assetCash = calcToken(
            marketState.totalCurrentCash,
            liquidityToken.notional,
            haircut,
            marketState.totalLiquidity
        );

        int fCash = calcToken(
            marketState.totalfCash,
            liquidityToken.notional,
            haircut,
            marketState.totalLiquidity
        );

        return (assetCash, fCash);
    }

    function getLiquidityTokenValue(
        PortfolioAsset memory liquidityToken,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        PortfolioAsset[] memory fCashAssets,
        uint blockTime,
        bool riskAdjusted
    ) internal view returns (int, int) {
        require(isLiquidityToken(liquidityToken.assetType) && liquidityToken.notional > 0); // dev: get liquidity token value, not liquidity token

        MarketParameters memory market;
        {
            (uint marketIndex, bool idiosyncratic) = cashGroup.getMarketIndex(liquidityToken.maturity, blockTime);
            // Liquidity tokens can never be idiosyncractic
            require(!idiosyncratic); // dev: idiosyncratic liquidity token
            // This market will always be initialized, if a liquidity token exists that means the market has some
            // liquidity in it (duh)
            market = cashGroup.getMarket(markets, marketIndex, blockTime, true);
        }

        int assetCashClaim;
        int fCashClaim;
        if (riskAdjusted) {
            (assetCashClaim, fCashClaim) = getHaircutCashClaims(
                liquidityToken,
                market,
                cashGroup,
                blockTime
            );
        } else {
            (assetCashClaim, fCashClaim) = getCashClaims(
                liquidityToken,
                market
            );
        }

        // Find the matching fCash asset and net off the value
        for (uint j; j < fCashAssets.length; j++) {
            if (fCashAssets[j].assetType == FCASH_ASSET_TYPE &&
                fCashAssets[j].currencyId == liquidityToken.currencyId &&
                fCashAssets[j].maturity == liquidityToken.maturity) {
                // Net off the fCashClaim here and we will discount it to present value in the second pass
                fCashAssets[j].notional = fCashAssets[j].notional.add(fCashClaim);

                return (assetCashClaim, 0);
            }
        }

        // If not matching fCash asset found then get the pv directly
        if (riskAdjusted) {
            int pv = getRiskAdjustedPresentValue(
                cashGroup,
                fCashClaim,
                liquidityToken.maturity,
                blockTime,
                market.oracleRate
            );

            return (assetCashClaim, pv);
        } else {
            int pv = getPresentValue(
                fCashClaim,
                liquidityToken.maturity,
                blockTime,
                market.oracleRate
            );

            return (assetCashClaim, pv);
        }
    }

    /**
     * @notice Returns the risk adjusted net portfolio value. Assumes that settle matured assets has already
     * been called so no assets have matured. Returns an array of present value figures per cash group.
     *
     * @dev Assumes that cashGroups and assets are sorted by cash group id. Also
     * assumes that market states are sorted by maturity within each cash group.
     */
    function getPortfolioValue(
        PortfolioAsset[] memory assets,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory markets,
        uint blockTime,
        bool riskAdjusted
    ) internal view returns(int[] memory) {
        int[] memory presentValueAsset = new int[](cashGroups.length);
        int[] memory presentValueUnderlying = new int[](cashGroups.length);
        uint groupIndex;

        for (uint i; i < assets.length; i++) {
            if (!isLiquidityToken(assets[i].assetType)) continue;
            while(assets[i].currencyId != cashGroups[groupIndex].currencyId) {
                // Assets and cash groups are sorted by currency id but there may be gaps
                // between them currency groups
                groupIndex += 1;
                require(groupIndex <= cashGroups.length); // dev: get portfolio value, cash group not found
            }

            (int assetCashClaim, int pv) = getLiquidityTokenValue(
                assets[i],
                cashGroups[groupIndex],
                markets[groupIndex],
                assets,
                blockTime,
                riskAdjusted
            );

            presentValueAsset[groupIndex] = presentValueAsset[groupIndex].add(assetCashClaim);
            if (pv != 0) presentValueUnderlying[groupIndex] = presentValueUnderlying[groupIndex].add(pv);
        }

        groupIndex = 0;
        for (uint i; i < assets.length; i++) {
            if (assets[i].assetType != FCASH_ASSET_TYPE) continue;
            while(assets[i].currencyId != cashGroups[groupIndex].currencyId) {
                // Assets and cash groups are sorted by currency id but there may be gaps
                // between them currency groups

                // Convert the PV of the underlying values before we move to the next group index.
                if (presentValueUnderlying[groupIndex] != 0) {
                    presentValueAsset[groupIndex] = cashGroups[groupIndex].assetRate.convertInternalFromUnderlying(
                        presentValueUnderlying[groupIndex]
                    );
                }
                groupIndex += 1;
                require(groupIndex <= cashGroups.length); // dev: get portfolio value, cash group not found
            }
            
            uint maturity = assets[i].maturity;
            uint oracleRate = cashGroups[groupIndex].getOracleRate(
                markets[groupIndex],
                maturity,
                blockTime
            );

            int pv;
            if (riskAdjusted) {
                pv = getRiskAdjustedPresentValue(
                    cashGroups[groupIndex],
                    assets[i].notional,
                    maturity,
                    blockTime,
                    oracleRate
                );
            } else {
                pv = getPresentValue(
                    assets[i].notional,
                    maturity,
                    blockTime,
                    oracleRate
                );
            }

            presentValueUnderlying[groupIndex] = presentValueUnderlying[groupIndex].add(pv);
        }

        // This converts the last group which is not caught in the if statement above
        presentValueAsset[groupIndex] = cashGroups[groupIndex].assetRate.convertInternalFromUnderlying(
            presentValueUnderlying[groupIndex]
        );

        return presentValueAsset;
    }
}

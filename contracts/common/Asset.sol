// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "../math/ABDKMath64x64.sol";
import "./CashGroup.sol";
import "../storage/PortfolioHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";

library Asset {
    using SafeMath for uint256;
    using SafeInt256 for int;
    using CashGroup for CashGroupParameters;
    using ExchangeRate for Rate;

    // Used for asset type enum
    uint public constant FCASH_ASSET_TYPE = 1;
    uint public constant LIQUIDITY_TOKEN_ASSET_TYPE = 2;

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

        require(discountFactor <= Market.RATE_PRECISION, "A: invalid discount factor");
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
            discountFactor = getDiscountFactor(timeToMaturity, oracleRate.add(cashGroup.fCashHaircut));
        } else {
            // If the adjustment exceeds the oracle rate we floor the value of the fCash
            // at the notional value. We don't want to require the account to hold more than
            // absolutely required.
            if (cashGroup.debtBuffer >= oracleRate) return notional;

            discountFactor = getDiscountFactor(timeToMaturity, oracleRate - cashGroup.debtBuffer);
        }

        require(discountFactor <= Market.RATE_PRECISION, "A: invalid discount factor");
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
        require(
            liquidityToken.assetType == LIQUIDITY_TOKEN_ASSET_TYPE && liquidityToken.notional > 0,
            "A: invalid asset in claims"
        );

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
        require(
            liquidityToken.assetType == LIQUIDITY_TOKEN_ASSET_TYPE && liquidityToken.notional > 0,
            "A: invalid asset in claims"
        );

        require(liquidityToken.currencyId == cashGroup.currencyId, "A: cash group mismatch");
        uint timeToMaturity = liquidityToken.maturity.sub(blockTime);
        int haircut = SafeCast.toInt256(cashGroup.getLiquidityHaircut(timeToMaturity));

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

    function findMarketIndex(
        uint maturity,
        MarketParameters[] memory marketStates
    ) internal pure returns (uint, bool) {
        // This assumes that market states are sorted, will cause issues otherwise.
        for (uint i; i < marketStates.length; i++) {
            if (marketStates[i].maturity == maturity) return (i, false);

            // If this maturity is between two market maturities then it
            // is idiosyncratic. We return the lower index and a true to indicate.
            if (i + 1 < marketStates.length
                && marketStates[i].maturity < maturity
                && maturity < marketStates[i + 1].maturity
            ) {
                return (i, true);
            }
        }

        revert("A: market not found");
    }

    /**
     * @notice Returns the linear interpolation between two market rates. The formula is
     * slope = (longMarket.oracleRate - shortMarket.oracleRate) / (longMarket.maturity - shortMarket.maturity)
     * interpolatedRate = slope * maturity + shortMarket.oracleRate
     */
    function interpolateOracleRate(
        MarketParameters memory shortMarket,
        MarketParameters memory longMarket,
        uint maturity
    ) internal pure returns (uint) {
        require(shortMarket.maturity < maturity, "A: interpolation error");
        require(maturity < longMarket.maturity, "A: interpolation error");

        // It's possible that the rates are inverted where the short market rate > long market rate and
        // we will get underflows here so we check for that
        if (longMarket.oracleRate >= shortMarket.oracleRate) {
            return (longMarket.oracleRate - shortMarket.oracleRate)
                .mul(maturity - shortMarket.maturity)
                // No underflow here, checked above
                .div(longMarket.maturity - shortMarket.maturity)
                .add(shortMarket.oracleRate);
        } else {
            // In this case the slope is negative so:
            // interpolatedRate = shortMarket.oracleRate - slope * maturity
            return shortMarket.oracleRate.sub(
                // This is reversed to keep it it positive
                (shortMarket.oracleRate - longMarket.oracleRate)
                    .mul(maturity - shortMarket.maturity)
                    // No underflow here, checked above
                    .div(longMarket.maturity - shortMarket.maturity)
            );
        }

    }

    function getLiquidityTokenValue(
        PortfolioAsset memory liquidityToken,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory marketStates,
        PortfolioAsset[] memory fCashAssets,
        uint blockTime
    ) internal pure returns (int, int) {
        require(
            liquidityToken.assetType == LIQUIDITY_TOKEN_ASSET_TYPE && liquidityToken.notional > 0,
            "A: invalid asset token value"
        );

        (uint marketIndex, bool idiosyncratic) = findMarketIndex(
            liquidityToken.maturity,
            marketStates
        );
        // Liquidity tokens can never be idiosyncractic
        require(!idiosyncratic, "A: idiosyncratic token");

        (int assetCashClaim, int fCashClaim) = getHaircutCashClaims(
            liquidityToken,
            marketStates[marketIndex],
            cashGroup,
            blockTime
        );

        bool found;
        // Find the matching fCash asset and net off the value
        for (uint j; j < fCashAssets.length; j++) {
            if (fCashAssets[j].assetType == Asset.FCASH_ASSET_TYPE &&
                fCashAssets[j].currencyId == liquidityToken.currencyId &&
                fCashAssets[j].maturity == liquidityToken.maturity) {
                // Net off the fCashClaim here and we will discount it to present value in the second pass
                fCashAssets[j].notional = fCashAssets[j].notional.add(fCashClaim);
                found = true;
                break;
            }
        }

        int pv;
        if (!found) {
            // If not matching fCash asset found then get the pv directly
            pv = getRiskAdjustedPresentValue(
                cashGroup,
                fCashClaim,
                liquidityToken.maturity,
                blockTime,
                marketStates[marketIndex].oracleRate
            );
        }

        return (assetCashClaim, pv);
    }

    /**
     * @notice Returns the risk adjusted net portfolio value. Assumes that settle matured assets has already
     * been called so no assets have matured. Returns an array of present value figures per cash group.
     *
     * @dev Assumes that cashGroups and assets are sorted by cash group id. Also
     * assumes that market states are sorted by maturity within each cash group.
     */
    function getRiskAdjustedPortfolioValue(
        PortfolioAsset[] memory assets,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) internal pure returns(int[] memory) {
        int[] memory presentValueAsset = new int[](cashGroups.length);
        int[] memory presentValueUnderlying = new int[](cashGroups.length);
        uint groupIndex;

        for (uint i; i < assets.length; i++) {
            if (assets[i].currencyId != cashGroups[groupIndex].currencyId) {
                groupIndex += 1;
            }
            if (assets[i].assetType != Asset.LIQUIDITY_TOKEN_ASSET_TYPE) continue;

            (int assetCashClaim, int pv) = getLiquidityTokenValue(
                assets[i],
                cashGroups[groupIndex],
                marketStates[groupIndex],
                assets,
                blockTime
            );

            presentValueAsset[groupIndex] = presentValueAsset[groupIndex].add(assetCashClaim);
            if (pv != 0) presentValueUnderlying[groupIndex] = presentValueUnderlying[groupIndex].add(pv);
        }

        groupIndex = 0;
        for (uint i; i < assets.length; i++) {
            if (assets[i].currencyId != cashGroups[groupIndex].currencyId) {
                // Convert the PV of the underlying values before we move to the next group index.
                presentValueAsset[groupIndex] = cashGroups[groupIndex].assetRate.convertInternalFromUnderlying(
                    presentValueUnderlying[groupIndex]
                );
                groupIndex += 1;
            }
            if (assets[i].assetType != Asset.FCASH_ASSET_TYPE) continue;
            
            uint maturity = assets[i].maturity;
            uint oracleRate;
            {
                (uint marketIndex, bool idiosyncractic) = findMarketIndex(
                    maturity,
                    marketStates[groupIndex]
                );
                // TODO: if the asset is idiosyncratic under the lowest market maturity
                // then we need to get the rate from the system

                oracleRate = idiosyncractic ? interpolateOracleRate(
                    marketStates[groupIndex][marketIndex],
                    marketStates[groupIndex][marketIndex + 1],
                    maturity
                ) : marketStates[groupIndex][marketIndex].oracleRate;
            }

            int pv = getRiskAdjustedPresentValue(
                cashGroups[groupIndex],
                assets[i].notional,
                maturity,
                blockTime,
                oracleRate
            );

            presentValueUnderlying[groupIndex] = presentValueUnderlying[groupIndex].add(pv);
        }

        // This converts the last group which is not caught in the if statement above
        presentValueAsset[groupIndex] = cashGroups[groupIndex].assetRate.convertInternalFromUnderlying(
            presentValueUnderlying[groupIndex]
        );

        return presentValueAsset;
    }
}

contract MockAsset {
    using SafeInt256 for int256;

    function getDiscountFactor(
        uint timeToMaturity,
        uint oracleRate
    ) public pure returns (int) {
        uint rate = SafeCast.toUint256(Asset.getDiscountFactor(timeToMaturity, oracleRate));
        assert(rate >= oracleRate);

        return int(rate);
    }

    function getPresentValue(
        int notional,
        uint maturity,
        uint blockTime,
        uint oracleRate
    ) public pure returns (int) {
        int pv = Asset.getPresentValue(notional, maturity, blockTime, oracleRate);
        if (notional > 0) assert(pv > 0);
        if (notional < 0) assert(pv < 0);

        assert(pv.abs() < notional.abs());
        return pv;
    }

    function getRiskAdjustedPresentValue(
        CashGroupParameters memory cashGroup,
        int notional,
        uint maturity,
        uint blockTime,
        uint oracleRate
    ) public pure returns (int) {
        int riskPv = Asset.getRiskAdjustedPresentValue(cashGroup, notional, maturity, blockTime, oracleRate);
        int pv = getPresentValue(notional, maturity, blockTime, oracleRate);

        assert(riskPv <= pv);
        assert(riskPv.abs() <= notional.abs());
        return riskPv;
    }

    function getCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState
    ) public pure returns (int, int) {
        (int cash, int fCash) = Asset.getCashClaims(liquidityToken, marketState);
        assert(cash > 0);
        assert(fCash > 0);
        assert(cash <= marketState.totalCurrentCash);
        assert(fCash <= marketState.totalfCash);

        return (cash, fCash);
    }

    function getHaircutCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup,
        uint blockTime
    ) public pure returns (int, int) {
        (int haircutCash, int haircutfCash) = Asset.getHaircutCashClaims(
            liquidityToken, marketState, cashGroup, blockTime
        );
        (int cash, int fCash) = getCashClaims(liquidityToken, marketState);

        assert(haircutCash < cash);
        assert(haircutfCash < fCash);

        return (haircutCash, haircutfCash);
    }

    function findMarketIndex(
        uint maturity,
        MarketParameters[] memory marketStates
    ) public pure returns (uint, bool) {
        return Asset.findMarketIndex(maturity, marketStates);
    }

    function interpolateOracleRate(
        MarketParameters memory shortMarket,
        MarketParameters memory longMarket,
        uint maturity
    ) public pure returns (uint) {
        uint rate = Asset.interpolateOracleRate(shortMarket, longMarket, maturity);
        if (shortMarket.oracleRate == longMarket.oracleRate) {
            assert(rate == shortMarket.oracleRate);
        } else if (shortMarket.oracleRate < longMarket.oracleRate) {
            assert(shortMarket.oracleRate < rate && rate < longMarket.oracleRate);
        } else {
            assert(shortMarket.oracleRate > rate && rate > longMarket.oracleRate);
        }

        return rate;
    }

    function getLiquidityTokenValue(
        PortfolioAsset memory liquidityToken,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory marketStates,
        PortfolioAsset[] memory fCashAssets,
        uint blockTime
    ) public pure returns (int, int, PortfolioAsset[] memory) {
        (int assetValue, int pv) = Asset.getLiquidityTokenValue(
            liquidityToken,
            cashGroup,
            marketStates,
            fCashAssets,
            blockTime
        );

        return (assetValue, pv, fCashAssets);
    }

    function getRiskAdjustedPortfolioValue(
        PortfolioAsset[] memory assets,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) public view returns(int[] memory) {
        int[] memory assetValue = Asset.getRiskAdjustedPortfolioValue(
            assets,
            cashGroups,
            marketStates,
            blockTime
        );

        return assetValue;
    }
}
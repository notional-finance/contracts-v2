// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    CashGroupParameters,
    PortfolioAsset,
    MarketParameters
} from "../../global/Types.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {ABDKMath64x64} from "../../math/ABDKMath64x64.sol";
import {Constants} from "../../global/Constants.sol";

import {DateTime} from "../markets/DateTime.sol";
import {CashGroup} from "../markets/CashGroup.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {PortfolioHandler} from "../portfolio/PortfolioHandler.sol";

library AssetHandler {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using CashGroup for CashGroupParameters;
    using PrimeRateLib for PrimeRate;

    function isLiquidityToken(uint256 assetType) internal pure returns (bool) {
        return
            assetType >= Constants.MIN_LIQUIDITY_TOKEN_INDEX &&
            assetType <= Constants.MAX_LIQUIDITY_TOKEN_INDEX;
    }

    /// @notice Liquidity tokens settle every 90 days (not at the designated maturity). This method
    /// calculates the settlement date for any PortfolioAsset.
    function getSettlementDate(PortfolioAsset memory asset) internal pure returns (uint256) {
        require(asset.assetType > 0 && asset.assetType <= Constants.MAX_LIQUIDITY_TOKEN_INDEX); // dev: settlement date invalid asset type
        // 3 month tokens and fCash tokens settle at maturity
        if (asset.assetType <= Constants.MIN_LIQUIDITY_TOKEN_INDEX) return asset.maturity;

        uint256 marketLength = DateTime.getTradedMarket(asset.assetType - 1);
        // Liquidity tokens settle at tRef + 90 days. The formula to get a maturity is:
        // maturity = tRef + marketLength
        // Here we calculate:
        // tRef = (maturity - marketLength) + 90 days
        return asset.maturity.sub(marketLength).add(Constants.QUARTER);
    }

    /// @notice Returns the continuously compounded discount rate given an oracle rate and a time to maturity.
    /// The formula is: e^(-rate * timeToMaturity).
    function getDiscountFactor(uint256 timeToMaturity, uint256 oracleRate)
        internal
        pure
        returns (int256)
    {
        int128 expValue =
            ABDKMath64x64.fromUInt(oracleRate.mul(timeToMaturity).div(Constants.YEAR));
        expValue = ABDKMath64x64.div(expValue, Constants.RATE_PRECISION_64x64);
        expValue = ABDKMath64x64.exp(ABDKMath64x64.neg(expValue));
        expValue = ABDKMath64x64.mul(expValue, Constants.RATE_PRECISION_64x64);
        int256 discountFactor = ABDKMath64x64.toInt(expValue);

        return discountFactor;
    }

    /// @notice Present value of an fCash asset without any risk adjustments.
    function getPresentfCashValue(
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) internal pure returns (int256) {
        if (notional == 0) return 0;

        // NOTE: this will revert if maturity < blockTime. That is the correct behavior because we cannot
        // discount matured assets.
        uint256 timeToMaturity = maturity.sub(blockTime);
        int256 discountFactor = getDiscountFactor(timeToMaturity, oracleRate);

        require(discountFactor <= Constants.RATE_PRECISION); // dev: get present value invalid discount factor
        return notional.mulInRatePrecision(discountFactor);
    }

    /// @notice Present value of an fCash asset with risk adjustments. Positive fCash value will be discounted more
    /// heavily than the oracle rate given and vice versa for negative fCash.
    function getRiskAdjustedPresentfCashValue(
        CashGroupParameters memory cashGroup,
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) internal pure returns (int256) {
        if (notional == 0) return 0;
        // NOTE: this will revert if maturity < blockTime. That is the correct behavior because we cannot
        // discount matured assets.
        uint256 timeToMaturity = maturity.sub(blockTime);

        int256 discountFactor;
        if (notional > 0) {
            // If fCash is positive then discounting by a higher rate will result in a smaller
            // discount factor (e ^ -x), meaning a lower positive fCash value.
            discountFactor = getDiscountFactor(
                timeToMaturity,
                oracleRate.add(cashGroup.getfCashHaircut())
            );
        } else {
            uint256 debtBuffer = cashGroup.getDebtBuffer();
            // If the adjustment exceeds the oracle rate we floor the value of the fCash
            // at the notional value. We don't want to require the account to hold more than
            // absolutely required.
            if (debtBuffer >= oracleRate) return notional;

            discountFactor = getDiscountFactor(timeToMaturity, oracleRate - debtBuffer);
        }

        require(discountFactor <= Constants.RATE_PRECISION); // dev: get risk adjusted pv, invalid discount factor
        return notional.mulInRatePrecision(discountFactor);
    }

    /// @notice Returns the non haircut claims on cash and fCash by the liquidity token.
    function getCashClaims(PortfolioAsset memory token, MarketParameters memory market)
        internal
        pure
        returns (int256 primeCash, int256 fCash)
    {
        require(isLiquidityToken(token.assetType) && token.notional >= 0); // dev: invalid asset, get cash claims

        primeCash = market.totalPrimeCash.mul(token.notional).div(market.totalLiquidity);
        fCash = market.totalfCash.mul(token.notional).div(market.totalLiquidity);
    }

    /// @notice Returns present value of all assets in the cash group as prime cash and the updated
    /// portfolio index where the function has ended.
    /// @return the value of the cash group in asset cash
    function getNetCashGroupValue(
        PortfolioAsset[] memory assets,
        CashGroupParameters memory cashGroup,
        uint256 blockTime,
        uint256 portfolioIndex
    ) internal view returns (int256, uint256) {
        int256 presentValueInPrime;
        int256 presentValueUnderlying;

        uint256 j = portfolioIndex;
        for (; j < assets.length; j++) {
            PortfolioAsset memory a = assets[j];
            if (a.assetType != Constants.FCASH_ASSET_TYPE) continue;
            // If we hit a different currency id then we've accounted for all assets in this currency
            // j will mark the index where we don't have this currency anymore
            if (a.currencyId != cashGroup.currencyId) break;

            uint256 oracleRate = cashGroup.calculateOracleRate(a.maturity, blockTime);

            int256 pv =
                getRiskAdjustedPresentfCashValue(
                    cashGroup,
                    a.notional,
                    a.maturity,
                    blockTime,
                    oracleRate
                );
            presentValueUnderlying = presentValueUnderlying.add(pv);
        }

        presentValueInPrime = presentValueInPrime.add(
            cashGroup.primeRate.convertFromUnderlying(presentValueUnderlying)
        );

        return (presentValueInPrime, j);
    }
}

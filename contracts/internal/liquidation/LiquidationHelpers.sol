// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./LiquidatefCash.sol";
import "../AccountContextHandler.sol";
import "../valuation/ExchangeRate.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../portfolio/PortfolioHandler.sol";
import "../balances/BalanceHandler.sol";
import "../balances/TokenHandler.sol";
import "../markets/AssetRate.sol";
import "../../external/FreeCollateralExternal.sol";
import "../../math/SafeInt256.sol";

library LiquidationHelpers {
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using BalanceHandler for BalanceState;
    using PortfolioHandler for PortfolioState;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountContext;
    using TokenHandler for Token;

    /// @notice Settles accounts and returns liquidation factors for all of the liquidation actions. Also
    /// returns the account context and portfolio state post settlement. All liquidation actions will start
    /// here to get their required preconditions met.
    function preLiquidationActions(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 collateralCurrency
    )
        internal
        returns (
            AccountContext memory,
            LiquidationFactors memory,
            PortfolioState memory
        )
    {
        // Cannot liquidate yourself
        require(msg.sender != liquidateAccount);
        require(localCurrency != 0);
        // Collateral currency must be unset or not equal to the local currency
        require(collateralCurrency != localCurrency);
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioAsset[] memory portfolio
        ) =
            FreeCollateralExternal.getLiquidationFactors(
                liquidateAccount,
                localCurrency,
                collateralCurrency
            );
        // Set the account context here to ensure that the context is up to date during
        // calculation methods
        accountContext.setAccountContext(liquidateAccount);

        PortfolioState memory portfolioState =
            PortfolioState({
                storedAssets: portfolio,
                newAssets: new PortfolioAsset[](0),
                lastNewAssetIndex: 0,
                storedAssetLength: portfolio.length
            });

        return (accountContext, factors, portfolioState);
    }

    /// @notice We allow liquidators to purchase up to Constants.DEFAULT_LIQUIDATION_PORTION percentage of collateral
    /// assets during liquidation to recollateralize an account as long as it does not also put the account
    /// further into negative free collateral (i.e. constraints on local available and collateral available).
    /// Additionally, we allow the liquidator to specify a maximum amount of collateral they would like to
    /// purchase so we also enforce that limit here.
    /// @param liquidateAmountRequired this is the amount required by liquidation to get back to positive free collateral
    /// @param maxTotalBalance the maximum total balance of the asset the account has
    /// @param userSpecifiedMaximum the maximum amount the liquidator is willing to purchase
    function calculateLiquidationAmount(
        int256 liquidateAmountRequired,
        int256 maxTotalBalance,
        int256 userSpecifiedMaximum
    ) internal pure returns (int256) {
        // By default, the liquidator is allowed to purchase at least to `defaultAllowedAmount`
        // if `liquidateAmountRequired` is less than `defaultAllowedAmount`.
        int256 defaultAllowedAmount =
            maxTotalBalance.mul(Constants.DEFAULT_LIQUIDATION_PORTION).div(
                Constants.PERCENTAGE_DECIMALS
            );

        int256 result = liquidateAmountRequired;

        // Limit the purchase amount by the max total balance, we cannot purchase
        // more than what is available.
        if (liquidateAmountRequired > maxTotalBalance) {
            result = maxTotalBalance;
        }

        // Allow the liquidator to go up to the default allowed amount which is always
        // less than the maxTotalBalance
        if (liquidateAmountRequired < defaultAllowedAmount) {
            result = defaultAllowedAmount;
        }

        if (userSpecifiedMaximum > 0 && result > userSpecifiedMaximum) {
            // Do not allow liquidation above the user specified maximum
            result = userSpecifiedMaximum;
        }

        return result;
    }

    /// @notice Calculates the amount of underlying benefit required for local currency and fCash
    /// liquidations. Uses the netETHValue converted back to local currency to maximize the benefit
    /// gained from local liquidations.
    /// @return the amount of underlying asset required
    function calculateLocalLiquidationUnderlyingRequired(
        int256 localAssetAvailable,
        int256 netETHValue,
        ETHRate memory localETHRate
    ) internal pure returns (int256) {
            // Formula in both cases requires dividing by the haircut or buffer:
            // convertToLocal(netFCShortfallInETH) = localRequired * haircut
            // convertToLocal(netFCShortfallInETH) / haircut = localRequired
            //
            // convertToLocal(netFCShortfallInETH) = localRequired * buffer
            // convertToLocal(netFCShortfallInETH) / buffer = localRequired
            int256 multiple = localAssetAvailable > 0 ? localETHRate.haircut : localETHRate.buffer;

            // Multiple will equal zero when the haircut is zero, in this case localAvailable > 0 but
            // liquidating a currency that is haircut to zero will have no effect on the netETHValue.
            require(multiple > 0); // dev: cannot liquidate haircut asset

            // netETHValue must be negative to be inside liquidation
            return localETHRate.convertETHTo(netETHValue.neg())
                    .mul(Constants.PERCENTAGE_DECIMALS)
                    .div(multiple);
    }

    /// @dev Calculates factors when liquidating across two currencies
    function calculateCrossCurrencyFactors(LiquidationFactors memory factors)
        internal
        pure
        returns (int256 collateralDenominatedFC, int256 liquidationDiscount)
    {
        collateralDenominatedFC = factors.collateralCashGroup.assetRate.convertFromUnderlying(
            factors
                .collateralETHRate
                // netETHValue must be negative to be in liquidation
                .convertETHTo(factors.netETHValue.neg())
        );

        liquidationDiscount = SafeInt256.max(
            factors.collateralETHRate.liquidationDiscount,
            factors.localETHRate.liquidationDiscount
        );
    }

    /// @notice Calculates the local to purchase in cross currency liquidations. Ensures that local to purchase
    /// is not so large that the account is put further into debt.
    /// @return
    ///     collateralBalanceToSell: the amount of collateral balance to be sold to the liquidator (it can either
    ///     be asset cash in the case of currency liquidations or fcash in the case of cross currency fcash liquidation,
    ///     this is scaled by a unitless proportion in the method).
    ///     localAssetFromLiquidator: the amount of asset cash from the liquidator
    function calculateLocalToPurchase(
        LiquidationFactors memory factors,
        int256 liquidationDiscount,
        int256 collateralUnderlyingPresentValue,
        int256 collateralBalanceToSell
    ) internal pure returns (int256, int256) {
        // Converts collateral present value to the local amount along with the liquidation discount.
        // localPurchased = collateralToSell / (exchangeRate * liquidationDiscount)
        int256 localUnderlyingFromLiquidator =
            collateralUnderlyingPresentValue
                .mul(Constants.PERCENTAGE_DECIMALS)
                .mul(factors.localETHRate.rateDecimals)
                .div(ExchangeRate.exchangeRate(factors.localETHRate, factors.collateralETHRate))
                .div(liquidationDiscount);

        int256 localAssetFromLiquidator =
            factors.localAssetRate.convertFromUnderlying(localUnderlyingFromLiquidator);
        // localAssetAvailable must be negative in cross currency liquidations
        int256 maxLocalAsset = factors.localAssetAvailable.neg();

        if (localAssetFromLiquidator > maxLocalAsset) {
            // If the local to purchase will flip the sign of localAssetAvailable then the calculations
            // for the collateral purchase amounts will be thrown off. The positive portion of localAssetAvailable
            // has to have a haircut applied. If this haircut reduces the localAssetAvailable value below
            // the collateralAssetValue then this may actually decrease overall free collateral.
            collateralBalanceToSell = collateralBalanceToSell
                .mul(maxLocalAsset)
                .div(localAssetFromLiquidator);

            localAssetFromLiquidator = maxLocalAsset;
        }

        return (collateralBalanceToSell, localAssetFromLiquidator);
    }

    function finalizeLiquidatorLocal(
        address liquidator,
        uint16 localCurrencyId,
        int256 netLocalFromLiquidator,
        int256 netLocalNTokens
    ) internal returns (AccountContext memory) {
        // Liquidator must deposit netLocalFromLiquidator, in the case of a repo discount then the
        // liquidator will receive some positive amount
        Token memory token = TokenHandler.getAssetToken(localCurrencyId);
        AccountContext memory liquidatorContext =
            AccountContextHandler.getAccountContext(liquidator);
        BalanceState memory liquidatorLocalBalance;
        liquidatorLocalBalance.loadBalanceState(liquidator, localCurrencyId, liquidatorContext);

        if (token.hasTransferFee && netLocalFromLiquidator > 0) {
            // If a token has a transfer fee then it must have been deposited prior to the liquidation
            // or else we won't be able to net off the correct amount. We also require that the account
            // does not have debt so that we do not have to run a free collateral check here
            require(
                liquidatorLocalBalance.storedCashBalance >= netLocalFromLiquidator &&
                    liquidatorContext.hasDebt == 0x00,
                "No cash"
            ); // dev: token has transfer fee, no liquidator balance
            liquidatorLocalBalance.netCashChange = netLocalFromLiquidator.neg();
        } else {
            // NOTE: in the case of aToken transfers this is going to convert the scaledBalanceOf aToken
            // to the balanceOf value required for transfers
            token.transfer(liquidator, localCurrencyId, token.convertToExternal(netLocalFromLiquidator));
        }
        liquidatorLocalBalance.netNTokenTransfer = netLocalNTokens;
        liquidatorLocalBalance.finalize(liquidator, liquidatorContext, false);

        return liquidatorContext;
    }

    function finalizeLiquidatorCollateral(
        address liquidator,
        AccountContext memory liquidatorContext,
        uint16 collateralCurrencyId,
        int256 netCollateralToLiquidator,
        int256 netCollateralNTokens,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) internal returns (AccountContext memory) {
        BalanceState memory balance;
        balance.loadBalanceState(liquidator, collateralCurrencyId, liquidatorContext);
        balance.netCashChange = netCollateralToLiquidator;

        if (withdrawCollateral) {
            // This will net off the cash balance
            balance.netAssetTransferInternalPrecision = netCollateralToLiquidator.neg();
        }

        balance.netNTokenTransfer = netCollateralNTokens;
        // NOTE: redeem to underlying does not affect nTokens, those must be redeemed
        // separately by calling back into Notional
        balance.finalize(liquidator, liquidatorContext, redeemToUnderlying);

        return liquidatorContext;
    }

    function finalizeLiquidatedLocalBalance(
        address liquidateAccount,
        uint16 localCurrency,
        AccountContext memory accountContext,
        int256 netLocalFromLiquidator
    ) internal {
        BalanceState memory balance;
        balance.loadBalanceState(liquidateAccount, localCurrency, accountContext);
        balance.netCashChange = netLocalFromLiquidator;
        balance.finalize(liquidateAccount, accountContext, false);
    }
}

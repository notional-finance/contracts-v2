// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/liquidation/LiquidateCurrency.sol";
import "../../internal/liquidation/LiquidationHelpers.sol";
import "../../math/SafeInt256.sol";

contract LiquidateCurrencyAction {
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int256;

    event LiquidateLocalCurrency(
        address indexed liquidated,
        address indexed liquidator,
        int256 netLocalFromLiquidator
    );

    event LiquidateCollateralCurrency(
        address indexed liquidated,
        address indexed liquidator,
        int256 netLocalFromLiquidator,
        int256 netCollateralTransfer,
        int256 netNTokenTransfer
    );

    /// @notice Calculates the net local currency required by the liquidator. This is a stateful method
    /// because it may settle the liquidated account if required. However, it can be called using staticcall
    /// off chain to determine the net local currency required before liquidating.
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency id of the local currency
    /// @param maxNTokenLiquidation maximum amount of nTokens to purchase (if any)
    /// @return the net amount of local currency required from the liquidator
    function calculateLocalCurrencyLiquidation(
        address liquidateAccount,
        uint256 localCurrency,
        uint96 maxNTokenLiquidation
    ) external returns (int256) {
        // prettier-ignore
        (
            int256 netLocalFromLiquidator,
            /* BalanceState memory localBalanceState */,
            /* PortfolioState memory portfolio */,
            /* AccountContext memory accountContext */,
            /* MarketParameters[] memory markets */
        ) = _localCurrencyLiquidation(liquidateAccount, localCurrency, maxNTokenLiquidation);

        return netLocalFromLiquidator;
    }

    /// @notice Liquidates an account using local currency only
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency id of the local currency
    /// @param maxNTokenLiquidation maximum amount of nTokens to purchase (if any)
    /// @return the net amount of local currency transferred to or from the liquidator
    function liquidateLocalCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint96 maxNTokenLiquidation
    ) external returns (int256) {
        (
            int256 netLocalFromLiquidator,
            BalanceState memory localBalanceState,
            PortfolioState memory portfolio,
            AccountContext memory accountContext,
            MarketParameters[] memory markets
        ) = _localCurrencyLiquidation(liquidateAccount, localCurrency, maxNTokenLiquidation);

        // Transfers a positive or negative amount of local currency as well as the net nToken
        // amounts to the liquidator
        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                netLocalFromLiquidator,
                localBalanceState.netNTokenTransfer.neg()
            );
        liquidatorContext.setAccountContext(msg.sender);

        LiquidateCurrency.finalizeLiquidatedCollateralAndPortfolio(
            liquidateAccount,
            localBalanceState, // In this case, local currency is the collateral
            accountContext,
            portfolio,
            markets
        );

        emit LiquidateLocalCurrency(liquidateAccount, msg.sender, netLocalFromLiquidator);

        return netLocalFromLiquidator;
    }

    /// @notice Calculates local and collateral currency transfers for a liquidation. This is a stateful method
    /// because it may settle the liquidated account if required. However, it can be called using staticcall
    /// off chain to determine the net currency amounts required before liquidating.
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency id of the local currency
    /// @param collateralCurrency id of the collateral currency
    /// @param maxCollateralLiquidation maximum amount of collateral (inclusive of cash and nTokens) to liquidate
    /// @param maxNTokenLiquidation maximum amount of nTokens to purchase (if any)
    /// @return currency transfer amounts:
    ///   - local currency required from liquidator (negative)
    ///   - collateral asset cash paid to liquidator (positive)
    ///   - collateral nTokens paid to liquidator (positive)
    function calculateCollateralCurrencyLiquidation(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    )
        external
        returns (
            int256,
            int256,
            int256
        )
    {
        // prettier-ignore
        (
            int256 netLocalFromLiquidator,
            BalanceState memory collateralBalanceState,
            /* PortfolioState memory portfolio */,
            /* AccountContext memory accountContext */,
            /* MarketParameters[] memory markets */
        ) = _collateralCurrencyLiquidation(
                liquidateAccount,
                localCurrency,
                collateralCurrency,
                maxCollateralLiquidation,
                maxNTokenLiquidation
            );

        return (
            netLocalFromLiquidator,
            collateralBalanceState.netCashChange.neg(),
            collateralBalanceState.netNTokenTransfer.neg()
        );
    }

    /// @notice Liquidates an account between local and collateral currency
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency id of the local currency
    /// @param collateralCurrency id of the collateral currency
    /// @param maxCollateralLiquidation maximum amount of collateral (inclusive of cash and nTokens) to liquidate
    /// @param maxNTokenLiquidation maximum amount of nTokens to purchase (if any)
    /// @param withdrawCollateral if true, withdraws collateral back to msg.sender
    /// @param redeemToUnderlying if true, converts collateral from asset cash to underlying
    /// @return currency transfer amounts:
    ///   - local currency required from liquidator (negative)
    ///   - collateral asset cash paid to liquidator (positive)
    ///   - collateral nTokens paid to liquidator (positive)
    function liquidateCollateralCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        bool withdrawCollateral,
        bool redeemToUnderlying
    )
        external
        returns (
            int256,
            int256,
            int256
        )
    {
        (
            int256 netLocalFromLiquidator,
            BalanceState memory collateralBalanceState,
            PortfolioState memory portfolio,
            AccountContext memory accountContext,
            MarketParameters[] memory markets
        ) =
            _collateralCurrencyLiquidation(
                liquidateAccount,
                localCurrency,
                collateralCurrency,
                maxCollateralLiquidation,
                maxNTokenLiquidation
            );

        _finalizeLiquidatorBalances(
            localCurrency,
            collateralCurrency,
            netLocalFromLiquidator,
            collateralBalanceState,
            withdrawCollateral,
            redeemToUnderlying
        );

        // Liquidated local currency balance will increase by the net paid from the liquidator
        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            accountContext,
            netLocalFromLiquidator
        );

        // Liquidated collateral balance will change accordingly
        LiquidateCurrency.finalizeLiquidatedCollateralAndPortfolio(
            liquidateAccount,
            collateralBalanceState,
            accountContext,
            portfolio,
            markets
        );

        emit LiquidateCollateralCurrency(
            liquidateAccount,
            msg.sender,
            netLocalFromLiquidator,
            collateralBalanceState.netCashChange.neg(),
            collateralBalanceState.netNTokenTransfer.neg()
        );

        return (
            netLocalFromLiquidator,
            collateralBalanceState.netCashChange.neg(),
            collateralBalanceState.netNTokenTransfer.neg()
        );
    }

    function _localCurrencyLiquidation(
        address liquidateAccount,
        uint256 localCurrency,
        uint96 maxNTokenLiquidation
    )
        private
        returns (
            int256,
            BalanceState memory,
            PortfolioState memory,
            AccountContext memory,
            MarketParameters[] memory markets
        )
    {
        uint256 blockTime = block.timestamp;
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) = LiquidationHelpers.preLiquidationActions(liquidateAccount, localCurrency, 0);
        BalanceState memory localBalanceState;
        localBalanceState.loadBalanceState(liquidateAccount, localCurrency, accountContext);

        int256 netLocalFromLiquidator =
            LiquidateCurrency.liquidateLocalCurrency(
                localCurrency,
                maxNTokenLiquidation,
                blockTime,
                localBalanceState,
                factors,
                portfolio
            );

        return (
            netLocalFromLiquidator,
            localBalanceState,
            portfolio,
            accountContext,
            factors.markets
        );
    }

    function _collateralCurrencyLiquidation(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    )
        private
        returns (
            int256,
            BalanceState memory,
            PortfolioState memory,
            AccountContext memory,
            MarketParameters[] memory markets
        )
    {
        uint256 blockTime = block.timestamp;
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) =
            LiquidationHelpers.preLiquidationActions(
                liquidateAccount,
                localCurrency,
                collateralCurrency
            );

        BalanceState memory collateralBalanceState;
        collateralBalanceState.loadBalanceState(
            liquidateAccount,
            collateralCurrency,
            accountContext
        );

        int256 netLocalFromLiquidator =
            LiquidateCurrency.liquidateCollateralCurrency(
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                blockTime,
                collateralBalanceState,
                factors,
                portfolio
            );

        return (
            netLocalFromLiquidator,
            collateralBalanceState,
            portfolio,
            accountContext,
            factors.markets
        );
    }

    function _finalizeLiquidatorBalances(
        uint256 localCurrency,
        uint256 collateralCurrency,
        int256 netLocalFromLiquidator,
        BalanceState memory collateralBalanceState,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) private {
        // Will transfer local currency from the liquidator
        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                netLocalFromLiquidator,
                0 // No nToken transfers
            );

        // Will transfer collateral to the liquidator
        LiquidationHelpers.finalizeLiquidatorCollateral(
            msg.sender,
            liquidatorContext,
            collateralCurrency,
            collateralBalanceState.netCashChange.neg(),
            collateralBalanceState.netNTokenTransfer.neg(),
            withdrawCollateral,
            redeemToUnderlying
        );

        liquidatorContext.setAccountContext(msg.sender);
    }
}

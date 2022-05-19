// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./ActionGuards.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/liquidation/LiquidateCurrency.sol";
import "../../internal/liquidation/LiquidationHelpers.sol";
import "../../math/SafeInt256.sol";

contract LiquidateCurrencyAction is ActionGuards {
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int256;

    event LiquidateLocalCurrency(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        int256 localAssetCashFromLiquidator
    );

    event LiquidateCollateralCurrency(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        uint16 collateralCurrencyId,
        int256 localAssetCashFromLiquidator,
        int256 netCollateralTransfer,
        int256 netNTokenTransfer
    );

    /// @notice Calculates the net local currency required by the liquidator. This is a stateful method
    /// because it may settle the liquidated account if required. However, it can be called using staticcall
    /// off chain to determine the net local currency required before liquidating.
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency id of the local currency
    /// @param maxNTokenLiquidation maximum amount of nTokens to purchase (if any)
    /// @return local currency required from liquidator (positive or negative)
    /// @return local nTokens paid to liquidator (positive)
    function calculateLocalCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint96 maxNTokenLiquidation
    ) external nonReentrant returns (int256, int256) {
        // prettier-ignore
        (
            int256 localAssetCashFromLiquidator,
            BalanceState memory localBalanceState,
            /* PortfolioState memory portfolio */,
            /* AccountContext memory accountContext */
        ) = _localCurrencyLiquidation(
            liquidateAccount,
            localCurrency,
            maxNTokenLiquidation,
            true // Is Calculation
        );

        return (
            localAssetCashFromLiquidator,
            localBalanceState.netNTokenTransfer.neg()
        );
    }

    /// @notice Liquidates an account using local currency only
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency id of the local currency
    /// @param maxNTokenLiquidation maximum amount of nTokens to purchase (if any)
    /// @return local currency required from liquidator (positive or negative)
    /// @return local nTokens paid to liquidator (positive)
    function liquidateLocalCurrency(
        address liquidateAccount,
        uint16 localCurrency,
        uint96 maxNTokenLiquidation
    ) external nonReentrant returns (int256, int256) {
        // Calculates liquidation results:
        //  - withdraws liquidity tokens in local currency
        //  - ntoken transfers
        //  - amount of cash paid to/from the liquidator
        (
            int256 localAssetCashFromLiquidator,
            BalanceState memory localBalanceState,
            PortfolioState memory portfolio,
            AccountContext memory accountContext
        ) = _localCurrencyLiquidation(
            liquidateAccount,
            localCurrency,
            maxNTokenLiquidation,
            false // is not calculation
        );

        // Finalizes liquidator account changes:
        //  - transfers local asset cash to/from liquidator wallet (not notional cash
        //    balance). Exception is with tokens that have a transfer fee
        //  - transfers ntokens to liquidator
        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                localAssetCashFromLiquidator,
                localBalanceState.netNTokenTransfer.neg()
            );
        liquidatorContext.setAccountContext(msg.sender);

        // Finalizes liquidated account changes:
        //   - credits additional change in localBalanceChange.netCashChange
        //   - removes transferred nTokens from the account
        //   - finalizes any liquidity token withdraws in an array portfolio
        //   - sets the account context
        LiquidateCurrency.finalizeLiquidatedCollateralAndPortfolio(
            liquidateAccount,
            localBalanceState, // In this case, local currency is the collateral
            accountContext,
            portfolio
        );

        emit LiquidateLocalCurrency(
            liquidateAccount,
            msg.sender,
            localCurrency,
            localAssetCashFromLiquidator
        );

        return (
            localAssetCashFromLiquidator,
            localBalanceState.netNTokenTransfer.neg()
        );
    }

    /// @notice Calculates local and collateral currency transfers for a liquidation. This is a stateful method
    /// because it may settle the liquidated account if required. However, it can be called using staticcall
    /// off chain to determine the net currency amounts required before liquidating.
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency id of the local currency
    /// @param collateralCurrency id of the collateral currency
    /// @param maxCollateralLiquidation maximum amount of collateral (inclusive of cash and nTokens) to liquidate
    /// @param maxNTokenLiquidation maximum amount of nTokens to purchase (if any)
    /// @return local currency required from liquidator (negative)
    /// @return collateral asset cash paid to liquidator (positive)
    /// @return collateral nTokens paid to liquidator (positive)
    function calculateCollateralCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    )
        external nonReentrant
        returns (
            int256,
            int256,
            int256
        )
    {
        // prettier-ignore
        (
            int256 localAssetCashFromLiquidator,
            BalanceState memory collateralBalanceState,
            /* PortfolioState memory portfolio */,
            /* AccountContext memory accountContext */
        ) = _collateralCurrencyLiquidation(
                liquidateAccount,
                localCurrency,
                collateralCurrency,
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                true // is calculation
            );

        return (
            localAssetCashFromLiquidator,
            _collateralAssetCashToLiquidator(collateralBalanceState),
            collateralBalanceState.netNTokenTransfer.neg()
        );
    }

    /// @notice Liquidates an account between local and collateral currency
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency id of the local currency
    /// @param collateralCurrency id of the collateral currency
    /// @param maxCollateralLiquidation maximum amount of collateral (inclusive of cash and nTokens) to liquidate
    /// @param maxNTokenLiquidation maximum amount of nTokens to purchase (if any)
    /// @param withdrawCollateral if true, withdraws collateral cash back to msg.sender
    /// @param redeemToUnderlying if true, converts collateral cash from asset cash to underlying
    /// @return local currency required from liquidator (negative)
    /// @return collateral asset cash paid to liquidator (positive)
    /// @return collateral nTokens paid to liquidator (positive)
    function liquidateCollateralCurrency(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        bool withdrawCollateral,
        bool redeemToUnderlying
    )
        external
        nonReentrant
        returns (
            int256,
            int256,
            int256
        )
    {
        // Calculates currency liquidation:
        //  - amount of collateral cash balance given to liquidator
        //  - liquidity tokens withdrawn
        //  - collateral ntokens transferred to liquidator
        (
            int256 localAssetCashFromLiquidator,
            BalanceState memory collateralBalanceState,
            PortfolioState memory portfolio,
            AccountContext memory accountContext
        ) =
            _collateralCurrencyLiquidation(
                liquidateAccount,
                localCurrency,
                collateralCurrency,
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                false // is not calculation
            );

        // Finalizes the liquidator side of the transaction:
        //   - transfers local asset cash from the liquidator wallet (exception
        //     is if local asset has transfer fees)
        //   - transfers collateral cash to liquidator, withdrawing and redeeming
        //     if specified
        //   - transfers ntokens to liquidator
        //   - sets account context
        _finalizeLiquidatorBalances(
            localCurrency,
            collateralCurrency,
            localAssetCashFromLiquidator,
            collateralBalanceState,
            withdrawCollateral,
            redeemToUnderlying
        );

        _emitCollateralEvent(
            liquidateAccount,
            localCurrency,
            localAssetCashFromLiquidator,
            collateralBalanceState
        );

        // Finalize liquidated account local balance:
        //   - adds local asset cash to the balance
        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            accountContext,
            localAssetCashFromLiquidator
        );

        // Finalizes the liquidated account collateral balance:
        //   - removes collateral cash paid to liquidator from cash balance
        //   - stores any updates to the portfolio array from removed liquidity tokens
        //   - removes collateral nTokens from the account
        //   - sets the account context
        LiquidateCurrency.finalizeLiquidatedCollateralAndPortfolio(
            liquidateAccount,
            collateralBalanceState,
            accountContext,
            portfolio
        );

        return (
            localAssetCashFromLiquidator,
            _collateralAssetCashToLiquidator(collateralBalanceState),
            collateralBalanceState.netNTokenTransfer.neg()
        );
    }

    function _emitCollateralEvent(
        address liquidateAccount,
        uint16 localCurrency,
        int256 localAssetCashFromLiquidator,
        BalanceState memory collateralBalanceState
    ) private {
        emit LiquidateCollateralCurrency(
            liquidateAccount,
            msg.sender,
            localCurrency,
            uint16(collateralBalanceState.currencyId),
            localAssetCashFromLiquidator,
            _collateralAssetCashToLiquidator(collateralBalanceState),
            collateralBalanceState.netNTokenTransfer.neg()
        );
    }

    function _localCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint96 maxNTokenLiquidation,
        bool isCalculation
    )
        internal
        returns (
            int256,
            BalanceState memory,
            PortfolioState memory,
            AccountContext memory
        )
    {
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) = LiquidationHelpers.preLiquidationActions(liquidateAccount, localCurrency, 0);
        BalanceState memory localBalanceState;
        localBalanceState.loadBalanceState(liquidateAccount, localCurrency, accountContext);
        factors.isCalculation = isCalculation;

        int256 localAssetCashFromLiquidator =
            LiquidateCurrency.liquidateLocalCurrency(
                localCurrency,
                maxNTokenLiquidation,
                block.timestamp,
                localBalanceState,
                factors,
                portfolio
            );

        return (
            localAssetCashFromLiquidator,
            localBalanceState,
            portfolio,
            accountContext
        );
    }

    function _collateralCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        bool isCalculation
    )
        private
        returns (
            int256,
            BalanceState memory,
            PortfolioState memory,
            AccountContext memory
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
        factors.isCalculation = isCalculation;

        int256 localAssetCashFromLiquidator =
            LiquidateCurrency.liquidateCollateralCurrency(
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                blockTime,
                collateralBalanceState,
                factors,
                portfolio
            );

        return (
            localAssetCashFromLiquidator,
            collateralBalanceState,
            portfolio,
            accountContext
        );
    }

    /// @dev Only used for collateral currency liquidation
    function _finalizeLiquidatorBalances(
        uint16 localCurrency,
        uint16 collateralCurrency,
        int256 localAssetCashFromLiquidator,
        BalanceState memory collateralBalanceState,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) private {
        // Will transfer local currency from the liquidator
        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                localAssetCashFromLiquidator,
                0 // No nToken transfers
            );

        // Will transfer collateral to the liquidator
        LiquidationHelpers.finalizeLiquidatorCollateral(
            msg.sender,
            liquidatorContext,
            collateralCurrency,
            _collateralAssetCashToLiquidator(collateralBalanceState),
            collateralBalanceState.netNTokenTransfer.neg(),
            withdrawCollateral,
            redeemToUnderlying
        );

        liquidatorContext.setAccountContext(msg.sender);
    }

    function _collateralAssetCashToLiquidator(BalanceState memory collateralBalanceState)
        private
        pure
        returns (int256)
    {
        // netAssetTransferInternalPrecision is the cash claim withdrawn from collateral
        // liquidity tokens.
        return
            collateralBalanceState.netCashChange.neg().add(
                collateralBalanceState.netAssetTransferInternalPrecision
            );
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address, address) {
        return (address(FreeCollateralExternal), address(MigrateIncentives));
    }
}

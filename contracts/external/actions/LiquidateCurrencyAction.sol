// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    BalanceState,
    AccountContext,
    LiquidationFactors
} from "../../global/Types.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {AccountContextHandler} from "../../internal/AccountContextHandler.sol";
import {BalanceHandler} from "../../internal/balances/BalanceHandler.sol";
import {LiquidateCurrency} from "../../internal/liquidation/LiquidateCurrency.sol";
import {LiquidationHelpers} from "../../internal/liquidation/LiquidationHelpers.sol";
import {ActionGuards} from "./ActionGuards.sol";

import {MigrateIncentives} from "../MigrateIncentives.sol";
import {FreeCollateralExternal} from "../FreeCollateralExternal.sol";

contract LiquidateCurrencyAction is ActionGuards {
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int256;

    event LiquidateLocalCurrency(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        int256 localPrimeCashFromLiquidator
    );

    event LiquidateCollateralCurrency(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        uint16 collateralCurrencyId,
        int256 localPrimeCashFromLiquidator,
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
            int256 localPrimeCashFromLiquidator,
            BalanceState memory localBalanceState,
            /* AccountContext memory accountContext */
        ) = _localCurrencyLiquidation(
            liquidateAccount,
            localCurrency,
            maxNTokenLiquidation,
            true // Is Calculation
        );

        return (
            localPrimeCashFromLiquidator,
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
    ) external payable nonReentrant returns (int256, int256) {
        // Calculates liquidation results:
        //  - ntoken transfers
        //  - amount of cash paid to/from the liquidator
        (
            int256 localPrimeCashFromLiquidator,
            BalanceState memory localBalanceState,
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
                localPrimeCashFromLiquidator,
                localBalanceState.netNTokenTransfer.neg()
            );
        liquidatorContext.setAccountContext(msg.sender);

        // Finalizes liquidated account changes:
        //   - credits additional change in localBalanceChange.netCashChange
        //   - removes transferred nTokens from the account
        //   - sets the account context
        localBalanceState.finalizeNoWithdraw(liquidateAccount, accountContext);
        accountContext.setAccountContext(liquidateAccount);

        emit LiquidateLocalCurrency(
            liquidateAccount,
            msg.sender,
            localCurrency,
            localPrimeCashFromLiquidator
        );

        return (
            localPrimeCashFromLiquidator,
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
    ) external nonReentrant returns (int256, int256, int256) {
        // prettier-ignore
        (
            int256 localPrimeCashFromLiquidator,
            BalanceState memory collateralBalanceState,
            /* */
        ) = _collateralCurrencyLiquidation(
                liquidateAccount,
                localCurrency,
                collateralCurrency,
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                true // is calculation
            );

        return (
            localPrimeCashFromLiquidator,
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
    ) external payable nonReentrant returns (int256, int256, int256) {
        // Calculates currency liquidation:
        //  - amount of collateral cash balance given to liquidator
        //  - liquidity tokens withdrawn
        //  - collateral ntokens transferred to liquidator
        (
            int256 localPrimeCashFromLiquidator,
            BalanceState memory collateralBalanceState,
            AccountContext memory accountContext
        ) = _collateralCurrencyLiquidation(
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
            localPrimeCashFromLiquidator,
            collateralBalanceState,
            withdrawCollateral,
            redeemToUnderlying
        );

        _emitCollateralEvent(
            liquidateAccount,
            localCurrency,
            localPrimeCashFromLiquidator,
            collateralBalanceState
        );

        // Finalize liquidated account local balance:
        //   - adds local asset cash to the balance
        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            accountContext,
            localPrimeCashFromLiquidator
        );

        // Finalizes the liquidated account collateral balance:
        //   - removes collateral cash paid to liquidator from cash balance
        //   - removes collateral nTokens from the account
        //   - skips the allowPrimeBorrow check
        //   - sets the account context
        collateralBalanceState.finalizeCollateralLiquidation(liquidateAccount, accountContext);
        accountContext.setAccountContext(liquidateAccount);

        return (
            localPrimeCashFromLiquidator,
            collateralBalanceState.netCashChange.neg(),
            collateralBalanceState.netNTokenTransfer.neg()
        );
    }

    function _emitCollateralEvent(
        address liquidateAccount,
        uint16 localCurrency,
        int256 localPrimeCashFromLiquidator,
        BalanceState memory collateralBalanceState
    ) private {
        emit LiquidateCollateralCurrency(
            liquidateAccount,
            msg.sender,
            localCurrency,
            uint16(collateralBalanceState.currencyId),
            localPrimeCashFromLiquidator,
            collateralBalanceState.netCashChange.neg(),
            collateralBalanceState.netNTokenTransfer.neg()
        );
    }

    function _localCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint96 maxNTokenLiquidation,
        bool isCalculation
    ) internal returns (
        int256 localPrimeCashFromLiquidator,
        BalanceState memory localBalanceState,
        AccountContext memory accountContext
    ) {
        LiquidationFactors memory factors;
        (accountContext, factors, /* */) = LiquidationHelpers.preLiquidationActions(
            liquidateAccount, localCurrency, 0
        );

        localBalanceState.loadBalanceState(liquidateAccount, localCurrency, accountContext);
        factors.isCalculation = isCalculation;

        localPrimeCashFromLiquidator = LiquidateCurrency.liquidateLocalCurrency(
                maxNTokenLiquidation,
                localBalanceState,
            factors
        );
    }

    function _collateralCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        bool isCalculation
    ) private returns (
        int256 localPrimeCashFromLiquidator,
        BalanceState memory collateralBalanceState,
        AccountContext memory accountContext
    ) {
        LiquidationFactors memory factors;
        (accountContext, factors, /* */) = LiquidationHelpers.preLiquidationActions(
            liquidateAccount, localCurrency, collateralCurrency
            );

        collateralBalanceState.loadBalanceState(liquidateAccount, collateralCurrency, accountContext);
        factors.isCalculation = isCalculation;

        localPrimeCashFromLiquidator = LiquidateCurrency.liquidateCollateralCurrency(
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                collateralBalanceState,
            factors
        );
    }

    /// @dev Only used for collateral currency liquidation
    function _finalizeLiquidatorBalances(
        uint16 localCurrency,
        uint16 collateralCurrency,
        int256 localPrimeCashFromLiquidator,
        BalanceState memory collateralBalanceState,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) private {
        // Will transfer local currency from the liquidator
        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                localPrimeCashFromLiquidator,
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

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address, address) {
        return (address(FreeCollateralExternal), address(MigrateIncentives));
    }
}

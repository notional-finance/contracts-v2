// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/liquidation/LiquidationHelpers.sol";
import "../../internal/liquidation/LiquidateCurrency.sol";
import "../../internal/liquidation/LiquidatefCash.sol";
import "../../external/actions/LiquidateCurrencyAction.sol";
import "./MockValuationLib.sol";

contract MockLiquidationSetup is MockValuationBase {
    function preLiquidationActions(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 collateralCurrency
    ) external returns (
        AccountContext memory,
        LiquidationFactors memory,
        PortfolioState memory
    ) {
        return LiquidationHelpers.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            collateralCurrency
        );
    }

    function getFreeCollateral(address account) external view returns (int256, int256[] memory) {
        return FreeCollateralExternal.getFreeCollateralView(account);
    }

    function calculateLiquidationAmount(
        int256 liquidateAmountRequired,
        int256 maxTotalBalance,
        int256 userSpecifiedMaximum
    ) external pure returns (int256) {
        return LiquidationHelpers.calculateLiquidationAmount(
            liquidateAmountRequired,
            maxTotalBalance,
            userSpecifiedMaximum
        );
    }

    function calculateLocalToPurchase(
        LiquidationFactors memory factors,
        int256 liquidationDiscount,
        int256 collateralUnderlyingPresentValue,
        int256 collateralAssetBalanceToSell
    ) internal pure returns (int256, int256) {
        return LiquidationHelpers.calculateLocalToPurchase(
            factors,
            liquidationDiscount,
            collateralUnderlyingPresentValue,
            collateralAssetBalanceToSell
        );
    }
}

contract MockLocalLiquidation is MockValuationBase {
    using SafeInt256 for int256;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;

    event LocalLiquidationTokens(
        int256 localAssetCashFromLiquidator,
        int256 nTokensPurchased,
        int256 netCashChange,
        PortfolioState portfolioState
    );

    event Test(int256 a, int256 t, LiquidateCurrency.WithdrawFactors w);
    function calculateLocalCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint96 maxNTokenLiquidation
    ) external returns (int256, int256) {
        // prettier-ignore
        (
            int256 localAssetCashFromLiquidator,
            BalanceState memory localBalanceState,
            /* PortfolioState memory portfolio*/,
            /* AccountContext memory accountContext */
        ) = _localCurrencyLiquidation(liquidateAccount, localCurrency, maxNTokenLiquidation, true);

        return (
            localAssetCashFromLiquidator,
            localBalanceState.netNTokenTransfer.neg()
        );
    }

    function calculateLocalCurrencyLiquidationTokens(
        address liquidateAccount,
        uint16 localCurrency,
        uint96 maxNTokenLiquidation
    ) external {
        // prettier-ignore
        (
            int256 localAssetCashFromLiquidator,
            BalanceState memory localBalanceState,
            PortfolioState memory portfolio,
            /* AccountContext memory accountContext */
        ) = _localCurrencyLiquidation(
            liquidateAccount,
            localCurrency,
            maxNTokenLiquidation,
            false // This will update markets internally
        );

        emit LocalLiquidationTokens(
            localAssetCashFromLiquidator,
            localBalanceState.netNTokenTransfer.neg(),
            localBalanceState.netCashChange,
            portfolio
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

    function getFreeCollateral(address account) external view returns (int256, int256[] memory) {
        return FreeCollateralExternal.getFreeCollateralView(account);
    }

    function getFreeCollateralAtTime(address account, uint256 blockTime) external view returns (int256, int256[] memory) {
        return FreeCollateralAtTime.getFreeCollateralViewAtTime(account, blockTime);
    }
}

contract MockCollateralLiquidation is MockValuationBase {
    using SafeInt256 for int256;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;

    event CollateralLiquidationTokens(
        int256 localAssetCashFromLiquidator,
        int256 collateralCashToLiquidator,
        int256 collateralNTokensToLiquidator,
        int256 cashClaimToLiquidator,
        PortfolioState portfolioState
    );

    function calculateCollateralCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 collateralCurrency,
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
                true
            );

        return (
            localAssetCashFromLiquidator,
            _collateralAssetCashToLiquidator(collateralBalanceState),
            collateralBalanceState.netNTokenTransfer.neg()
        );
    }

    function calculateCollateralCurrencyTokens(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    ) external {
        // prettier-ignore
        (
            int256 localAssetCashFromLiquidator,
            BalanceState memory collateralBalanceState,
            PortfolioState memory portfolio,
            /* AccountContext memory accountContext */
        ) = _collateralCurrencyLiquidation(
                liquidateAccount,
                localCurrency,
                collateralCurrency,
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                false // not calculation, updates market state
            );

        emit CollateralLiquidationTokens(
            localAssetCashFromLiquidator,
            _collateralAssetCashToLiquidator(collateralBalanceState),
            collateralBalanceState.netNTokenTransfer.neg(),
            collateralBalanceState.netAssetTransferInternalPrecision,
            portfolio
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

    function getFreeCollateral(address account) external view returns (int256, int256[] memory) {
        return FreeCollateralExternal.getFreeCollateralView(account);
    }

    function getFreeCollateralAtTime(address account, uint256 blockTime)
        external
        view
        returns (int256, int256[] memory)
    {
        return FreeCollateralAtTime.getFreeCollateralViewAtTime(account, blockTime);
    }
}

contract MockLocalfCashLiquidation is MockValuationBase {
    using AccountContextHandler for AccountContext;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;

    function getFreeCollateral(address account, uint256 blockTime)
        external
        view
        returns (int256, int256[] memory)
    {
        return FreeCollateralAtTime.getFreeCollateralViewAtTime(account, blockTime);
    }

    function calculatefCashLocalLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) external returns (int256[] memory, int256) {
        LiquidatefCash.fCashContext memory c = _liquidateLocal(
            liquidateAccount,
            localCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            blockTime
        );

        return (c.fCashNotionalTransfers, c.localAssetCashFromLiquidator);
    }

    function _liquidateLocal(
        address liquidateAccount,
        uint16 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) private returns (LiquidatefCash.fCashContext memory) {
        require(fCashMaturities.length == maxfCashLiquidateAmounts.length);
        LiquidatefCash.fCashContext memory c;
        (c.accountContext, c.factors, c.portfolio) = LiquidationHelpers.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            0
        );

        // prettier-ignore
        (
            int256 cashBalance,
            /* int256 nTokenBalance */,
            /* uint256 lastClaimTime */,
            /* uint256 accountIncentiveDebt*/
        ) = BalanceHandler.getBalanceStorage(liquidateAccount, localCurrency);
        // Cash balance is used if liquidating negative fCash
        c.localCashBalanceUnderlying = c.factors.localAssetRate.convertToUnderlying(cashBalance);
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

        LiquidatefCash.liquidatefCashLocal(
            liquidateAccount,
            localCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        return c;
    }
}

contract MockCrossCurrencyfCashLiquidation is MockValuationBase {
    using AccountContextHandler for AccountContext;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;

    function getFreeCollateral(address account, uint256 blockTime) external view returns (int256, int256[] memory) {
        return FreeCollateralAtTime.getFreeCollateralViewAtTime(account, blockTime);
    }

    function calculatefCashCrossCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) external returns (int256[] memory, int256) {
        LiquidatefCash.fCashContext memory c = _liquidateCrossCurrency(
            liquidateAccount,
            localCurrency,
            fCashCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            blockTime
        );

        return (c.fCashNotionalTransfers, c.localAssetCashFromLiquidator);
    }

    function _liquidateCrossCurrency(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) private returns (LiquidatefCash.fCashContext memory) {
        require(fCashMaturities.length == maxfCashLiquidateAmounts.length); // dev: fcash maturity length mismatch
        LiquidatefCash.fCashContext memory c;
        (c.accountContext, c.factors, c.portfolio) = LiquidationHelpers.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            fCashCurrency
        );
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

        LiquidatefCash.liquidatefCashCrossCurrency(
            liquidateAccount,
            fCashCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        return c;
    }
}

library FreeCollateralAtTime {
    using AccountContextHandler for AccountContext;

    function getFreeCollateralViewAtTime(address account, uint256 blockTime)
        external
        view
        returns (int256, int256[] memory)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        // The internal free collateral function does not account for settled assets. The Notional SDK
        // can calculate the free collateral off chain if required at this point.
        // TODO: this should go forward in time
        require(!accountContext.mustSettleAssets(), "Assets not settled");
        return FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);
    }
}

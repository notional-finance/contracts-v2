// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/liquidation/LiquidationHelpers.sol";
import "../../internal/liquidation/LiquidateCurrency.sol";
import "../../internal/liquidation/LiquidatefCash.sol";
import "../../internal/valuation/FreeCollateral.sol";
import "../../external/actions/LiquidateCurrencyAction.sol";
import "./MockValuationLib.sol";
import "./AbstractSettingsRouter.sol";

contract MockLiquidationSetup is MockValuationLib, AbstractSettingsRouter {

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

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
        ETHRate memory localETHRate,
        ETHRate memory collateralETHRate,
        PrimeRate memory localPrimeRate,
        int256 localPrimeAvailable,
        int256 liquidationDiscount,
        int256 collateralUnderlyingPresentValue,
        int256 collateralAssetBalanceToSell
    ) external pure returns (int256, int256) {
        LiquidationFactors memory factors;
        factors.localETHRate = localETHRate;
        factors.collateralETHRate = collateralETHRate;
        factors.localPrimeRate = localPrimeRate;
        factors.localPrimeAvailable = localPrimeAvailable;

        return LiquidationHelpers.calculateLocalToPurchase(
            factors,
            liquidationDiscount,
            collateralUnderlyingPresentValue,
            collateralAssetBalanceToSell
        );
    }
}

contract MockLocalLiquidation is MockValuationLib, AbstractSettingsRouter {
    using SafeInt256 for int256;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    event LocalLiquidationTokens(
        int256 localPrimeCashFromLiquidator,
        int256 nTokensPurchased,
        int256 netCashChange,
        PortfolioState portfolioState
    );

    function calculateLocalCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint96 maxNTokenLiquidation
    ) external returns (int256, int256) {
        // prettier-ignore
        (
            int256 localPrimeCashFromLiquidator,
            BalanceState memory localBalanceState,
            /* PortfolioState memory portfolio*/,
            /* AccountContext memory accountContext */
        ) = _localCurrencyLiquidation(liquidateAccount, localCurrency, maxNTokenLiquidation, true);

        return (
            localPrimeCashFromLiquidator,
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
            int256 localPrimeCashFromLiquidator,
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
            localPrimeCashFromLiquidator,
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

        int256 localPrimeCashFromLiquidator =
            LiquidateCurrency.liquidateLocalCurrency(
                maxNTokenLiquidation,
                localBalanceState,
                factors
        );

        return (
            localPrimeCashFromLiquidator,
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

contract MockCollateralLiquidation is MockValuationLib, AbstractSettingsRouter {
    using SafeInt256 for int256;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    event CollateralLiquidationTokens(
        int256 localPrimeCashFromLiquidator,
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
            int256 localPrimeCashFromLiquidator,
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
            localPrimeCashFromLiquidator,
            _collateralPrimeCashToLiquidator(collateralBalanceState),
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
            int256 localPrimeCashFromLiquidator,
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
            localPrimeCashFromLiquidator,
            _collateralPrimeCashToLiquidator(collateralBalanceState),
            collateralBalanceState.netNTokenTransfer.neg(),
            collateralBalanceState.primeCashWithdraw,
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

        int256 localPrimeCashFromLiquidator =
            LiquidateCurrency.liquidateCollateralCurrency(
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                collateralBalanceState,
                factors
            );

        return (
            localPrimeCashFromLiquidator,
            collateralBalanceState,
            portfolio,
            accountContext
        );
    }

    function _collateralPrimeCashToLiquidator(BalanceState memory collateralBalanceState)
        private
        pure
        returns (int256)
    {
        // netPrimeTransfer is the cash claim withdrawn from collateral
        // liquidity tokens.
        return
            collateralBalanceState.netCashChange.neg().add(
                collateralBalanceState.primeCashWithdraw
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

contract MockLocalfCashLiquidation is MockValuationLib, AbstractSettingsRouter {
    using AccountContextHandler for AccountContext;
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

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

        return (c.fCashNotionalTransfers, c.localPrimeCashFromLiquidator);
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
        ) = BalanceHandler.getBalanceStorage(liquidateAccount, localCurrency, c.factors.localPrimeRate);
        // Cash balance is used if liquidating negative fCash
        c.localCashBalanceUnderlying = c.factors.localPrimeRate.convertToUnderlying(cashBalance);
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

contract MockCrossCurrencyfCashLiquidation is MockValuationLib, AbstractSettingsRouter {
    using AccountContextHandler for AccountContext;
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;
    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

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

        return (c.fCashNotionalTransfers, c.localPrimeCashFromLiquidator);
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
        require(!accountContext.mustSettleAssets(), "Assets not settled");
        return FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);
    }
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./ActionGuards.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/liquidation/LiquidatefCash.sol";
import "../../internal/liquidation/LiquidationHelpers.sol";
import "../../math/SafeInt256.sol";

contract LiquidatefCashAction is ActionGuards {
    using AccountContextHandler for AccountContext;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;

    event LiquidatefCashEvent(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        uint16 fCashCurrency,
        int256 netLocalFromLiquidator,
        uint256[] fCashMaturities,
        int256[] fCashNotionalTransfer
    );

    /// @notice Calculates fCash local liquidation amounts, may settle account so this can be called off
    // chain using a static call
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency local currency to liquidate
    /// @param fCashMaturities array of fCash maturities in the local currency to purchase, must be
    /// ordered descending
    /// @param maxfCashLiquidateAmounts max notional of fCash to liquidate in corresponding maturity,
    /// zero will represent no maximum
    /// @return an array of the notional amounts of fCash to transfer, corresponding to fCashMaturities
    /// @return amount of local currency required from the liquidator
    function calculatefCashLocalLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external nonReentrant returns (int256[] memory, int256) {
        uint256 blockTime = block.timestamp;
        LiquidatefCash.fCashContext memory c =
            _liquidateLocal(
                liquidateAccount,
                localCurrency,
                fCashMaturities,
                maxfCashLiquidateAmounts,
                blockTime
            );

        return (c.fCashNotionalTransfers, c.localAssetCashFromLiquidator);
    }

    /// @notice Liquidates fCash using local currency
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency local currency to liquidate
    /// @param fCashMaturities array of fCash maturities in the local currency to purchase, must be ordered
    /// descending
    /// @param maxfCashLiquidateAmounts max notional of fCash to liquidate in corresponding maturity,
    /// zero will represent no maximum
    /// @return an array of the notional amounts of fCash to transfer, corresponding to fCashMaturities
    /// @return amount of local currency required from the liquidator
    function liquidatefCashLocal(
        address liquidateAccount,
        uint16 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external nonReentrant returns (int256[] memory, int256) {
        uint256 blockTime = block.timestamp;
        LiquidatefCash.fCashContext memory c =
            _liquidateLocal(
                liquidateAccount,
                localCurrency,
                fCashMaturities,
                maxfCashLiquidateAmounts,
                blockTime
            );

        LiquidatefCash.finalizefCashLiquidation(
            liquidateAccount,
            msg.sender,
            localCurrency,
            localCurrency,
            fCashMaturities,
            c
        );

        emit LiquidatefCashEvent(
            liquidateAccount,
            msg.sender,
            localCurrency,
            localCurrency,
            c.localAssetCashFromLiquidator,
            fCashMaturities,
            c.fCashNotionalTransfers
        );

        return (c.fCashNotionalTransfers, c.localAssetCashFromLiquidator);
    }

    /// @notice Calculates fCash cross currency liquidation, can be called via staticcall off chain
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency local currency to liquidate
    /// @param fCashCurrency currency of fCash to purchase
    /// @param fCashMaturities array of fCash maturities in the local currency to purchase, must be ordered
    /// descending
    /// @param maxfCashLiquidateAmounts max notional of fCash to liquidate in corresponding maturity, zero
    /// will represent no maximum
    /// @return an array of the notional amounts of fCash to transfer, corresponding to fCashMaturities
    /// @return amount of local currency required from the liquidator
    function calculatefCashCrossCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external nonReentrant returns (int256[] memory, int256) {
        uint256 blockTime = block.timestamp;
        LiquidatefCash.fCashContext memory c =
            _liquidateCrossCurrency(
                liquidateAccount,
                localCurrency,
                fCashCurrency,
                fCashMaturities,
                maxfCashLiquidateAmounts,
                blockTime
            );

        return (c.fCashNotionalTransfers, c.localAssetCashFromLiquidator);
    }

    /// @notice Liquidates fCash across local to collateral currency
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency local currency to liquidate
    /// @param fCashCurrency currency of fCash to purchase
    /// @param fCashMaturities array of fCash maturities in the local currency to purchase, must be ordered
    /// descending
    /// @param maxfCashLiquidateAmounts max notional of fCash to liquidate in corresponding maturity, zero
    /// will represent no maximum
    /// @return an array of the notional amounts of fCash to transfer, corresponding to fCashMaturities
    /// @return amount of local currency required from the liquidator
    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external nonReentrant returns (int256[] memory, int256) {
        uint256 blockTime = block.timestamp;

        LiquidatefCash.fCashContext memory c =
            _liquidateCrossCurrency(
                liquidateAccount,
                localCurrency,
                fCashCurrency,
                fCashMaturities,
                maxfCashLiquidateAmounts,
                blockTime
            );

        LiquidatefCash.finalizefCashLiquidation(
            liquidateAccount,
            msg.sender,
            localCurrency,
            fCashCurrency,
            fCashMaturities,
            c
        );

        emit LiquidatefCashEvent(
            liquidateAccount,
            msg.sender,
            localCurrency,
            fCashCurrency,
            c.localAssetCashFromLiquidator,
            fCashMaturities,
            c.fCashNotionalTransfers
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
            /* uint256 accountIncentiveDebt */
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

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address) {
        return address(FreeCollateralExternal);
    }
}

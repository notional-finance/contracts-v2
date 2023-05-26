// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.17;

import {Constants} from "../../global/Constants.sol";
import {IERC20} from "../../../interfaces/IERC20.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {
    IPrimeCashHoldingsOracle,
    DepositData,
    RedeemData
} from "../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";

contract UnderlyingHoldingsOracle is IPrimeCashHoldingsOracle {
    NotionalProxy internal immutable NOTIONAL;
    address internal immutable UNDERLYING_TOKEN;
    uint8 internal immutable UNDERLYING_DECIMALS;
    uint256 private immutable UNDERLYING_PRECISION;
    bool internal immutable UNDERLYING_IS_ETH;

    constructor(NotionalProxy notional_, address underlying_) {
        NOTIONAL = notional_;
        UNDERLYING_TOKEN = underlying_;
        UNDERLYING_IS_ETH = underlying_ == Constants.ETH_ADDRESS;
        UNDERLYING_DECIMALS = UNDERLYING_IS_ETH ? 18 : IERC20(UNDERLYING_TOKEN).decimals();
        UNDERLYING_PRECISION = 10**UNDERLYING_DECIMALS;
    }
    
    /// @notice Returns a list of the various holdings for the prime cash
    /// currency
    function holdings() external view override returns (address[] memory) {
        return _holdings();
    }

    /// @notice Returns the underlying token that all holdings can be redeemed
    /// for.
    function underlying() external view override returns (address) {
        return UNDERLYING_TOKEN;
    }
    
    /// @notice Returns the native decimal precision of the underlying token
    function decimals() external view override returns (uint8) {
        return UNDERLYING_DECIMALS;
    }

    /// @notice Returns the total underlying held by the caller in all the
    /// listed holdings
    function getTotalUnderlyingValueStateful() external override returns (
        uint256 nativePrecision,
        uint256 internalPrecision
    ) {
        nativePrecision = _getTotalUnderlyingValueStateful();
        internalPrecision = nativePrecision * uint256(Constants.INTERNAL_TOKEN_PRECISION) / UNDERLYING_PRECISION;
    }

    function getTotalUnderlyingValueView() external view override returns (
        uint256 nativePrecision,
        uint256 internalPrecision
    ) {
        nativePrecision = _getTotalUnderlyingValueView();
        internalPrecision = nativePrecision * uint256(Constants.INTERNAL_TOKEN_PRECISION) / UNDERLYING_PRECISION;
    }

    function holdingValuesInUnderlying() external view override returns (uint256[] memory) {
        return _holdingValuesInUnderlying();
    }

    /// @notice Returns calldata for how to withdraw an amount
    function getRedemptionCalldata(uint256 withdrawAmount) external view override returns (RedeemData[] memory redeemData) {
        return _getRedemptionCalldata(withdrawAmount);
    }

    function getRedemptionCalldataForRebalancing(
        address[] calldata holdings_, 
        uint256[] calldata withdrawAmounts
    ) external view override returns (RedeemData[] memory redeemData) {
        return _getRedemptionCalldataForRebalancing(holdings_, withdrawAmounts);
    }

    function getDepositCalldataForRebalancing(
        address[] calldata holdings_, 
        uint256[] calldata depositAmounts
    ) external view override returns (DepositData[] memory depositData) {
        return _getDepositCalldataForRebalancing(holdings_, depositAmounts);
    }

    function _holdings() internal view virtual returns (address[] memory) {
        return new address[](0);
    }

    function _getTotalUnderlyingValueStateful() internal virtual returns (uint256) {
        return _getTotalUnderlyingValueView();
    }

    function _getTotalUnderlyingValueView() internal view virtual returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = UNDERLYING_TOKEN;
        return NOTIONAL.getStoredTokenBalances(tokens)[0];
    }

    function _holdingValuesInUnderlying() internal view virtual returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// @notice Returns calldata for how to withdraw an amount
    function _getRedemptionCalldata(
        uint256 /* withdrawAmount */ 
    ) internal view virtual returns (RedeemData[] memory /* redeemData */) { /* No-op */ }

    function _getRedemptionCalldataForRebalancing(
        address[] calldata /* holdings_ */, 
        uint256[] calldata /* withdrawAmounts */
    ) internal view virtual returns (RedeemData[] memory /* redeemData */) { /* No-op */ }

    function _getDepositCalldataForRebalancing(
        address[] calldata /* holdings_ */, 
        uint256[] calldata /* depositAmount */
    ) internal view virtual returns (DepositData[] memory /* depositData */) { /* No-op */ }
}

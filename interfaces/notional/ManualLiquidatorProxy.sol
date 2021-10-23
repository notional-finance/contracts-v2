// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../contracts/global/Types.sol";

interface ManualLiquidatorProxy {
    function initialize(
        uint16 localCurrencyId_,
        address localAssetAddress_,
        address localUnderlyingAddress_,
        bool hasTransferFee_
    ) external;

    function approveToken(address token, address spender) external;

    function enableCToken(address cToken) external;

    function transferOwnership(address newOwner) external;

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

    function batchBalanceTradeAction(BalanceActionWithTrades[] calldata actions) external;

    function batchBalanceAction(BalanceAction[] calldata actions) external;

    function nTokenRedeem(uint96 tokensToRedeem, bool sellTokenAssets) external returns (uint256);

    function claimNOTE() external returns (uint256);

    function localLiquidate(address account, uint96 maxNTokenLiquidation) external;

    function collateralLiquidate(
        address account,
        uint16 collateralCurrencyId,
        address collateralCurrencyAddress,
        address collateralUnderlyingAddress,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    ) external;

    function fcashLocalLiquidate(
        BalanceActionWithTrades[] calldata actions,
        address account,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external;

    function fcashCrossCurrencyLiquidate(
        BalanceActionWithTrades[] calldata actions,
        address account,
        uint16 fCashCurrency,
        address fCashAddress,
        address fCashUnderlyingAddress,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external;

    function tradeAndWrap(bytes calldata path, uint256 amountIn, uint256 amountOutMin) external;

    function wrapToWETH() external;

    function withdraw(address token, uint256 amount) external;
}

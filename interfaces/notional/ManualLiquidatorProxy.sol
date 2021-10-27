// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../contracts/global/Types.sol";

interface ManualLiquidatorProxy {
    function initialize(uint16 ifCashCurrencyId_) external;

    function approveToken(address token, address spender) external;

    function enableCToken(address cToken) external;

    function transferOwnership(address newOwner) external;

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

    function batchBalanceTradeAction(BalanceActionWithTrades[] calldata actions) external;

    function batchBalanceAction(BalanceAction[] calldata actions) external;

    function withdrawFromNotional(
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external returns (uint256);

    function nTokenRedeem(uint96 tokensToRedeem, bool sellTokenAssets) external returns (uint256);

    function claimNOTE() external returns (uint256);

    function liquidateLocalCurrency(
        address liquidateAccount,
        uint16 localCurrencyId,
        uint96 maxNTokenLiquidation
    ) external;

    function liquidateCollateralCurrency(
        address liquidateAccount,
        uint16 localCurrencyId,
        uint16 collateralCurrencyId,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        bool withdrawCollateral,
        bool redeemNToken
    ) external;

    function fcashLocalLiquidate(
        address liquidateAccount,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external;

    function fcashCrossCurrencyLiquidate(
        address liquidateAccount,
        uint16 localCurrencyId,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external;

    function mintCTokens(address[] calldata assets, uint256[] calldata amounts) external;

    function redeemCTokens(address[] calldata assets) external;

    function executeDexTrade(
        bytes calldata path,
        uint256 amountIn,
        uint256 amountOutMin
    ) external;

    function wrapToWETH() external;

    function withdrawToOwner(address token, uint256 amount) external;
}

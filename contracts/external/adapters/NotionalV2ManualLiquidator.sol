// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./NotionalV2BaseLiquidator.sol";

contract NotionalV2ManualLiquidator is NotionalV2BaseLiquidator {
    address public EXCHANGE;

    function initialize(
        NotionalProxy notionalV2_,
        address weth_,
        address cETH_,
        address owner_,
        address exchange_
    ) public initializer {
        __NotionalV2BaseLiquidator_init(notionalV2_, weth_, cETH_, owner_);
        EXCHANGE = exchange_;
    }

    function localLiquidateNoTransferFee(address account) public {}

    function localLiquidateWithTransferFee(address account) public {}

    /*function collateralLiquidateNoTransferFee(
        address account,
        uint256 localCurrencyId,
        address localCurrencyAddress,
        uint256 collateralCurrencyId,
        address collateralCurrencyAddress,
        address collateralUnderlyingAddress,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    ) public returns (uint256) {
        bytes memory encoded = abi.encode(
            LiquidationAction.CollateralCurrency_NoTransferFee,
            account,
            localCurrencyId,
            localCurrencyAddress,
            collateralCurrencyId,
            collateralCurrencyAddress,
            collateralUnderlyingAddress,
            maxCollateralLiquidation,
            maxNTokenLiquidation
        );
        _liquidateCollateral(
            LiquidationAction.CollateralCurrency_NoTransferFee,
            encoded,
            [localCurrencyAddress]
        );
        return 0;
    } */

    function collateralLiquidateWithTransferFee(
        address account,
        address localCurrency,
        bytes calldata params
    ) public {}

    function fcashLocalLiquidate(address account) public {}

    function fcashCrossCurrencyLiquidate(address account) public {}

    function executeDexTrade(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal override {}
}

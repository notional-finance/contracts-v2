// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./NotionalV2BaseLiquidator.sol";

contract NotionalV2ManualLiquidator is NotionalV2BaseLiquidator {
    function initialize(
        NotionalProxy notionalV2_,
        address weth_,
        address cETH_,
        address owner_
    ) public initializer {
        __NotionalV2BaseLiquidator_init(notionalV2_, weth_, cETH_, owner_);
    }

    function executeDexTrade(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal override {
        
    }
}

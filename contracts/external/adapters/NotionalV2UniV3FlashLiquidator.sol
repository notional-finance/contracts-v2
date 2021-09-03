// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./NotionalV2FlashLiquidator.sol";
import "../../../interfaces/uniswap/v3/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NotionalV2UniV3FlashLiquidator is NotionalV2FlashLiquidator {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    address private _swapRouter;

    constructor(
        address swapRouter,
        NotionalProxy notionalV2_,
        address lendingPool_,
        address addressProvider_,
        address weth_,
        address cETH_
    ) NotionalV2FlashLiquidator(notionalV2_, lendingPool_, addressProvider_, weth_, cETH_) {
        _swapRouter = swapRouter;
    }

    function executeDexTrade(
        address from,
        address to,
        uint256 amountOut,
        bytes memory params
    ) internal override {
        uint256 amountIn = IERC20(from).balanceOf(address(this));
        uint24 fee;
        uint256 deadline;
        uint160 priceLimit;

        // prettier-ignore
        (
            fee,
            deadline,
            priceLimit
        ) = abi.decode(params, (uint24, uint256, uint160));

        ISwapRouter.ExactOutputSingleParams memory swapParams = ISwapRouter.ExactOutputSingleParams(
            from,
            to,
            fee,
            address(this),
            deadline,
            amountOut,
            amountIn,
            priceLimit
        );

        ISwapRouter(_swapRouter).exactOutputSingle(swapParams);
    }
}

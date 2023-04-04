// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./NotionalV2FlashLiquidator.sol";
import "../../../interfaces/uniswap/v3/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract NotionalV2UniV3SwapRouter {
    ISwapRouter public immutable EXCHANGE;

    constructor(ISwapRouter exchange_) {
        EXCHANGE = exchange_;
    }

    function _executeDexTrade(
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal returns (uint256) {
        // prettier-ignore
        (
            bytes memory path,
            uint256 deadline
        ) = abi.decode(params, (bytes, uint256));

        ISwapRouter.ExactInputParams memory swapParams = ISwapRouter.ExactInputParams(
            path,
            address(this),
            deadline,
            amountIn,
            amountOutMin
        );

       return ISwapRouter(EXCHANGE).exactInput(swapParams);
    }
}

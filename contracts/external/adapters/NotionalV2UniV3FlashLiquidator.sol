// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./NotionalV2FlashLiquidator.sol";
import "interfaces/uniswap/v3/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NotionalV2UniV3FlashLiquidator is NotionalV2FlashLiquidator {
    ISwapRouter public immutable EXCHANGE;

    constructor(
        NotionalProxy notionalV2_,
        address lendingPool_,
        address weth_,
        address cETH_,
        address owner_,
        ISwapRouter exchange_
    ) NotionalV2FlashLiquidator(notionalV2_, lendingPool_, weth_, cETH_, owner_) {
        EXCHANGE = exchange_;
    }

    function executeDexTrade(
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal override returns (uint256) {
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

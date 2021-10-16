// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./NotionalV2FlashLiquidator.sol";
import "../../../interfaces/uniswap/v3/ISwapRouter.sol";
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
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal override returns (uint256) {
        uint24 fee;
        uint256 deadline;
        uint160 priceLimit;

        // prettier-ignore
        (
            fee,
            deadline,
            priceLimit
        ) = abi.decode(params, (uint24, uint256, uint160));

        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams(
            from,
            to,
            fee,
            address(this),
            deadline,
            amountIn,
            amountOutMin,
            priceLimit
        );

       return ISwapRouter(EXCHANGE).exactInputSingle(swapParams);
    }
}

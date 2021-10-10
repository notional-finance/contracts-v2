// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface WETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function transfer(address dst, uint256 wad) external returns (bool);
}

contract MockUniV3SwapRouter {
    address public WETH;
    address public OWNER;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    constructor(address weth_, address owner_) {
        WETH = weth_;
        OWNER = owner_;
    }

    function wrap() external {
        WETH9(WETH).deposit{value: address(this).balance}();
    }

    function withdraw(address asset, uint256 amount) external {
        IERC20(asset).transfer(OWNER, amount);
    }

    event DexTrade(address from, address to, uint256 amountIn, uint256 amountOutMin);

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).transfer(msg.sender, params.amountOutMinimum);
        emit DexTrade(params.tokenIn, params.tokenOut, params.amountIn, params.amountOutMinimum);
        return params.amountOutMinimum;        
    }

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

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountInMaximum);
        IERC20(params.tokenOut).transfer(msg.sender, params.amountOut);
        return params.amountInMaximum;
    }

    receive() external payable {}
}

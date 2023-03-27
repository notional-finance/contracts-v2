// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH9} from "../../interfaces/WETH9.sol";

contract MockUniV3SwapRouter {
    address public WETH;
    address public OWNER;

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
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

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        (
            address from,
            uint24 fee,
            address to
        ) = abi.decode(params.path, (address, uint24, address));

        IERC20(from).transferFrom(msg.sender, address(this), params.amountIn);
        IERC20(to).transfer(msg.sender, params.amountOutMinimum);
        emit DexTrade(from, to, params.amountIn, params.amountOutMinimum);
        return params.amountOutMinimum;        
    }

    receive() external payable {}
}

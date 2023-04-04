// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWstETH is IERC20 {
    function stEthPerToken() external view returns (uint256);
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
}

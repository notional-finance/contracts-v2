// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

interface IAToken {
  /**
   * @dev Returns the scaled balance of the user. The scaled balance is the sum of all the
   * updated stored balance divided by the reserve's liquidity index at the moment of the update
   * @param user The user whose balance is calculated
   * @return The scaled balance of the user
   **/
  function scaledBalanceOf(address user) external view returns (uint256);

  function UNDERLYING_ASSET_ADDRESS() external view returns (address);

  function symbol() external view returns (string memory);
}
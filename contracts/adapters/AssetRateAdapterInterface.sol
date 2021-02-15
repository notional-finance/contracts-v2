// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;

/**
 * @dev A modified aggregator interface when the latestRoundData call must modify
 * state of the underlying contract
 */
interface AssetRateAdapterInterface {

  function token() external view returns (address);
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);

  function getExchangeRateStateful() external returns (int);
  function getExchangeRateView() external view returns (int);
  function getAnnualizedSupplyRate() external view returns (uint);
}
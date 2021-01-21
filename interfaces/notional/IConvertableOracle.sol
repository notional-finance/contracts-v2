// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "../chainlink/AggregatorV3Interface.sol";

interface ICombinedOracle is AggregatorV3Interface {

    /**
     * @notice Emitted when a settlement rate has been set
     */
    event SettledRate(uint maturity);

    /**
     * @notice Returns the **settlement** rate for the fCash asset (not the exchange rate of underlying to ETH).
     * This rate will be set as the conversion from fCash back to cash at maturity. If the rate is not yet set, then
     * the current rate will be used.
     * @param maturity the timestamp of the maturity to get or set
     */
    function getOrSetSettledRate(uint maturity) external returns (int256 answer);

    /**
     * @notice Returns the **settlement** rate at the maturity, reverts if the value has not been set
     * @param maturity the timestamp of the maturity to get
     */
    function getSettledRate(uint maturity) external view returns (int256 answer);

    /**
     * @notice Returns the current exchange rate from the asset to the underlying
     */
    function getAssetRate() external view returns (uint answer);
} 
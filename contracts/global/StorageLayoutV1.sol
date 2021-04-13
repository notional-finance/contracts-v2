// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

/**
 * @notice Storage layout for the system. Do not change this file once deployed, future storage
 * layouts must inherit this and increment the version number.
 */
contract StorageLayoutV1 {
    /* Start Non-Mapping storage slots */
    uint16 internal maxCurrencyId;
    /* End Non-Mapping storage slots */

    // Returns the exchange rate between an underlying currency and ETH for free
    // collateral purposes. Mapping is from currency id to rate storage object.
    mapping(uint256 => ETHRateStorage) internal underlyingToETHRateMapping;
    // Returns the exchange rate between an underlying currency and asset for trading
    // and free collateral. Mapping is from currency id to rate storage object.
    mapping(uint256 => AssetRateStorage) internal assetToUnderlyingRateMapping;

    // address => currency id => maturity => ifCash value
    mapping(address => mapping(uint256 => mapping(uint256 => int256))) internal ifCashMapping;

    /* Authentication Mappings */
    // This is set to the timelock contract to execute governance functions
    address internal owner;
    // This is set to the governance token address
    address internal token;

    // A blanket allowance for a spender to transfer any of an account's nTokens. This would allow a user
    // to set an allowance on all nTokens for a particular integrating contract system.
    // owner => spender => transferAllowance
    mapping(address => mapping(address => uint256)) internal nTokenWhitelist;
    // Individual transfer allowances for nTokens used for ERC20
    // owner => spender => currencyId => transferAllowance
    mapping(address => mapping(address => mapping(uint16 => uint256))) internal nTokenAllowance;

    // Transfer operators
    mapping(address => bool) internal globalTransferOperator;
    mapping(address => mapping(address => bool)) internal accountAuthorizedTransferOperator;
}

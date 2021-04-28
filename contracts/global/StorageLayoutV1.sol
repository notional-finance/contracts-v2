// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Types.sol";

/**
 * @notice Storage layout for the system. Do not change this file once deployed, future storage
 * layouts must inherit this and increment the version number.
 */
contract StorageLayoutV1 {
    uint16 internal maxCurrencyId;

    // Returns the exchange rate between an underlying currency and ETH for free
    // collateral purposes. Mapping is from currency id to rate storage object.
    mapping(uint256 => ETHRateStorage) internal underlyingToETHRateMapping;
    // Returns the exchange rate between an underlying currency and asset for trading
    // and free collateral. Mapping is from currency id to rate storage object.
    mapping(uint256 => AssetRateStorage) internal assetToUnderlyingRateMapping;

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

    // Reverse mapping from token addresses to currency ids, only used for referencing in views
    // and checking for duplicate token listings.
    mapping(address => uint16) internal tokenAddressToCurrencyId;
}

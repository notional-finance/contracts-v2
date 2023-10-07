// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

contract LiquidatorStorageLayoutV1 {
    mapping(address => address) internal underlyingToCToken;
    address public owner;
    uint16 public ifCashCurrencyId;
}

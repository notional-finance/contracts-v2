// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;

contract NotionalV2LiquidatorStorageLayoutV1 {
    mapping(address => address) internal underlyingToCToken;
    address public owner;
    uint16 public ifCashCurrencyId;
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./StorageLayoutV1.sol";

contract StorageLayoutV2 is StorageLayoutV1 {
    address public treasuryManagerContract;
    mapping(address => uint256) internal reserveBuffer;
}

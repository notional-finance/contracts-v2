// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {StorageLayoutV1} from "./StorageLayoutV1.sol";

contract StorageLayoutV2 is StorageLayoutV1 {
    // Contract that manages the treasury and reserves
    address internal treasuryManagerContract;

    // Reserve buffers per currency, used in the TreasuryAction contract
    mapping(uint256 => uint256) internal reserveBuffer;

    // Pending owner used in the transfer ownership / claim ownership pattern
    address internal pendingOwner;
}

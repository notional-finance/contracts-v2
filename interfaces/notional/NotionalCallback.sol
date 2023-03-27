// SPDX-License-Identifier: BSUL-1.1
pragma solidity >=0.7.6;

interface NotionalCallback {
    function notionalCallback(address sender, address account, bytes calldata callbackdata) external;
}

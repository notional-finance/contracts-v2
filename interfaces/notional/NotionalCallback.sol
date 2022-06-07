// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;

interface NotionalCallback {
    function notionalCallback(address sender, address account, bytes calldata callbackdata) external;
}

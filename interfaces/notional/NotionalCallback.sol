// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;

interface NotionalCallback {
    function notionalCallback(address sender, address account, bytes calldata callbackdata) external;
}

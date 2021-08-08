// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/balances/BalanceHandler.sol";

contract BalanceStateHarness {
    using BalanceHandler for BalanceState;

    BalanceState symbolicBalanceState;

    function depositAssetToken(address account, int256 assetAmountExternal, bool forceTransfer) external returns (int256, int256) {
        return symbolicBalanceState.depositAssetToken(account, assetAmountExternal, forceTransfer);
    }

    function depositUnderlyingToken(
        address account,
        int256 underlyingAmountExternal
    ) public returns (int256) {
        return symbolicBalanceState.depositUnderlyingToken(account, underlyingAmountExternal);
    }
}
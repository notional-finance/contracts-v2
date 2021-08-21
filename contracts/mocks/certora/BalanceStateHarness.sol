// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/balances/BalanceHandler.sol";

contract BalanceStateHarness {
    using BalanceHandler for BalanceState;

    BalanceState symbolicBalanceState;

    function depositAssetToken(address account, int256 assetAmountExternal, bool forceTransfer) external returns (int256)  {
        return symbolicBalanceState.depositAssetToken(account, assetAmountExternal, forceTransfer);
    }

    function depositUnderlyingToken(
        address account,
        int256 underlyingAmountExternal
    ) public returns (int256) {
        return symbolicBalanceState.depositUnderlyingToken(account, underlyingAmountExternal);
    }

    // getters
    function getCurrencyId() external returns (uint256) { return symbolicBalanceState.currencyId; }
    function getStoredCashBalance() external returns (int256) { return symbolicBalanceState.storedCashBalance; }
    function getStoredNTokenBalance() external returns (int256) { return symbolicBalanceState.storedNTokenBalance; }
    function getNetCashChange() external returns (int256) { return symbolicBalanceState.netCashChange; }
    function getNetAssetTransferInternalPrecision() external returns (int256) { return symbolicBalanceState.netAssetTransferInternalPrecision; }
    function getNetNTokenTransfer() external returns (int256) { return symbolicBalanceState.netNTokenTransfer; }
    function getNetNTokenSupplyChange() external returns (int256) { return symbolicBalanceState.netNTokenSupplyChange; }
    function getLastClaimTime() external returns (uint256) { return symbolicBalanceState.lastClaimTime; }
    function getLastClaimSupply() external returns (uint256) { return symbolicBalanceState.lastClaimIntegralSupply; }
}
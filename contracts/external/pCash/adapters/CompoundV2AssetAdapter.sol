// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.17;

import {CErc20Interface} from "../../../../interfaces/compound/CErc20Interface.sol";
import {CEtherInterface} from "../../../../interfaces/compound/CEtherInterface.sol";
import {CTokenInterface} from "../../../../interfaces/compound/CTokenInterface.sol";
import {AssetRateAdapter} from "../../../../interfaces/notional/AssetRateAdapter.sol";
import {DepositData, RedeemData} from "../../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";

library CompoundV2AssetAdapter {
    function getRedemptionCalldata(
        address from,
        address assetToken,
        address assetRateAdapter,
        uint256 rateAdapterPrecision,
        uint256 redeemUnderlyingAmount
    ) internal view returns (RedeemData[] memory data) {
        address[] memory targets = new address[](1);
        bytes[] memory callData = new bytes[](1);
        targets[0] = assetToken;
        callData[0] = abi.encodeWithSelector(CErc20Interface.redeemUnderlying.selector, redeemUnderlyingAmount);

        data = new RedeemData[](1);
        data[0] = RedeemData(targets, callData, redeemUnderlyingAmount, assetToken);
    }

    function getRedemptionLength() internal view returns (uint256) {
        return 1;
    }

    function getDepositCalldata(
        address from,
        address assetToken,
        address assetRateAdapter,
        uint256 rateAdapterPrecision,
        uint256 depositUnderlyingAmount,
        bool underlyingIsETH
    ) internal view returns (DepositData[] memory data) {
        address[] memory targets = new address[](1);
        bytes[] memory callData = new bytes[](1);
        uint256[] memory msgValue = new uint256[](1);

        targets[0] = assetToken;
        msgValue[0] = underlyingIsETH ? depositUnderlyingAmount : 0;
        callData[0] = abi.encodeWithSelector(
            underlyingIsETH ? CEtherInterface.mint.selector : CErc20Interface.mint.selector, 
            depositUnderlyingAmount
        );

        data = new DepositData[](1);
        data[0] = DepositData(targets, callData, msgValue, depositUnderlyingAmount, assetToken);
    }

    function getUnderlyingValue(
        address assetRateAdapter, 
        uint256 rateAdapterPrecision, 
        uint256 assetBalance
    ) internal view returns (uint256) {
        return assetBalance * _toUint(AssetRateAdapter(assetRateAdapter).getExchangeRateView()) / rateAdapterPrecision;
    }
    
    function _toUint(int256 x) private pure returns (uint256) {
        require(x >= 0);
        return uint256(x);
    }
}

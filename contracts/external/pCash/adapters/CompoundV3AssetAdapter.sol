// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.17;

import {Deployments} from "../../../global/Deployments.sol";
import {DepositData, RedeemData} from "../../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";
import {WETH9} from "../../../../interfaces/WETH9.sol";
import {CTokenInterfaceV3} from "../../../../interfaces/compound/CTokenInterfaceV3.sol";
import {IERC20} from "../../../../interfaces/IERC20.sol";

library CompoundV3AssetAdapter {
    function getRedemptionCalldata(
        address from,
        address assetToken,
        address underlyingToken,
        uint256 redeemUnderlyingAmount
    ) internal view returns (RedeemData[] memory data) {
        if (redeemUnderlyingAmount == 0) {
            return data;
        }

        address[] memory targets = new address[](1);
        bytes[] memory callData = new bytes[](1);
        targets[0] = assetToken;
        callData[0] = abi.encodeWithSelector(
            CTokenInterfaceV3.withdraw.selector, 
            underlyingToken,
            redeemUnderlyingAmount
        );

        data = new RedeemData[](1);
        data[0] = RedeemData(targets, callData, redeemUnderlyingAmount, assetToken);
    }

    function getDepositCalldata(
        address from,
        address assetToken,
        address underlyingToken,
        uint256 depositUnderlyingAmount
    ) internal view returns (DepositData[] memory data) {
        if (depositUnderlyingAmount == 0) {
            return data;
        }

        address[] memory targets = new address[](2);
        bytes[] memory callData = new bytes[](2);
        uint256[] memory msgValue = new uint256[](2);

        targets[0] = underlyingToken;
        callData[0] = abi.encodeWithSelector(
            IERC20.approve.selector,
            assetToken,
            depositUnderlyingAmount
        );

        targets[1] = underlyingToken;
        callData[1] = abi.encodeWithSelector(
            CTokenInterfaceV3.supply.selector,
            assetToken,
            depositUnderlyingAmount
        );

        data = new DepositData[](1);
        data[0] = DepositData(targets, callData, msgValue, depositUnderlyingAmount, assetToken);
    }

    function getUnderlyingValue(address assetToken, uint256 assetBalance) internal view returns (uint256) {
       return 0;
    }
}

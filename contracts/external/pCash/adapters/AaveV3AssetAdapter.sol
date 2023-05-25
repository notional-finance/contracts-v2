// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.17;

import {Deployments} from "../../../global/Deployments.sol";
import {IWrappedAToken} from "../../../../interfaces/aave/IWrappedAToken.sol";
import {DepositData, RedeemData} from "../../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";
import {WETH9} from "../../../../interfaces/WETH9.sol";
import {IERC20} from "../../../../interfaces/IERC20.sol";

library AaveV3AssetAdapter {
    function getRedemptionCalldata(
        address from,
        address assetToken,
        uint256 redeemUnderlyingAmount,
        bool underlyingIsETH
    ) internal view returns (RedeemData[] memory data) {
        address[] memory targets = new address[](underlyingIsETH ? 2 : 1);
        bytes[] memory callData = new bytes[](underlyingIsETH ? 2 : 1);
        targets[0] = assetToken;
        callData[0] = abi.encodeWithSelector(
            IWrappedAToken.withdraw.selector, 
            redeemUnderlyingAmount,
            from,
            from
        );

        if (underlyingIsETH) {
            targets[1] = address(Deployments.WETH);
            callData[1] = abi.encodeWithSelector(WETH9.withdraw.selector, redeemUnderlyingAmount);
        }

        data = new RedeemData[](1);
        data[0] = RedeemData(targets, callData, redeemUnderlyingAmount, assetToken);
    }

    function getDepositCalldata(
        address from,
        address assetToken,
        address underlyingToken,
        uint256 depositUnderlyingAmount,
        bool underlyingIsETH
    ) internal view returns (DepositData[] memory data) {
        address[] memory targets = new address[](underlyingIsETH ? 3 : 2);
        bytes[] memory callData = new bytes[](underlyingIsETH ? 3 : 2);
        uint256[] memory msgValue = new uint256[](underlyingIsETH ? 3 : 2);

        if (underlyingIsETH) {
            targets[0] = address(Deployments.WETH);
            msgValue[0] = depositUnderlyingAmount;
            callData[0] = abi.encodeWithSelector(WETH9.deposit.selector, depositUnderlyingAmount);

            targets[1] = address(Deployments.WETH);
            callData[1] = abi.encodeWithSelector(IERC20.approve.selector, assetToken, depositUnderlyingAmount);

            targets[2] = assetToken;
            callData[2] = abi.encodeWithSelector(
                IWrappedAToken.deposit.selector, 
                depositUnderlyingAmount,
                from
            );        
        } else {
            targets[0] = underlyingToken;
            callData[0] = abi.encodeWithSelector(IERC20.approve.selector, assetToken, depositUnderlyingAmount);

            targets[1] = assetToken;
            callData[1] = abi.encodeWithSelector(
                IWrappedAToken.deposit.selector, 
                depositUnderlyingAmount,
                from
            );
        }

        data = new DepositData[](1);
        data[0] = DepositData(targets, callData, msgValue, depositUnderlyingAmount, assetToken);
    }

    function getUnderlyingValue(address assetToken, uint256 assetBalance) internal view returns (uint256) {
       return IWrappedAToken(assetToken).convertToAssets(assetBalance);
    }
}

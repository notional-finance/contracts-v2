// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.17;

import {UnderlyingHoldingsOracle} from "./UnderlyingHoldingsOracle.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {AaveV3AssetAdapter} from "./adapters/AaveV3AssetAdapter.sol";
import {DepositData, RedeemData} from "../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";

struct AaveV3DeploymentParams {
    NotionalProxy notional;
    address underlying;
    address waToken;
}

contract AaveV3HoldingsOracle is UnderlyingHoldingsOracle {
    uint8 private constant NUM_ASSET_TOKENS = 1;
    address internal immutable AAVE_ASSET_TOKEN;

    constructor(AaveV3DeploymentParams memory params) 
        UnderlyingHoldingsOracle(params.notional, params.underlying) {
        AAVE_ASSET_TOKEN = params.waToken;
    }

    function _holdings() internal view virtual override returns (address[] memory) {
        address[] memory result = new address[](NUM_ASSET_TOKENS);
        result[0] = AAVE_ASSET_TOKEN;
        return result;
    }

    function _holdingValuesInUnderlying() internal view virtual override returns (uint256[] memory) {
        uint256[] memory result = new uint256[](NUM_ASSET_TOKENS);
        address[] memory tokens = new address[](NUM_ASSET_TOKENS);
        tokens[0] = AAVE_ASSET_TOKEN;
        result[0] = _aaveUnderlyingValue(NOTIONAL.getStoredTokenBalances(tokens)[0]);
        return result;
    }

    function _getTotalUnderlyingValueView() internal view virtual override returns (uint256) {
        // NUM_ASSET_TOKENS + underlying
        address[] memory tokens = new address[](NUM_ASSET_TOKENS + 1);
        tokens[0] = UNDERLYING_TOKEN;
        tokens[1] = AAVE_ASSET_TOKEN;

        uint256[] memory balances = NOTIONAL.getStoredTokenBalances(tokens);
        return _aaveUnderlyingValue(balances[1]) + balances[0];
    }

    function _aaveUnderlyingValue(uint256 assetBalance) internal view returns (uint256) {
        return AaveV3AssetAdapter.getUnderlyingValue({
            assetToken: AAVE_ASSET_TOKEN,
            assetBalance: assetBalance
        });
    } 

    /// @notice Returns calldata for how to withdraw an amount
    function _getRedemptionCalldata(uint256 withdrawAmount) internal view virtual override returns (
        RedeemData[] memory redeemData
    ) {
        return AaveV3AssetAdapter.getRedemptionCalldata({
            from: address(NOTIONAL),
            assetToken: AAVE_ASSET_TOKEN,
            redeemUnderlyingAmount: withdrawAmount,
            underlyingIsETH: UNDERLYING_IS_ETH
        });
    }

    function _getRedemptionCalldataForRebalancing(
        address[] calldata holdings, 
        uint256[] calldata withdrawAmounts
    ) internal view virtual override returns (
        RedeemData[] memory redeemData
    ) {
        require(holdings.length == NUM_ASSET_TOKENS && holdings[0] == AAVE_ASSET_TOKEN);
        return _getRedemptionCalldata(withdrawAmounts[0]);
    }

    function _getDepositCalldataForRebalancing(
        address[] calldata holdings, 
        uint256[] calldata depositAmounts
    ) internal view virtual override returns (
        DepositData[] memory depositData
    ) {
        require(holdings.length == NUM_ASSET_TOKENS && holdings[0] == AAVE_ASSET_TOKEN);
        return AaveV3AssetAdapter.getDepositCalldata({
            from: address(NOTIONAL),
            assetToken: AAVE_ASSET_TOKEN,
            underlyingToken: UNDERLYING_TOKEN,
            depositUnderlyingAmount: depositAmounts[0],
            underlyingIsETH: UNDERLYING_IS_ETH
        });
    }
}

// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.8.17;

import {UnderlyingHoldingsOracle} from "./UnderlyingHoldingsOracle.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {AssetRateAdapter} from "../../../interfaces/notional/AssetRateAdapter.sol";
import {CompoundV2AssetAdapter} from "./adapters/CompoundV2AssetAdapter.sol";
import {DepositData, RedeemData} from "../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";

struct CompoundV2DeploymentParams {
    NotionalProxy notional;
    address underlying;
    address cToken;
    address cTokenRateAdapter;
}

contract CompoundV2HoldingsOracle is UnderlyingHoldingsOracle {
    uint8 private constant NUM_ASSET_TOKENS = 1;
    address internal immutable COMPOUND_ASSET_TOKEN;
    address internal immutable COMPOUND_RATE_ADAPTER;
    uint256 private immutable RATE_ADAPTER_PRECISION;

    constructor(CompoundV2DeploymentParams memory params) 
        UnderlyingHoldingsOracle(params.notional, params.underlying) {
        COMPOUND_ASSET_TOKEN = params.cToken;
        COMPOUND_RATE_ADAPTER = params.cTokenRateAdapter;
        RATE_ADAPTER_PRECISION = 10**AssetRateAdapter(COMPOUND_RATE_ADAPTER).decimals();
    }

    /// @notice Returns a list of the various holdings for the prime cash
    /// currency
    function _holdings() internal view virtual override returns (address[] memory) {
        address[] memory result = new address[](NUM_ASSET_TOKENS);
        result[0] = COMPOUND_ASSET_TOKEN;
        return result;
    }

    function _holdingValuesInUnderlying() internal view virtual override returns (uint256[] memory) {
        uint256[] memory result = new uint256[](NUM_ASSET_TOKENS);
        address[] memory tokens = new address[](NUM_ASSET_TOKENS);
        tokens[0] = COMPOUND_ASSET_TOKEN;
        result[0] = _compUnderlyingValue(NOTIONAL.getStoredTokenBalances(tokens)[0]);
        return result;
    }

    function _getTotalUnderlyingValueView() internal view virtual override returns (uint256) {
        // NUM_ASSET_TOKENS + underlying
        address[] memory tokens = new address[](NUM_ASSET_TOKENS + 1);
        tokens[0] = UNDERLYING_TOKEN;
        tokens[1] = COMPOUND_ASSET_TOKEN;

        uint256[] memory balances = NOTIONAL.getStoredTokenBalances(tokens);
        return _compUnderlyingValue(balances[1]) + balances[0];
    }

    function _compUnderlyingValue(uint256 assetBalance) internal view returns (uint256) {
        return CompoundV2AssetAdapter.getUnderlyingValue({
            assetRateAdapter: COMPOUND_RATE_ADAPTER,
            rateAdapterPrecision: RATE_ADAPTER_PRECISION,
            assetBalance: assetBalance
        });
    } 

    /// @notice Returns calldata for how to withdraw an amount
    function _getRedemptionCalldata(uint256 withdrawAmount) internal view virtual override returns (
        RedeemData[] memory redeemData
    ) {
        return CompoundV2AssetAdapter.getRedemptionCalldata({
            from: address(NOTIONAL),
            assetToken: COMPOUND_ASSET_TOKEN,
            assetRateAdapter: COMPOUND_RATE_ADAPTER,
            rateAdapterPrecision: RATE_ADAPTER_PRECISION,
            redeemUnderlyingAmount: withdrawAmount
        });
    }

    function _getRedemptionCalldataForRebalancing(
        address[] calldata holdings, 
        uint256[] calldata withdrawAmounts
    ) internal view virtual override returns (
        RedeemData[] memory redeemData
    ) {
        require(holdings.length == NUM_ASSET_TOKENS && holdings[0] == COMPOUND_ASSET_TOKEN);
        return _getRedemptionCalldata(withdrawAmounts[0]);
    }

    function _getDepositCalldataForRebalancing(
        address[] calldata holdings, 
        uint256[] calldata depositAmounts
    ) internal view virtual override returns (
        DepositData[] memory depositData
    ) {
        require(holdings.length == NUM_ASSET_TOKENS && holdings[0] == COMPOUND_ASSET_TOKEN);
        return CompoundV2AssetAdapter.getDepositCalldata({
            from: address(NOTIONAL),
            assetToken: COMPOUND_ASSET_TOKEN,
            assetRateAdapter: COMPOUND_RATE_ADAPTER,
            rateAdapterPrecision: RATE_ADAPTER_PRECISION,
            depositUnderlyingAmount: depositAmounts[0],
            underlyingIsETH: UNDERLYING_IS_ETH
        });
    }
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Token, TokenType, TokenStorage, AssetRateStorage, AssetRateParameters} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {BasePatchFixRouter, NotionalProxy} from "./BasePatchFixRouter.sol";
import {StorageLayoutV2} from "../../global/StorageLayoutV2.sol";
import {TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {AssetRate} from "../../internal/markets/AssetRate.sol";
import {CErc20Interface} from "../../../interfaces/compound/CErc20Interface.sol";
import {ncTokenInterface} from "../../../interfaces/notional/ncTokenInterface.sol";
import {AssetRateAdapter} from "../../../interfaces/notional/AssetRateAdapter.sol";

contract MigrateCTokens is BasePatchFixRouter, StorageLayoutV2 {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using SafeERC20 for ERC20;
    using TokenHandler for Token;

    address public immutable ncETH;
    address public immutable ncDAI;
    address public immutable ncUSDC;
    address public immutable ncWBTC;

    constructor(
        address currentRouter,
        address finalRouter,
        NotionalProxy proxy,
        address ncETH_,
        address ncDAI_,
        address ncUSDC_,
        address ncWBTC_
    ) BasePatchFixRouter(currentRouter, finalRouter, proxy) {
        ncETH = ncETH_;
        ncDAI = ncDAI_;
        ncUSDC = ncUSDC_;
        ncWBTC = ncWBTC_;
    }

    /// @notice This method is called during a delegate call context while this contract is the implementation of the
    /// Notional proxy. This happens prior to an upgrade to the final router.
    function _patchFix() internal override {
        _migrateCurrency(1, ncETH);
        _migrateCurrency(2, ncDAI);
        _migrateCurrency(3, ncUSDC);
        _migrateCurrency(4, ncWBTC);
    }

    function _migrateCurrency(uint16 currencyId, address ncToken) private {
        Token memory assetToken = TokenHandler.getAssetToken(currencyId);

        if (currencyId == Constants.ETH_CURRENCY_ID) {
            require(assetToken.tokenType == TokenType.cETH);
        } else {
            require(assetToken.tokenType == TokenType.cToken);        
        }

        // Initialize ncToken contract with the final cToken rate
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(currencyId);
        ncTokenInterface(ncToken).initialize(assetRate.rate.toUint());
        
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(currencyId);

        // Redeem asset to underlying
        uint256 underlyingBefore = underlyingToken.balanceOf(address(this));
        CErc20Interface(assetToken.tokenAddress).redeem(
            ERC20(assetToken.tokenAddress).balanceOf(address(this))
        );
        uint256 underlyingChange = underlyingToken.balanceOf(address(this)).sub(underlyingBefore);

        // Mint ncTokens
        if (currencyId == Constants.ETH_CURRENCY_ID) {
            ncTokenInterface(ncToken).mint{value: underlyingChange}();
        } else {
            // Revoke cToken approval
            ERC20(underlyingToken.tokenAddress).safeApprove(assetToken.tokenAddress, 0);
            // Approve ncToken to pull underyling
            ERC20(underlyingToken.tokenAddress).safeApprove(ncToken, type(uint256).max);
            ncTokenInterface(ncToken).mint(underlyingChange);
        }

        // Sets the asset token to ncToken
        require(assetToken.maxCollateralBalance <= type(uint72).max);
        TokenHandler.setToken(currencyId, false, TokenStorage({
            tokenAddress: ncToken,
            hasTransferFee: false,
            decimalPlaces: ERC20(ncToken).decimals(),
            tokenType: currencyId == Constants.ETH_CURRENCY_ID ? TokenType.cETH : TokenType.cToken,
            maxCollateralBalance: uint72(assetToken.maxCollateralBalance)
        }));

        // Remap the token address to currency id information
        delete tokenAddressToCurrencyId[assetToken.tokenAddress];
        tokenAddressToCurrencyId[ncToken] = currencyId;

        // Set asset rate adapter
        /// NOTE: ncToken also implements the AssetRateAdapter interface
        _setAssetRateAdapter(currencyId, ncToken);
    }

    function _setAssetRateAdapter(uint16 currencyId, address adapter) private {
        mapping(uint256 => AssetRateStorage) storage store = LibStorage.getAssetRateStorage();
        AssetRateStorage storage ar = store[currencyId];
        ar.rateOracle = AssetRateAdapter(adapter);
    }
}

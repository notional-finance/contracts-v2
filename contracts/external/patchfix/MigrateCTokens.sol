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

    uint16 public immutable CURRENCY_ID;
    address public immutable NC_TOKEN;

    event ListCurrency(uint16 newCurrencyId);
    event UpdateAssetRate(uint16 currencyId);

    constructor(
        address currentRouter,
        address finalRouter,
        NotionalProxy proxy,
        uint16 currencyId,
        address ncToken
    ) BasePatchFixRouter(currentRouter, finalRouter, proxy) {
        CURRENCY_ID = currencyId;
        NC_TOKEN = ncToken;
    }

    /// @notice This method is called during a delegate call context while this contract is the implementation of the
    /// Notional proxy. This happens prior to an upgrade to the final router.
    function _patchFix() internal override {
        Token memory assetToken = TokenHandler.getAssetToken(CURRENCY_ID);

        if (CURRENCY_ID == Constants.ETH_CURRENCY_ID) {
            require(assetToken.tokenType == TokenType.cETH);
        } else {
            require(assetToken.tokenType == TokenType.cToken);        
        }

        // Initialize ncToken contract with the final cToken rate
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(CURRENCY_ID);
        ncTokenInterface(NC_TOKEN).initialize(assetRate.rate.toUint());
        
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(CURRENCY_ID);

        // Redeem asset to underlying
        uint256 underlyingBefore = underlyingToken.balanceOf(address(this));
        CErc20Interface(assetToken.tokenAddress).redeem(
            ERC20(assetToken.tokenAddress).balanceOf(address(this))
        );
        uint256 underlyingChange = underlyingToken.balanceOf(address(this)).sub(underlyingBefore);

        // Mint ncTokens
        if (CURRENCY_ID == Constants.ETH_CURRENCY_ID) {
            ncTokenInterface(NC_TOKEN).mint{value: underlyingChange}();
        } else {
            // Revoke cToken approval
            ERC20(underlyingToken.tokenAddress).safeApprove(assetToken.tokenAddress, 0);
            // Approve ncToken to pull underyling
            ERC20(underlyingToken.tokenAddress).safeApprove(NC_TOKEN, type(uint256).max);
            ncTokenInterface(NC_TOKEN).mint(underlyingChange);
        }

        // Sets the asset token to ncToken
        require(assetToken.maxCollateralBalance <= type(uint72).max);
        _setTokenStorage(TokenStorage({
            tokenAddress: NC_TOKEN,
            hasTransferFee: false,
            decimalPlaces: ERC20(NC_TOKEN).decimals(),
            tokenType: CURRENCY_ID == Constants.ETH_CURRENCY_ID ? TokenType.cETH : TokenType.cToken,
            maxCollateralBalance: uint72(assetToken.maxCollateralBalance)
        }));

        // Remap the token address to currency id information
        delete tokenAddressToCurrencyId[assetToken.tokenAddress];
        tokenAddressToCurrencyId[NC_TOKEN] = CURRENCY_ID;

        emit ListCurrency(CURRENCY_ID);

        // Set asset rate adapter
        /// NOTE: ncToken also implements the AssetRateAdapter interface
        _setAssetRateAdapter();
    }

    function _setTokenStorage(TokenStorage memory tokenStorage) private {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();
        /// NOTE: underlying = false
        store[CURRENCY_ID][false] = tokenStorage;
    }

    function _setAssetRateAdapter() private {
        mapping(uint256 => AssetRateStorage) storage store = LibStorage.getAssetRateStorage();
        AssetRateStorage storage ar = store[CURRENCY_ID];
        ar.rateOracle = AssetRateAdapter(NC_TOKEN);
        emit UpdateAssetRate(CURRENCY_ID);
    }
}

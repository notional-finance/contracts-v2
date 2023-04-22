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
import {nwTokenInterface} from "../../../interfaces/notional/nwTokenInterface.sol";
import {AssetRateAdapter} from "../../../interfaces/notional/AssetRateAdapter.sol";

contract MigrateCTokens is BasePatchFixRouter, StorageLayoutV2 {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using SafeERC20 for ERC20;
    using TokenHandler for Token;

    event ListCurrency(uint16 newCurrencyId);
    event UpdateAssetRate(uint16 currencyId);

    address public immutable nwETH;
    address public immutable nwDAI;
    address public immutable nwUSDC;
    address public immutable nwWBTC;
    uint256 internal constant COMPOUND_RETURN_CODE_NO_ERROR = 0;

    constructor(
        address currentRouter,
        address finalRouter,
        NotionalProxy proxy,
        address _nwETH,
        address _nwDAI,
        address _nwUSDC,
        address _nwWBTC
    ) BasePatchFixRouter(currentRouter, finalRouter, proxy) {
        nwETH = _nwETH;
        nwDAI = _nwDAI;
        nwUSDC = _nwUSDC;
        nwWBTC = _nwWBTC;
    }

    /// @notice This method is called during a delegate call context while this contract is the implementation of the
    /// Notional proxy. This happens prior to an upgrade to the final router.
    function _patchFix() internal override {
        _migrateToken(1, nwETH);
        _migrateToken(2, nwDAI);
        _migrateToken(3, nwUSDC);
        _migrateToken(4, nwWBTC);
    }
        
    function _migrateToken(uint16 currencyId, address ncToken) private {
        Token memory assetToken = TokenHandler.getAssetToken(currencyId);

        if (currencyId == Constants.ETH_CURRENCY_ID) {
            require(assetToken.tokenType == TokenType.cETH);
        } else {
            require(assetToken.tokenType == TokenType.cToken);
        }

        // Initialize ncToken contract with the final cToken rate
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(currencyId);
        nwTokenInterface(ncToken).initialize(assetRate.rate.toUint());
        
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(currencyId);

        // Redeem asset to underlying
        uint256 underlyingBefore = underlyingToken.balanceOf(address(this));
        uint256 success = CErc20Interface(assetToken.tokenAddress).redeem(
            ERC20(assetToken.tokenAddress).balanceOf(address(this))
        );
        require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Redeem Failed");
        uint256 underlyingChange = underlyingToken.balanceOf(address(this)).sub(underlyingBefore);

        // Mint ncTokens
        if (currencyId == Constants.ETH_CURRENCY_ID) {
            nwTokenInterface(ncToken).mint{value: underlyingChange}();
        } else {
            // Revoke cToken approval
            ERC20(underlyingToken.tokenAddress).safeApprove(assetToken.tokenAddress, 0);
            // Approve ncToken to pull underlying
            ERC20(underlyingToken.tokenAddress).safeApprove(ncToken, type(uint256).max);
            nwTokenInterface(ncToken).mint(underlyingChange);
        }

        // Sets the asset token to ncToken
        require(assetToken.maxCollateralBalance <= type(uint72).max);
        _setTokenStorage(TokenStorage({
            tokenAddress: ncToken,
            hasTransferFee: false,
            decimalPlaces: ERC20(ncToken).decimals(),
            tokenType: currencyId == Constants.ETH_CURRENCY_ID ? TokenType.cETH : TokenType.cToken,
            maxCollateralBalance: uint72(assetToken.maxCollateralBalance)
        }), currencyId);

        // Remap the token address to currency id information
        delete tokenAddressToCurrencyId[assetToken.tokenAddress];
        tokenAddressToCurrencyId[ncToken] = currencyId;

        emit ListCurrency(currencyId);

        // Set asset rate adapter
        /// NOTE: ncToken also implements the AssetRateAdapter interface
        _setAssetRateAdapter(currencyId, ncToken);
    }

    function _setTokenStorage(TokenStorage memory tokenStorage, uint16 currencyId) private {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();
        /// NOTE: underlying = false
        store[currencyId][false] = tokenStorage;
    }

    function _setAssetRateAdapter(uint16 currencyId, address ncToken) private {
        mapping(uint256 => AssetRateStorage) storage store = LibStorage.getAssetRateStorage();
        AssetRateStorage storage ar = store[currencyId];
        ar.rateOracle = AssetRateAdapter(ncToken);
        emit UpdateAssetRate(currencyId);
    }
}

// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {Token} from "../../../global/Types.sol";
import {SafeUint256} from "../../../math/SafeUint256.sol";

import {GenericToken} from "./GenericToken.sol";

import {CErc20Interface} from "../../../../interfaces/compound/CErc20Interface.sol";
import {CEtherInterface} from "../../../../interfaces/compound/CEtherInterface.sol";
import {IERC20} from "../../../../interfaces/IERC20.sol";

library CompoundHandler {
    using SafeUint256 for uint256;

    // Return code for cTokens that represents no error
    uint256 internal constant COMPOUND_RETURN_CODE_NO_ERROR = 0;

    function redeemCETH(
        Token memory assetToken,
        uint256 assetAmountExternal
    ) internal returns (uint256 underlyingAmountExternal) {
        uint256 startingBalance = address(this).balance;

        uint256 success = CErc20Interface(assetToken.tokenAddress).redeem(assetAmountExternal);
        require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Redeem");

        uint256 endingBalance = address(this).balance;

        underlyingAmountExternal = endingBalance.sub(startingBalance);
    }

    function redeem(
        Token memory assetToken,
        Token memory underlyingToken,
        uint256 assetAmountExternal
    ) internal returns (uint256 underlyingAmountExternal) {
        uint256 startingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));

        uint256 success = CErc20Interface(assetToken.tokenAddress).redeem(assetAmountExternal);
        require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Redeem");

        uint256 endingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));

        underlyingAmountExternal = endingBalance.sub(startingBalance);
    }
}
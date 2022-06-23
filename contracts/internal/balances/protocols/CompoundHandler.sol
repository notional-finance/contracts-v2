// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./GenericToken.sol";
import "../../../../interfaces/compound/CErc20Interface.sol";
import "../../../../interfaces/compound/CEtherInterface.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../../../global/Types.sol";

library CompoundHandler {
    using SafeMath for uint256;

    // Return code for cTokens that represents no error
    uint256 internal constant COMPOUND_RETURN_CODE_NO_ERROR = 0;

    function mintCETH(Token memory token, uint256 underlyingAmountExternal) internal {
        // Reverts on error
        CEtherInterface(token.tokenAddress).mint{value: underlyingAmountExternal}();
    }

    function mint(Token memory token, uint256 underlyingAmountExternal) internal {
        uint256 success = CErc20Interface(token.tokenAddress).mint(underlyingAmountExternal);
        require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Mint");
    }

    function redeemCETH(
        Token memory assetToken,
        address account,
        uint256 assetAmountExternal
    ) internal returns (uint256 underlyingAmountExternal) {
        // Although the contract should never end with any ETH or underlying token balances, we still do this
        // starting and ending check in the case that tokens are accidentally sent to the contract address. They
        // will not be sent to some lucky address in a windfall.
        uint256 startingBalance = address(this).balance;

        uint256 success = CErc20Interface(assetToken.tokenAddress).redeem(assetAmountExternal);
        require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Redeem");

        uint256 endingBalance = address(this).balance;

        underlyingAmountExternal = endingBalance.sub(startingBalance);

        // Withdraws the underlying amount out to the destination account
        GenericToken.transferNativeTokenOut(account, underlyingAmountExternal);
    }

    function redeem(
        Token memory assetToken,
        Token memory underlyingToken,
        address account,
        uint256 assetAmountExternal
    ) internal returns (uint256 underlyingAmountExternal) {
        // Although the contract should never end with any ETH or underlying token balances, we still do this
        // starting and ending check in the case that tokens are accidentally sent to the contract address. They
        // will not be sent to some lucky address in a windfall.
        uint256 startingBalance = GenericToken.checkBalanceViaSelector(underlyingToken.tokenAddress, address(this), GenericToken.defaultBalanceOfSelector);

        uint256 success = CErc20Interface(assetToken.tokenAddress).redeem(assetAmountExternal);
        require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Redeem");

        uint256 endingBalance = GenericToken.checkBalanceViaSelector(underlyingToken.tokenAddress, address(this), GenericToken.defaultBalanceOfSelector);

        underlyingAmountExternal = endingBalance.sub(startingBalance);

        // Withdraws the underlying amount out to the destination account
        GenericToken.safeTransferOut(underlyingToken.tokenAddress, account, underlyingAmountExternal);
    }
}
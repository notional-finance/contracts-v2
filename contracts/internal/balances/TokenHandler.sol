// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../math/SafeInt256.sol";
import "../../global/LibStorage.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "interfaces/IEIP20NonStandard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Handles all external token transfers and events
library TokenHandler {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    function setMaxCollateralBalance(uint256 currencyId, uint72 maxCollateralBalance) internal {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();
        TokenStorage storage tokenStorage = store[currencyId][false];
        tokenStorage.maxCollateralBalance = maxCollateralBalance;
    } 

    function getAssetToken(uint256 currencyId) internal view returns (Token memory) {
        return _getToken(currencyId, false);
    }

    function getUnderlyingToken(uint256 currencyId) internal view returns (Token memory) {
        return _getToken(currencyId, true);
    }

    /// @notice Gets token data for a particular currency id, if underlying is set to true then returns
    /// the underlying token. (These may not always exist)
    function _getToken(uint256 currencyId, bool underlying) private view returns (Token memory) {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();
        TokenStorage storage tokenStorage = store[currencyId][underlying];

        return
            Token({
                tokenAddress: tokenStorage.tokenAddress,
                hasTransferFee: tokenStorage.hasTransferFee,
                // No overflow, restricted on storage
                decimals: int256(10**tokenStorage.decimalPlaces),
                tokenType: tokenStorage.tokenType,
                maxCollateralBalance: tokenStorage.maxCollateralBalance
            });
    }

    /// @notice Sets a token for a currency id.
    function setToken(
        uint256 currencyId,
        bool underlying,
        TokenStorage memory tokenStorage
    ) internal {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();

        if (tokenStorage.tokenType == TokenType.Ether && currencyId == Constants.ETH_CURRENCY_ID) {
            // Hardcoded parameters for ETH just to make sure we don't get it wrong.
            TokenStorage storage ts = store[currencyId][true];
            ts.tokenAddress = address(0);
            ts.hasTransferFee = false;
            ts.tokenType = TokenType.Ether;
            ts.decimalPlaces = Constants.ETH_DECIMAL_PLACES;
            ts.maxCollateralBalance = 0;

            return;
        }

        // Check token address
        require(tokenStorage.tokenAddress != address(0), "TH: address is zero");
        // Once a token is set we cannot override it. In the case that we do need to do change a token address
        // then we should explicitly upgrade this method to allow for a token to be changed.
        Token memory token = _getToken(currencyId, underlying);
        require(
            token.tokenAddress == tokenStorage.tokenAddress || token.tokenAddress == address(0),
            "TH: token cannot be reset"
        );

        require(0 < tokenStorage.decimalPlaces 
            && tokenStorage.decimalPlaces <= Constants.MAX_DECIMAL_PLACES, "TH: invalid decimals");

        // Validate token type
        require(tokenStorage.tokenType != TokenType.Ether); // dev: ether can only be set once
        if (underlying) {
            // Underlying tokens cannot have max collateral balances, the contract only has a balance temporarily
            // during mint and redeem actions.
            require(tokenStorage.maxCollateralBalance == 0); // dev: underlying cannot have max collateral balance
            require(tokenStorage.tokenType == TokenType.UnderlyingToken); // dev: underlying token inconsistent
        } else {
            require(tokenStorage.tokenType != TokenType.UnderlyingToken); // dev: underlying token inconsistent
        }

        if (tokenStorage.tokenType == TokenType.cToken) {
            // Set the approval for the underlying so that we can mint cTokens
            Token memory underlyingToken = getUnderlyingToken(currencyId);
            // ERC20 tokens should return true on success for an approval, but Tether
            // does not return a value here so we use the NonStandard interface here to
            // check that the approval was successful.
            IEIP20NonStandard(underlyingToken.tokenAddress).approve(
                tokenStorage.tokenAddress,
                type(uint256).max
            );
            checkReturnCode();
        }

        store[currencyId][underlying] = tokenStorage;
    }

    /// @notice This method only works with cTokens, it's unclear how we can make this more generic
    function mint(Token memory token, uint256 underlyingAmountExternal) internal returns (int256) {
        uint256 startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

        uint256 success;
        if (token.tokenType == TokenType.cToken) {
            success = CErc20Interface(token.tokenAddress).mint(underlyingAmountExternal);
        } else if (token.tokenType == TokenType.cETH) {
            // Reverts on error
            CEtherInterface(token.tokenAddress).mint{value: msg.value}();
        } else {
            revert(); // dev: non mintable token
        }

        require(success == Constants.COMPOUND_RETURN_CODE_NO_ERROR, "Mint");
        uint256 endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

        // This is the starting and ending balance in external precision
        return SafeInt256.toInt(endingBalance.sub(startingBalance));
    }

    function redeem(
        Token memory assetToken,
        Token memory underlyingToken,
        uint256 assetAmountExternal
    ) internal returns (int256) {
        uint256 startingBalance;
        if (assetToken.tokenType == TokenType.cETH) {
            startingBalance = address(this).balance;
        } else if (assetToken.tokenType == TokenType.cToken) {
            startingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));
        } else {
            revert(); // dev: non redeemable failure
        }

        uint256 success = CErc20Interface(assetToken.tokenAddress).redeem(assetAmountExternal);
        require(success == Constants.COMPOUND_RETURN_CODE_NO_ERROR, "Redeem");

        uint256 endingBalance;
        if (assetToken.tokenType == TokenType.cETH) {
            endingBalance = address(this).balance;
        } else {
            endingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));
        }

        // Underlying token external precision
        return SafeInt256.toInt(endingBalance.sub(startingBalance));
    }

    /// @notice Handles transfers into and out of the system denominated in the external token decimal
    /// precision.
    function transfer(
        Token memory token,
        address account,
        int256 netTransferExternal
    ) internal returns (int256) {
        if (netTransferExternal > 0) {
            // Deposits must account for transfer fees.
            netTransferExternal = _deposit(token, account, uint256(netTransferExternal));
        } else if (token.tokenType == TokenType.Ether) {
            require(netTransferExternal <= 0); // dev: cannot deposit ether
            address payable accountPayable = payable(account);
            // This does not work with contracts, but is reentrancy safe. If contracts want to withdraw underlying
            // ETH they will have to withdraw the cETH token and then redeem it manually.
            accountPayable.transfer(uint256(netTransferExternal.neg()));
        } else {
            safeTransferOut(
                token.tokenAddress,
                account,
                // netTransferExternal is zero or negative here
                uint256(netTransferExternal.neg())
            );
        }

        return netTransferExternal;
    }

    /// @notice Handles token deposits into Notional. If there is a transfer fee then we must
    /// calculate the net balance after transfer. Amounts are denominated in the destination token's
    /// precision.
    function _deposit(
        Token memory token,
        address account,
        uint256 amount
    ) private returns (int256) {
        uint256 startingBalance;
        uint256 endingBalance;
        uint256 finalAmountAdjustment;

        if (token.hasTransferFee) {
            startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));
        }

        safeTransferIn(token.tokenAddress, account, amount);

        if (token.hasTransferFee || token.maxCollateralBalance > 0) {
            endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));
        }

        if (token.maxCollateralBalance > 0) {
            int256 internalPrecisionBalance = convertToInternal(token, SafeInt256.toInt(endingBalance));
            // Max collateral balance is stored as uint72, no overflow
            require(internalPrecisionBalance <= SafeInt256.toInt(token.maxCollateralBalance)); // dev: over max collateral balance
        }

        if (token.decimals < Constants.INTERNAL_TOKEN_PRECISION && token.tokenType != TokenType.UnderlyingToken) {
            // If decimals is less than internal token precision, we change how much the the user is credited
            // during this deposit so that the protocol accrues the dust (not the user's cash balance)
            finalAmountAdjustment = 1;
        }

        // Math is done in uint inside these statements and will revert on negative
        if (token.hasTransferFee) {
            return SafeInt256.toInt(endingBalance.sub(startingBalance).sub(finalAmountAdjustment));
        } else {
            // If amount == 0 then will revert if final amount adjustment is 1
            return SafeInt256.toInt(amount.sub(finalAmountAdjustment));
        }
    }

    function convertToInternal(Token memory token, int256 amount) internal pure returns (int256) {
        // If token decimals is greater than INTERNAL_TOKEN_PRECISION then this will truncate
        // down to the internal precision. Resulting dust will accumulate to the protocol.
        // If token decimals is less than INTERNAL_TOKEN_PRECISION then this will add zeros to the
        // end of amount and will not result in dust.
        if (token.decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        return amount.mul(Constants.INTERNAL_TOKEN_PRECISION).div(token.decimals);
    }

    function convertToExternal(Token memory token, int256 amount) internal pure returns (int256) {
        if (token.decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        // If token decimals is greater than INTERNAL_TOKEN_PRECISION then this will increase amount
        // by adding a number of zeros to the end. If token decimals is less than INTERNAL_TOKEN_PRECISION
        // then we will end up truncating off the lower portion of the amount. This can result in the
        // internal cash balances being different from the actual cash balances. This can result in dust
        // amounts.
        // For this case, when withdrawing out of the protocol we want to round down such that the
        // protocol will retain more balance than the user. This already happens in the conversion below. When
        // depositing, we want to decrease the amount of cash balance we credit to the user by a dust amount
        // so that the protocol accrues the dust (rather than the user's balance). This is implemented in _deposit
        // above.
        return amount.mul(token.decimals).div(Constants.INTERNAL_TOKEN_PRECISION);
    }

    function transferIncentive(address account, uint256 tokensToTransfer) internal {
        safeTransferOut(Constants.NOTE_TOKEN_ADDRESS, account, tokensToTransfer);
    }

    function safeTransferOut(
        address token,
        address account,
        uint256 amount
    ) private {
        IEIP20NonStandard(token).transfer(account, amount);
        checkReturnCode();
    }

    function safeTransferIn(
        address token,
        address account,
        uint256 amount
    ) private {
        IEIP20NonStandard(token).transferFrom(account, address(this), amount);
        checkReturnCode();
    }

    function checkReturnCode() private pure {
        bool success;
        uint256[1] memory result;
        assembly {
            switch returndatasize()
                case 0 {
                    // This is a non-standard ERC-20
                    success := 1 // set success to true
                }
                case 32 {
                    // This is a compliant ERC-20
                    returndatacopy(result, 0, 32)
                    success := mload(result) // Set `success = returndata` of external call
                }
                default {
                    // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }

        require(success, "ERC20");
    }
}

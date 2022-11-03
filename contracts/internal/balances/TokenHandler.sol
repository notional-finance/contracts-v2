// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../math/SafeInt256.sol";
import "../../global/LibStorage.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../global/Deployments.sol";
import "./protocols/AaveHandler.sol";
import "./protocols/CompoundHandler.sol";
import "./protocols/GenericToken.sol";
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

        if (tokenStorage.tokenType == TokenType.cToken || tokenStorage.tokenType == TokenType.aToken) {
            // Set the approval for the underlying so that we can mint cTokens or aTokens
            Token memory underlyingToken = getUnderlyingToken(currencyId);

            // cTokens call transfer from the tokenAddress, but aTokens use the LendingPool
            // to initiate all transfers
            address approvalAddress = tokenStorage.tokenType == TokenType.cToken ?
                tokenStorage.tokenAddress :
                address(LibStorage.getLendingPool().lendingPool);

            // ERC20 tokens should return true on success for an approval, but Tether
            // does not return a value here so we use the NonStandard interface here to
            // check that the approval was successful.
            IEIP20NonStandard(underlyingToken.tokenAddress).approve(
                approvalAddress,
                type(uint256).max
            );
            GenericToken.checkReturnCode();
        }

        store[currencyId][underlying] = tokenStorage;
    }

    /**
     * @notice If a token is mintable then will mint it. At this point we expect to have the underlying
     * balance in the contract already.
     * @param assetToken the asset token to mint
     * @param underlyingAmountExternal the amount of underlying to transfer to the mintable token
     * @return the amount of asset tokens minted, will always be a positive integer
     */
    function mint(Token memory assetToken, uint16 currencyId, uint256 underlyingAmountExternal) internal returns (int256) {
        // aTokens return the principal plus interest value when calling the balanceOf selector. We cannot use this
        // value in internal accounting since it will not allow individual users to accrue aToken interest. Use the
        // scaledBalanceOf function call instead for internal accounting.
        bytes4 balanceOfSelector = assetToken.tokenType == TokenType.aToken ?
            AaveHandler.scaledBalanceOfSelector :
            GenericToken.defaultBalanceOfSelector;
        
        uint256 startingBalance = GenericToken.checkBalanceViaSelector(assetToken.tokenAddress, address(this), balanceOfSelector);

        if (assetToken.tokenType == TokenType.aToken) {
            Token memory underlyingToken = getUnderlyingToken(currencyId);
            AaveHandler.mint(underlyingToken, underlyingAmountExternal);
        } else if (assetToken.tokenType == TokenType.cToken) {
            CompoundHandler.mint(assetToken, underlyingAmountExternal);
        } else if (assetToken.tokenType == TokenType.cETH) {
            // NOTE: current deployed contracts rely on msg.value but this has been updated for
            // strategy vaults.
            CompoundHandler.mintCETH(assetToken, underlyingAmountExternal);
        } else {
            revert(); // dev: non mintable token
        }

        uint256 endingBalance = GenericToken.checkBalanceViaSelector(assetToken.tokenAddress, address(this), balanceOfSelector);
        // This is the starting and ending balance in external precision
        return SafeInt256.toInt(endingBalance.sub(startingBalance));
    }

    /**
     * @notice If a token is redeemable to underlying will redeem it and transfer the underlying balance
     * to the account
     * @param assetToken asset token to redeem
     * @param currencyId the currency id of the token
     * @param account account to transfer the underlying to
     * @param assetAmountExternal the amount to transfer in asset token denomination and external precision
     * @return the actual amount of underlying tokens transferred. this is used as a return value back to the
     * user, is not used for internal accounting purposes
     */
    function redeem(
        Token memory assetToken,
        uint256 currencyId,
        address account,
        uint256 assetAmountExternal
    ) internal returns (int256) {
        uint256 transferAmount;
        if (assetToken.tokenType == TokenType.cETH) {
            transferAmount = CompoundHandler.redeemCETH(assetToken, account, assetAmountExternal);
        } else {
            Token memory underlyingToken = getUnderlyingToken(currencyId);
            if (assetToken.tokenType == TokenType.aToken) {
                transferAmount = AaveHandler.redeem(underlyingToken, account, assetAmountExternal);
            } else if (assetToken.tokenType == TokenType.cToken) {
                transferAmount = CompoundHandler.redeem(assetToken, underlyingToken, account, assetAmountExternal);
            } else {
                revert(); // dev: non redeemable token
            }
        }
        
        // Use the negative value here to signify that assets have left the protocol
        return SafeInt256.toInt(transferAmount).neg();
    }

    /// @notice Handles transfers into and out of the system denominated in the external token decimal
    /// precision.
    function transfer(
        Token memory token,
        address account,
        uint256 currencyId,
        int256 netTransferExternal
    ) internal returns (int256 actualTransferExternal) {
        // This will be true in all cases except for deposits where the token has transfer fees. For
        // aTokens this value is set before convert from scaled balances to principal plus interest
        actualTransferExternal = netTransferExternal;

        if (token.tokenType == TokenType.aToken) {
            Token memory underlyingToken = getUnderlyingToken(currencyId);
            // aTokens need to be converted when we handle the transfer since the external balance format
            // is not the same as the internal balance format that we use
            netTransferExternal = AaveHandler.convertFromScaledBalanceExternal(
                underlyingToken.tokenAddress,
                netTransferExternal
            );
        }

        if (netTransferExternal > 0) {
            // Deposits must account for transfer fees.
            int256 netDeposit = _deposit(token, account, uint256(netTransferExternal));
            // If an aToken has a transfer fee this will still return a balance figure
            // in scaledBalanceOf terms due to the selector
            if (token.hasTransferFee) actualTransferExternal = netDeposit;
        } else if (token.tokenType == TokenType.Ether) {
            // netTransferExternal can only be negative or zero at this point
            GenericToken.transferNativeTokenOut(account, uint256(netTransferExternal.neg()));
        } else {
            GenericToken.safeTransferOut(
                token.tokenAddress,
                account,
                // netTransferExternal is zero or negative here
                uint256(netTransferExternal.neg())
            );
        }
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
        bytes4 balanceOfSelector = token.tokenType == TokenType.aToken ?
            AaveHandler.scaledBalanceOfSelector :
            GenericToken.defaultBalanceOfSelector;

        if (token.hasTransferFee) {
            startingBalance = GenericToken.checkBalanceViaSelector(token.tokenAddress, address(this), balanceOfSelector);
        }

        GenericToken.safeTransferIn(token.tokenAddress, account, amount);

        if (token.hasTransferFee || token.maxCollateralBalance > 0) {
            // If aTokens have a max collateral balance then it will be applied against the scaledBalanceOf. This is probably
            // the correct behavior because if collateral accrues interest over time we should not somehow go over the
            // maxCollateralBalance due to the passage of time.
            endingBalance = GenericToken.checkBalanceViaSelector(token.tokenAddress, address(this), balanceOfSelector);
        }

        if (token.maxCollateralBalance > 0) {
            int256 internalPrecisionBalance = convertToInternal(token, SafeInt256.toInt(endingBalance));
            // Max collateral balance is stored as uint72, no overflow
            require(internalPrecisionBalance <= SafeInt256.toInt(token.maxCollateralBalance)); // dev: over max collateral balance
        }

        // Math is done in uint inside these statements and will revert on negative
        if (token.hasTransferFee) {
            return SafeInt256.toInt(endingBalance.sub(startingBalance));
        } else {
            return SafeInt256.toInt(amount);
        }
    }

    function convertToInternal(Token memory token, int256 amount) internal pure returns (int256) {
        // If token decimals > INTERNAL_TOKEN_PRECISION:
        //  on deposit: resulting dust will accumulate to protocol
        //  on withdraw: protocol may lose dust amount. However, withdraws are only calculated based
        //    on a conversion from internal token precision to external token precision so therefore dust
        //    amounts cannot be specified for withdraws.
        // If token decimals < INTERNAL_TOKEN_PRECISION then this will add zeros to the
        // end of amount and will not result in dust.
        if (token.decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        return amount.mul(Constants.INTERNAL_TOKEN_PRECISION).div(token.decimals);
    }

    function convertToExternal(Token memory token, int256 amount) internal pure returns (int256) {
        if (token.decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        // If token decimals > INTERNAL_TOKEN_PRECISION then this will increase amount
        // by adding a number of zeros to the end and will not result in dust.
        // If token decimals < INTERNAL_TOKEN_PRECISION:
        //  on deposit: Deposits are specified in external token precision and there is no loss of precision when
        //      tokens are converted from external to internal precision
        //  on withdraw: this calculation will round down such that the protocol retains the residual cash balance
        return amount.mul(token.decimals).div(Constants.INTERNAL_TOKEN_PRECISION);
    }

    /// @notice Converts a token to an underlying external amount with adjustments for rounding errors when depositing
    function convertToUnderlyingExternalWithAdjustment(
        Token memory token,
        int256 underlyingInternalAmount
    ) internal pure returns (int256 underlyingExternalAmount) {
        if (token.decimals < Constants.INTERNAL_TOKEN_PRECISION) {
            // If external < 8, we could truncate down and cause an off by one error, for example we need
            // 1.00000011 cash and we deposit only 1.000000, missing 11 units. Therefore, we add a unit at the
            // lower precision (external) to get around off by one errors
            underlyingExternalAmount = convertToExternal(token, underlyingInternalAmount).add(1);
        } else {
            // If external > 8, we may not mint enough asset tokens because in the case of 1e18 precision 
            // an off by 1 error at 1e8 precision is 1e10 units of the underlying token. In this case we
            // add 1 at the internal precision which has the effect of rounding up by 1e10
            underlyingExternalAmount = convertToExternal(token, underlyingInternalAmount.add(1));
        }
    }

    /// @notice Converts and asset token value to it's native external precision. Used to handle aToken internal to
    /// rebasing native external precision.
    function convertAssetInternalToNativeExternal(
        Token memory assetToken,
        uint16 currencyId,
        int256 assetInternalAmount
    ) internal view returns (int256 assetNativeExternal) {
        assetNativeExternal = convertToExternal(assetToken, assetInternalAmount);

        if (assetToken.tokenType == TokenType.aToken) {
            // Special handling for aTokens, we use scaled balance internally
            Token memory underlying = getUnderlyingToken(currencyId);
            assetNativeExternal = AaveHandler.convertFromScaledBalanceExternal(
                underlying.tokenAddress, assetNativeExternal
            );
        }
    }

    /// @notice Convenience method for getting the balance using a token object
    function balanceOf(Token memory token, address account) internal view returns (uint256) {
        if (token.tokenType == TokenType.Ether) {
            return account.balance;
        } else {
            return IERC20(token.tokenAddress).balanceOf(account);
        }
    }

    function transferIncentive(address account, uint256 tokensToTransfer) internal {
        GenericToken.safeTransferOut(Deployments.NOTE_TOKEN_ADDRESS, account, tokensToTransfer);
    }
}

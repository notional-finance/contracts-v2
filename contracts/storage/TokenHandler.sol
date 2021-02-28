// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "./StorageLayoutV1.sol";
import "interfaces/compound/CErc20Interface.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

enum TokenType {
    UnderlyingToken,
    cToken,
    cETH,
    NonMintable
}

struct Token {
    address tokenAddress;
    bool hasTransferFee;
    int decimals;
    TokenType tokenType;
}

struct TokenStorage {
    address tokenAddress;
    bool hasTransferFee;
    TokenType tokenType;
}

/**
 * @notice Handles deposits and withdraws for ERC20 tokens
 */
library TokenHandler {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    int internal constant INTERNAL_TOKEN_PRECISION = 1e9;
    // TODO: hardcode this or move it into an internal storage slot
    address internal constant NOTE_TOKEN_ADDRESS = address(0);

    /**
     * @notice Gets token data for a particular currency id, if underlying is set to true then returns
     * the underlying token. (These may not always exist)
     */
    function getToken(
        uint currencyId,
        bool underlying
    ) internal view returns (Token memory) {
        bytes32 slot = keccak256(abi.encode(currencyId, underlying, "token"));
        bytes32 data;

        assembly { data := sload(slot) }
        address tokenAddress = address(bytes20(data << 96));
        bool tokenHasTransferFee = bytes1(data << 88) != 0x00;
        uint8 tokenDecimalPlaces = uint8(bytes1(data << 80));
        TokenType tokenType = TokenType(uint8(bytes1(data << 72)));

        return Token({
            tokenAddress: tokenAddress,
            hasTransferFee: tokenHasTransferFee,
            decimals: int(10 ** tokenDecimalPlaces),
            tokenType: tokenType
        });
    }

    /**
     * @notice Sets a token for a currency id.
     */
    function setToken(
        uint currencyId,
        bool underlying,
        TokenStorage memory tokenStorage
    ) internal {
        bytes32 slot = keccak256(abi.encode(currencyId, underlying, "token"));
        require(tokenStorage.tokenAddress != address(0), "TH: address is zero");
        uint8 decimalPlaces = ERC20(tokenStorage.tokenAddress).decimals();
        require(decimalPlaces != 0, "TH: decimals is zero");

        // Once a token is set we cannot override it. In the case that we do need to do this then we should
        // explicitly upgrade this method to allow for a token to be changed.
        Token memory token = getToken(currencyId, underlying);
        require(
            token.tokenAddress == tokenStorage.tokenAddress || token.tokenAddress == address(0),
            "TH: token cannot be reset"
        );

        if (tokenStorage.tokenType == TokenType.cToken) {
            // Set the approval for the underlying so that we can mint cTokens
            Token memory underlyingToken = getToken(currencyId, true);
            ERC20(underlyingToken.tokenAddress).approve(tokenStorage.tokenAddress, type(uint).max);
        }

        bytes1 transferFee = tokenStorage.hasTransferFee ? bytes1(0x01) : bytes1(0x00);

        bytes32 data = (
            bytes32(bytes20(tokenStorage.tokenAddress)) >> 96 |
            bytes32(bytes1(transferFee)) >> 88 |
            bytes32(uint(decimalPlaces) << 168) |
            bytes32(uint(tokenStorage.tokenType) << 176)
        );

        assembly { sstore(slot, data) }
    }

    /**
     * @notice Handles token deposits into Notional. If there is a transfer fee then we must
     * calculate the net balance after transfer. Amounts are denominated in the destination token's
     * precision.
     */
    function deposit(
        Token memory token,
        address account,
        uint amount 
    ) private returns (int) {
        if (token.hasTransferFee) {
            // Must deposit from the token and calculate the net transfer
            uint startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));
            SafeERC20.safeTransferFrom(
                IERC20(token.tokenAddress), account, address(this), amount
            );
            uint endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

            return int(endingBalance.sub(startingBalance));
        }

        SafeERC20.safeTransferFrom(
            IERC20(token.tokenAddress), account, address(this), amount
        );

        return int(amount);
    }

    /**
     * @notice This method only works with cTokens, it's unclear how we can make this more generic
     */
    function mint(
        Token memory token,
        uint underlyingAmountExternalPrecision
    ) internal returns (int) {
        require(token.tokenType == TokenType.cToken, "TH: non mintable token");

        // TODO: Need special handling for ETH
        uint startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));
        uint success = CErc20Interface(token.tokenAddress).mint(underlyingAmountExternalPrecision);
        require(success == 0, "TH: ctoken mint failure");
        uint endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

        // This is the starting and ending balance in external precision
        return int(endingBalance.sub(startingBalance));
    }

    function redeem(
        Token memory assetToken,
        Token memory underlyingToken,
        uint assetAmountInternalPrecision
    ) internal returns (int) {
        require(assetToken.tokenType == TokenType.cToken, "TH: non mintable token");
        require(underlyingToken.tokenType == TokenType.UnderlyingToken, "TH: not underlying token");

        uint redeemAmount = assetAmountInternalPrecision
            .mul(uint(assetToken.decimals))
            .div(uint(TokenHandler.INTERNAL_TOKEN_PRECISION));

        // TODO: need special handling for ETH
        uint startingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));
        uint success = CErc20Interface(assetToken.tokenAddress).redeem(redeemAmount);
        require(success == 0, "TH: ctoken redeem failure");
        uint endingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));

        // Underlying token external precision
        return int(endingBalance.sub(startingBalance));
    }

    /**
     * @notice Handles transfers into and out of the system denominated in the external token decimal
     * precision.
     */
    function transfer(
        Token memory token,
        address account,
        int netTransferExternalPrecision
    ) internal returns (int) {
        if (netTransferExternalPrecision > 0) {
            // Deposits must account for transfer fees.
            netTransferExternalPrecision = deposit(token, account, uint(netTransferExternalPrecision));
        } else {
            SafeERC20.safeTransfer(IERC20(token.tokenAddress), account, uint(netTransferExternalPrecision.neg()));
        }

        return netTransferExternalPrecision;
    }

    function convertToInternal(
        Token memory token,
        int amount
    ) internal pure returns (int) {
        return amount.mul(INTERNAL_TOKEN_PRECISION).div(token.decimals);
    }

    function convertToExternal(
        Token memory token,
        int amount
    ) internal pure returns (int) {
        return amount.div(token.decimals).div(INTERNAL_TOKEN_PRECISION);
    }

    function transferIncentive(
        address account,
        uint tokensToTransfer
    ) internal {
        SafeERC20.safeTransfer(IERC20(NOTE_TOKEN_ADDRESS), account, tokensToTransfer);
    }
}
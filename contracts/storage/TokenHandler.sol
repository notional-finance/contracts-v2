// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "./StorageLayoutV1.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

enum TokenType {
    UnderlyingToken,
    cToken,
    cETH,
    Ether,
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

    int internal constant INTERNAL_TOKEN_PRECISION = 1e8;
    // NOTE: this address is hardcoded in the library, must update this on deployment
    address constant NOTE_TOKEN_ADDRESS = 0xe25EDE8b52d4DE741Bd61c30060a003f0F1151A5;

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
        if (tokenStorage.tokenType == TokenType.Ether && currencyId == 1) {
            // Specific storage for Ether token type
            bytes32 etherData = (
                bytes32(bytes20(address(0))) >> 96 |
                bytes32(bytes1(0x00)) >> 88 |
                bytes32(uint(18) << 168) |
                bytes32(uint(TokenType.Ether) << 176)
            );
            assembly { sstore(slot, etherData) }

            return;
        }
        require(tokenStorage.tokenType != TokenType.Ether); // dev: ether can only be set once

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
            safeTransferIn(IERC20(token.tokenAddress), account, amount);
            uint endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

            return int(endingBalance.sub(startingBalance));
        }

        safeTransferIn(IERC20(token.tokenAddress), account, amount);
        return int(amount);
    }

    /**
     * @notice This method only works with cTokens, it's unclear how we can make this more generic
     */
    function mint(
        Token memory token,
        uint underlyingAmountExternalPrecision
    ) internal returns (int) {
        uint startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

        uint success;
        if (token.tokenType == TokenType.cToken) {
            success = CErc20Interface(token.tokenAddress).mint(underlyingAmountExternalPrecision);
        } else if (token.tokenType == TokenType.cETH) {
            // Reverts on error
            CEtherInterface(token.tokenAddress).mint{value: msg.value}();
        } else {
            revert("Non mintable");
        }

        require(success == 0, "TH: mint failure");
        uint endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

        // This is the starting and ending balance in external precision
        return int(endingBalance.sub(startingBalance));
    }

    function redeem(
        Token memory assetToken,
        Token memory underlyingToken,
        uint assetAmountExternalPrecision
    ) internal returns (int) {
        uint startingBalance;
        if (assetToken.tokenType == TokenType.cETH) {
            startingBalance = address(this).balance;
        } else if (assetToken.tokenType == TokenType.cToken) {
            startingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));
        } else {
            revert("Non redeemable token");
        }

        uint success = CErc20Interface(assetToken.tokenAddress).redeem(assetAmountExternalPrecision);
        require(success == 0, "Redeem failure");

        uint endingBalance;
        if (assetToken.tokenType == TokenType.cETH) {
            endingBalance = address(this).balance;
        } else {
            endingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));
        }

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
        } else if (token.tokenType == TokenType.Ether) {
            require(netTransferExternalPrecision < 0); // dev: cannot transfer ether
            address payable accountPayable = payable(account);
            accountPayable.transfer(uint(netTransferExternalPrecision.neg()));
        } else {
            safeTransferOut(IERC20(token.tokenAddress), account, uint(netTransferExternalPrecision.neg()));
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
        return amount.mul(token.decimals).div(INTERNAL_TOKEN_PRECISION);
    }

    function transferIncentive(
        address account,
        uint tokensToTransfer
    ) internal {
        safeTransferOut(IERC20(NOTE_TOKEN_ADDRESS), account, tokensToTransfer);
    }

    function safeTransferOut(IERC20 token, address account, uint amount) private {
        token.transfer(account, amount);
        checkReturnCode();
    }

    function safeTransferIn(IERC20 token, address account, uint amount) private {
        token.transferFrom(account, address(this), amount);
        checkReturnCode();
    }

    function checkReturnCode() private pure {
        bool success;
        assembly {
            switch returndatasize()
                case 0 {                       // This is a non-standard ERC-20
                    success := not(0)          // set success to true
                }
                case 32 {                      // This is a compliant ERC-20
                    returndatacopy(0, 0, 32)
                    success := mload(0)        // Set `success = returndata` of external call
                }
                default {                      // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }

        require(success, "TH: Transfer Failed");
    }
}
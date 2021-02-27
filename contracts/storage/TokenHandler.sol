// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "./StorageLayoutV1.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

struct Token {
    address tokenAddress;
    bool hasTransferFee;
    int decimals;
}

struct TokenStorage {
    address tokenAddress;
    bool hasTransferFee;
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

        return Token({
            tokenAddress: tokenAddress,
            hasTransferFee: tokenHasTransferFee,
            decimals: int(10 ** tokenDecimalPlaces)
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
        bytes1 transferFee = tokenStorage.hasTransferFee ? bytes1(0x01) : bytes1(0x00);

        bytes32 data = (
            bytes32(bytes20(tokenStorage.tokenAddress)) >> 96 |
            bytes32(bytes1(transferFee)) >> 88 |
            bytes32(uint(decimalPlaces) >> 80)
        );

        assembly { sstore(slot, data) }
    }

    /**
     * @notice Handles token deposits into Notional. If there is a transfer fee then we must
     * calculate the net balance after transfer.
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
     * @notice Handles transfers into and out of the system. Crucially we must
     * translate the amount from internal balance precision to the external balance
     * precision.
     */
    function transfer(
        Token memory token,
        address account,
        int netTransfer
    ) internal returns (int) {
        // Convert internal balances in 1e9 to token decimals:
        // balance * tokenDecimals / 1e9
        int transferBalance = netTransfer 
            .mul(token.decimals)
            .div(INTERNAL_TOKEN_PRECISION);

        if (transferBalance > 0) {
            // Deposits must account for transfer fees.
            transferBalance = deposit(token, account, uint(transferBalance));
        } else {
            SafeERC20.safeTransfer(IERC20(token.tokenAddress), account, uint(transferBalance.neg()));
        }

        // Convert transfer balance back into internal precision
        return transferBalance.mul(INTERNAL_TOKEN_PRECISION).div(token.decimals);
    }

    function transferIncentive(
        address account,
        uint tokensToTransfer
    ) internal {
        SafeERC20.safeTransfer(IERC20(NOTE_TOKEN_ADDRESS), account, tokensToTransfer);
    }
}
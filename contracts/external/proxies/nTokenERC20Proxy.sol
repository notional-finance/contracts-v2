// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {SafeInt256} from "../../math/SafeInt256.sol";
import {Constants} from "../../global/Constants.sol";
import {NotionalProxy, BaseERC4626Proxy} from "./BaseERC4626Proxy.sol";

/// @notice ERC20 proxy for nToken contracts that forwards calls to the Router, all nToken
/// balances and allowances are stored in at single address for gas efficiency. This contract
/// is used simply for ERC20 compliance.
contract nTokenERC20Proxy is BaseERC4626Proxy {
    using SafeInt256 for int256;

    constructor(NotionalProxy notional_) BaseERC4626Proxy(notional_) {}

    function _getPrefixes() internal pure override returns (string memory namePrefix, string memory symbolPrefix) {
        namePrefix = "nToken";
        symbolPrefix = "n";
    }

    function _totalSupply() internal view override returns (uint256 supply) {
        // Total supply is looked up via the token address
        return NOTIONAL.nTokenTotalSupply(address(this));
    }

    function _balanceOf(address account) internal view override returns (uint256 balance) {
        return NOTIONAL.nTokenBalanceOf(currencyId, account);
    }

    function _allowance(address account, address spender) internal view override returns (uint256) {
        return NOTIONAL.nTokenTransferAllowance(currencyId, account, spender);
    }

    function _approve(address spender, uint256 amount) internal override returns (bool) {
        return NOTIONAL.nTokenTransferApprove(currencyId, msg.sender, spender, amount);
    }

    function _transfer(address to, uint256 amount) internal override returns (bool) {
        return NOTIONAL.nTokenTransfer(currencyId, msg.sender, to, amount);
    }

    function _transferFrom(address from, address to, uint256 amount) internal override returns (bool) {
        return NOTIONAL.nTokenTransferFrom(currencyId, msg.sender, from, to, amount);
    }

    /// @notice Returns the present value of the nToken's assets denominated in asset tokens
    function getPresentValueAssetDenominated() external view returns (int256) {
        return NOTIONAL.nTokenPresentValueAssetDenominated(currencyId);
    }

    /// @notice Returns the present value of the nToken's assets denominated in underlying
    function getPresentValueUnderlyingDenominated() external view returns (int256) {
        return NOTIONAL.nTokenPresentValueUnderlyingDenominated(currencyId);
    }

    function _getTotalValueExternal() internal view override returns (uint256 totalValueExternal) {
        int256 underlyingInternal = NOTIONAL.nTokenPresentValueUnderlyingDenominated(currencyId);
        totalValueExternal = underlyingInternal
            // No overflow, native decimals is restricted to < 36 in initialize
            .mul(int256(10**nativeDecimals))
            .div(Constants.INTERNAL_TOKEN_PRECISION).toUint();
    }

    function _mint(uint256 assets, uint256 msgValue, address receiver) internal override returns (uint256 tokensMinted) {
        revert("Not Implemented");
    }

    function _redeem(uint256 shares, address receiver, address owner) internal override returns (uint256 assets) {
        revert("Not Implemented");
    }
}

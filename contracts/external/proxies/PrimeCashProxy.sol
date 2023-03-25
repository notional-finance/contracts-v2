// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {Constants} from "../../global/Constants.sol";
import {PrimeCashFactors, PrimeRate} from "../../global/Types.sol";

import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {NotionalProxy, BaseERC4626Proxy} from "./BaseERC4626Proxy.sol";

contract PrimeCashProxy is BaseERC4626Proxy {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;
    using PrimeRateLib for PrimeRate;

    constructor(NotionalProxy notional_) BaseERC4626Proxy(notional_) {}

    function _getPrefixes() internal pure override returns (string memory namePrefix, string memory symbolPrefix) {
        namePrefix = "pCash";
        symbolPrefix = "p";
    }

    function _totalSupply() internal view override returns (uint256 supply) {
        // Total supply is looked up via the token address
        (
            /* */,
            PrimeCashFactors memory factors,
            /* */,
            /* */
        ) = NOTIONAL.getPrimeFactors(currencyId, block.timestamp);

        return factors.totalPrimeSupply;
    }

    function _balanceOf(address account) internal view override returns (uint256 balance) {
        (int256 cashBalance, /* */, /* */) = NOTIONAL.getAccountBalance(currencyId, account);

        // If cash balance is negative, return a zero to maintain compatibility with uint
        return cashBalance < 0 ? 0 : uint256(cashBalance);
    }

    function _allowance(address account, address spender) internal view override returns (uint256) {
        return NOTIONAL.pCashTransferAllowance(currencyId, account, spender);
    }

    function _approve(address spender, uint256 amount) internal override returns (bool) {
        return NOTIONAL.pCashTransferApprove(currencyId, msg.sender, spender, amount);
    }

    function _transfer(address to, uint256 amount) internal override returns (bool) {
        return NOTIONAL.pCashTransfer(currencyId, msg.sender, to, amount);
    }

    function _transferFrom(address from, address to, uint256 amount) internal override returns (bool) {
        return NOTIONAL.pCashTransferFrom(currencyId, msg.sender, from, to, amount);
    }

    function _getTotalValueExternal() internal view override returns (uint256 totalValueExternal) {
        (
            PrimeRate memory pr,
            PrimeCashFactors memory factors,
            /* */,
            /* */
        ) = NOTIONAL.getPrimeFactors(currencyId, block.timestamp);

        totalValueExternal = pr.convertToUnderlying(factors.totalPrimeSupply.toInt())
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
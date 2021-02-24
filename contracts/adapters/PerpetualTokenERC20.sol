// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "interfaces/notional/PerpetualTokenActionInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice The PerpetualTokenERC20 is a proxy for perpetual token methods on the router. It holds no state
 * and simply forwards calls to the Router.
 */
contract PerpetualTokenERC20 is IERC20 {
    string public name;
    string public symbol;
    // This is the hardcoded internal token precision in TokenHandler.INTERNAL_TOKEN_PRECISION,
    // solidity does not allow assignment from another constant :(
    uint8 public constant decimals = 9;
    PerpetualTokenActionInterface public immutable proxy;
    uint16 public immutable currencyId;

    constructor (PerpetualTokenActionInterface proxy_, uint16 currencyId_) {
        proxy = proxy_;
        currencyId = currencyId_;
    }

    function totalSupply() override external view returns (uint) {
        // Total supply is looked up via the token address
        return proxy.perpetualTokenTotalSupply(address(this));
    }

    function balanceOf(address account) override external view returns (uint) {
        return proxy.perpetualTokenBalanceOf(currencyId, account);
    }

    function allowance(address owner, address spender) override external view returns (uint) {
        return proxy.perpetualTokenTransferAllowance(currencyId, owner, spender);
    }

    function approve(address spender, uint amount) override external returns (bool) {
        return proxy.perpetualTokenTransferApprove(currencyId, msg.sender, spender, amount);
    }

    function transfer(address recipient, uint amount) override external returns (bool) {
        return proxy.perpetualTokenTransfer(currencyId, msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint amount) override external returns (bool) {
        return proxy.perpetualTokenTransferFrom(currencyId, sender, recipient, amount);
    }

    // non-ERC20 methods
    function getPresentValueAssetDenominated() external view returns (int) {
        return proxy.perpetualTokenPresentValueAssetDenominated(currencyId);
    }

    function getPresentValueUnderlyingDenominated() external view returns (int) {
        return proxy.perpetualTokenPresentValueUnderlyingDenominated(currencyId);
    }
}
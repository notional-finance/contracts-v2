// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "interfaces/notional/NotionalProxy.sol";
import "interfaces/compound/CTokenInterface.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";

// This should be behind a proxy...
contract NotionalV2ifCashLiquidator is Initializable {
    address public owner;
    NotionalProxy public immutable NotionalV2;
    uint16 public immutable ifCashCurrencyId;
    address public immutable NOTE;
    address public immutable underlyingToken;
    address public immutable assetToken;

    /// @dev Throws if called by any account other than the owner.
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /// @dev Transfers ownership of the contract to a new account (`newOwner`).
    /// Can only be called by the current owner.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        owner = newOwner;
    }

    constructor(
        NotionalProxy notionalV2_,
        uint16 ifCashCurrencyId_,
        address note_,
        address assetToken_,
        address underlyingToken_
    ) {
        NotionalV2 = notionalV2_;
        NOTE = note_;
        ifCashCurrencyId = ifCashCurrencyId_;
        assetToken = assetToken_;
        underlyingToken = underlyingToken_;
    }

    function initialize() external initializer {
        owner = msg.sender;
        // At this point the contract can only hold assets of this currency id
        NotionalV2.enableBitmapCurrency(ifCashCurrencyId);
        // Allow ERC1155 trades to be authorized by owner for selling ifCash OTC
        NotionalV2.setApprovalForAll(msg.sender, true);

        IERC20(assetToken).approve(address(NotionalV2), type(uint256).max);
        IERC20(underlyingToken).approve(address(NotionalV2), type(uint256).max);
    }

    function approveToken(address token, address spender) external onlyOwner {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function executeArbitrary(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOwner {
        // prettier-ignore
        (
            bool success,
            /* bytes retval */
        ) = target.call{value: value}(data);
        require(success, "Call failed");
    }

    function batchBalanceTradeAction(BalanceActionWithTrades[] calldata actions)
        external
        onlyOwner
    {
        NotionalV2.batchBalanceAndTradeAction(address(this), actions);
    }

    function batchBalanceAction(BalanceAction[] calldata actions) external onlyOwner {
        NotionalV2.batchBalanceAction(address(this), actions);
    }

    function nTokenRedeem(uint96 tokensToRedeem, bool sellTokenAssets)
        external
        onlyOwner
        returns (int256)
    {
        return
            NotionalV2.nTokenRedeem(
                address(this),
                ifCashCurrencyId,
                tokensToRedeem,
                sellTokenAssets
            );
    }

    function claimNOTE() external onlyOwner returns (uint256) {
        uint256 notesClaimed = NotionalV2.nTokenClaimIncentives();
        IERC20(NOTE).transfer(owner, notesClaimed);
        return notesClaimed;
    }

    function liquidateLocalfCash(
        BalanceActionWithTrades[] calldata actions,
        address liquidateAccount,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external onlyOwner {
        if (actions.length > 0) {
            NotionalV2.batchBalanceAndTradeAction(address(this), actions);
        }

        NotionalV2.liquidatefCashLocal(
            liquidateAccount,
            ifCashCurrencyId,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );
    }

    function liquidateCrossCurrencyfCash(
        BalanceActionWithTrades[] calldata actions,
        address liquidateAccount,
        uint256 localCurrencyId,
        address localCurrencyAssetToken,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        bytes calldata dexTrade
    ) external onlyOwner {
        if (actions.length > 0) {
            // Need to borrow some amount of ifCashCurrency and trade it for local currency in the next step
            NotionalV2.batchBalanceAndTradeAction(address(this), actions);
        }

        if (dexTrade.length > 0) {
            // Arbitrary call to any DEX to trade ifCashCurrency to local currency
            // Approval should only be required for underlyingToken...the DEX will push local currency to this contract
            (address tradeContract, uint256 tradeETHValue, bytes memory tradeCallData) = abi.decode(dexTrade, (address, uint256, bytes));
            checkAllowanceOrSet(underlyingToken, tradeContract);
            (bool success, /* return value */) = tradeContract.call{value: tradeETHValue}(tradeCallData);
            require(success);
        }

        // Mint the traded local currency balance to cTokens
        if (localCurrencyId == 1) {
            uint256 underlyingToMint = address(this).balance;
            CEtherInterface(localCurrencyAssetToken).mint{value: underlyingToMint}();
        } else if (underlyingToken != address(0)) {
            address localUnderlying = CTokenInterface(localCurrencyAssetToken).underlying();
            uint256 underlyingToMint = IERC20(localUnderlying).balanceOf(address(this));

            // Set approval for minting if not set
            checkAllowanceOrSet(localUnderlying, localCurrencyAssetToken);
            CErc20Interface(localCurrencyAssetToken).mint(underlyingToMint);
        }

        // Set approval for Notional V2 transfers if not set
        checkAllowanceOrSet(localCurrencyAssetToken, address(NotionalV2));
        NotionalV2.liquidatefCashCrossCurrency(
            liquidateAccount,
            localCurrencyId,
            ifCashCurrencyId, // collateral currency fCash
            fCashMaturities,
            maxfCashLiquidateAmounts
        );
    }

    function checkAllowanceOrSet(address erc20, address spender) internal {
        if (IERC20(erc20).allowance(address(this), spender) < 2 ** 128) {
            IERC20(erc20).approve(spender, type(uint256).max);
        }
    }

    receive() external payable {}
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "interfaces/notional/NotionalProxy.sol";
import "interfaces/compound/CTokenInterface.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";

contract NotionalV2ifCashLiquidator is Initializable {
    address public owner;
    NotionalProxy public immutable NotionalV2;
    uint16 public immutable IFCASH_CURRENCY_ID;
    address public immutable NOTE;
    address public immutable UNDERLYING_TOKEN;
    address public immutable ASSET_TOKEN;
    address public immutable cETH;

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
        uint16 IFCASH_CURRENCY_ID_,
        address note_,
        address ASSET_TOKEN_,
        address UNDERLYING_TOKEN_,
        address cETH_
    ) {
        NotionalV2 = notionalV2_;
        NOTE = note_;
        IFCASH_CURRENCY_ID = IFCASH_CURRENCY_ID_;
        ASSET_TOKEN = ASSET_TOKEN_;
        UNDERLYING_TOKEN = UNDERLYING_TOKEN_;
        cETH = cETH_;
    }

    function initialize() external initializer {
        owner = msg.sender;
        // At this point the contract can only hold assets of this currency id
        NotionalV2.enableBitmapCurrency(IFCASH_CURRENCY_ID);
        // Allow ERC1155 trades to be authorized by owner for selling ifCash OTC
        NotionalV2.setApprovalForAll(msg.sender, true);

        IERC20(ASSET_TOKEN).approve(address(NotionalV2), type(uint256).max);
        IERC20(UNDERLYING_TOKEN).approve(address(NotionalV2), type(uint256).max);
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
                IFCASH_CURRENCY_ID,
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
            IFCASH_CURRENCY_ID,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );
    }

    function liquidateCrossCurrencyfCash(
        BalanceActionWithTrades[] calldata actions,
        address liquidateAccount,
        uint16 localCurrencyId,
        address localCurrencyAssetToken,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        bytes calldata dexTrade,
        bool localHasTransferFee
    ) external onlyOwner {
        if (actions.length > 0) {
            // Need to borrow some amount of ifCashCurrency and trade it for local currency in the next step
            NotionalV2.batchBalanceAndTradeAction(address(this), actions);
        }

        if (dexTrade.length > 0) {
            // Arbitrary call to any DEX to trade ifCashCurrency to local currency
            // Approval should only be required for UNDERLYING_TOKEN...the DEX will push local currency to this contract
            (address tradeContract, uint256 tradeETHValue, bytes memory tradeCallData) = abi.decode(
                dexTrade,
                (address, uint256, bytes)
            );
            checkAllowanceOrSet(UNDERLYING_TOKEN, tradeContract);
            // prettier-ignore
            (
                bool success,
                /* return value */
            ) = tradeContract.call{value: tradeETHValue}(tradeCallData);
            require(success);
        }

        // Mint the traded local currency balance to cTokens
        if (localCurrencyId == 1) {
            uint256 underlyingToMint = address(this).balance;
            CEtherInterface(cETH).mint{value: underlyingToMint}();
        } else {
            // prettier-ignore
            (
                Token memory localAssetToken,
                Token memory localUnderlyingToken
            ) = NotionalV2.getCurrency(localCurrencyId);

            // Set approval for minting if not set
            if (localAssetToken.tokenType == TokenType.cToken) {
                uint256 underlyingToMint = IERC20(localUnderlyingToken.tokenAddress).balanceOf(
                    address(this)
                );

                // It's possible that underlying to mint is zero if we've traded directly
                // for cTokens in the DEX
                if (underlyingToMint > 0) {
                    checkAllowanceOrSet(
                        localUnderlyingToken.tokenAddress,
                        localAssetToken.tokenAddress
                    );
                    CErc20Interface(localAssetToken.tokenAddress).mint(underlyingToMint);
                }
            }

            // Set approval for Notional V2 transfers if not set
            checkAllowanceOrSet(localAssetToken.tokenAddress, address(NotionalV2));

            if (localAssetToken.hasTransferFee) {
                uint256 depositAmount = IERC20(localAssetToken.tokenAddress).balanceOf(
                    address(this)
                );
                NotionalV2.depositAssetToken(address(this), localCurrencyId, depositAmount);
            }
        }

        NotionalV2.liquidatefCashCrossCurrency(
            liquidateAccount,
            localCurrencyId,
            IFCASH_CURRENCY_ID, // collateral currency fCash
            fCashMaturities,
            maxfCashLiquidateAmounts
        );
    }

    function checkAllowanceOrSet(address erc20, address spender) internal {
        if (IERC20(erc20).allowance(address(this), spender) < 2**128) {
            IERC20(erc20).approve(spender, type(uint256).max);
        }
    }

    receive() external payable {}
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "./NotionalV2BaseLiquidator.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "interfaces/uniswap/v3/ISwapRouter.sol";

contract NotionalV2ManualLiquidator is NotionalV2BaseLiquidator, AccessControl, Initializable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant USER_ROLE = keccak256("USER_ROLE");
    address public immutable NOTE;
    address public immutable EXCHANGE;

    constructor(
        NotionalProxy notionalV2_,
        address weth_,
        address cETH_,
        address owner_,
        address exchange_,
        address note_
    ) NotionalV2BaseLiquidator(notionalV2_, weth_, cETH_, owner_) initializer {
        EXCHANGE = exchange_;
        NOTE = note_;
    }

    function initialize(
        uint16 localCurrencyId_,
        address localAssetAddress_,
        address localUnderlyingAddress_,
        bool hasTransferFee_
    ) external initializer {
        localCurrencyId = localCurrencyId_;
        localAssetAddress = localAssetAddress_;
        localUnderlyingAddress = localUnderlyingAddress_;
        hasTransferFee = hasTransferFee_;
        owner = msg.sender;

        _setRoleAdmin(USER_ROLE, ADMIN_ROLE);
        _setupRole(ADMIN_ROLE, msg.sender);

        // At this point the contract can only hold assets of this currency id
        NotionalV2.enableBitmapCurrency(localCurrencyId);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        owner = newOwner;
        grantRole(ADMIN_ROLE, newOwner);
        revokeRole(ADMIN_ROLE, msg.sender);
    }

    function grantRole(bytes32 role, address account) public virtual override {
        AccessControl.grantRole(role, account);
        // Allow ERC1155 trades to be authorized by owner for selling ifCash OTC
        NotionalV2.setApprovalForAll(account, true);
    }

    function revokeRole(bytes32 role, address account) public virtual override {
        AccessControl.revokeRole(role, account);
        NotionalV2.setApprovalForAll(account, false);
    }

    modifier ownerOrUser() {
        require(hasRole(USER_ROLE, msg.sender) || msg.sender == owner, "User or owner required");
        _;
    }

    function batchBalanceTradeAction(BalanceActionWithTrades[] calldata actions) external ownerOrUser {
        NotionalV2.batchBalanceAndTradeAction(address(this), actions);
    }

    function batchBalanceAction(BalanceAction[] calldata actions) external ownerOrUser {
        NotionalV2.batchBalanceAction(address(this), actions);
    }

    function nTokenRedeem(uint96 tokensToRedeem, bool sellTokenAssets)
        external
        ownerOrUser
        returns (int256)
    {
        return
            NotionalV2.nTokenRedeem(
                address(this),
                localCurrencyId,
                tokensToRedeem,
                sellTokenAssets
            );
    }

    function claimNOTE() external onlyOwner returns (uint256) {
        uint256 notesClaimed = NotionalV2.nTokenClaimIncentives();
        IERC20(NOTE).transfer(owner, notesClaimed);
        return notesClaimed;
    }

    function localLiquidate(address account, uint96 maxNTokenLiquidation) external ownerOrUser {
        LiquidationAction action = LiquidationAction.LocalCurrency_NoTransferFee_NoWithdraw;

        if (hasTransferFee) {
            action = LiquidationAction.LocalCurrency_WithTransferFee_NoWithdraw;
        }

        bytes memory encoded = abi.encode(action, account, localCurrencyId, maxNTokenLiquidation);

        address[] memory assets = new address[](1);
        assets[0] = localUnderlyingAddress;

        _liquidateLocal(action, encoded, assets);
    }

    function collateralLiquidate(
        address account,
        uint16 collateralCurrencyId,
        address collateralCurrencyAddress,
        address collateralUnderlyingAddress,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    ) external ownerOrUser {
        LiquidationAction action = LiquidationAction.CollateralCurrency_NoTransferFee_NoWithdraw;

        if (hasTransferFee) {
            action = LiquidationAction.CollateralCurrency_WithTransferFee_NoWithdraw;
        }

        bytes memory encoded = abi.encode(
            action,
            account,
            localCurrencyId,
            localUnderlyingAddress,
            collateralCurrencyId,
            collateralCurrencyAddress,
            collateralUnderlyingAddress,
            maxCollateralLiquidation,
            maxNTokenLiquidation
        );

        address[] memory assets = new address[](1);
        assets[0] = localUnderlyingAddress;

        _liquidateCollateral(action, encoded, assets);
    }

    function fcashLocalLiquidate(
        BalanceActionWithTrades[] calldata actions,
        address account,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external ownerOrUser {
        if (actions.length > 0) {
            NotionalV2.batchBalanceAndTradeAction(address(this), actions);
        }

        LiquidationAction action = LiquidationAction.LocalfCash_NoTransferFee_NoWithdraw;

        if (hasTransferFee) {
            action = LiquidationAction.LocalfCash_WithTransferFee_NoWithdraw;
        }

        bytes memory encoded = abi.encode(
            action,
            account,
            localCurrencyId,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );

        address[] memory assets = new address[](1);
        assets[0] = localUnderlyingAddress;

        _liquidateLocalfCash(action, encoded, assets);
    }

    function fcashCrossCurrencyLiquidate(
        BalanceActionWithTrades[] calldata actions,
        address account,
        uint16 fCashCurrency,
        address fCashAddress,
        address fCashUnderlyingAddress,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external ownerOrUser {
        if (actions.length > 0) {
            // Need to borrow some amount of ifCashCurrency and trade it for local currency in the next step
            NotionalV2.batchBalanceAndTradeAction(address(this), actions);
        }

        LiquidationAction action = LiquidationAction.CrossCurrencyfCash_NoTransferFee_NoWithdraw;

        if (hasTransferFee) {
            action = LiquidationAction.CrossCurrencyfCash_WithTransferFee_NoWithdraw;
        }

        address[] memory assets = new address[](1);
        assets[0] = localUnderlyingAddress;

        bytes memory encoded = abi.encode(
            action,
            account,
            localCurrencyId,
            localUnderlyingAddress,
            fCashCurrency,
            fCashAddress,
            fCashUnderlyingAddress,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );

        _liquidateCrossCurrencyfCash(action, encoded, assets);
    }


    function tradeAndWrap(bytes calldata path, uint256 deadline, uint256 amountIn, uint256 amountOutMin) external ownerOrUser {
        bytes memory encoded = abi.encode(
            path,
            deadline
        );

        executeDexTrade(amountIn, amountOutMin, encoded);

        address[] memory assets = new address[](1);
        assets[0] = localUnderlyingAddress;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = IERC20(localUnderlyingAddress).balanceOf(address(this));

        _mintCTokens(assets, amounts);
    }

    function executeDexTrade(
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal override ownerOrUser returns (uint256) {
        // prettier-ignore
        (
            bytes memory path,
            uint256 deadline
        ) = abi.decode(params, (bytes, uint256));

        ISwapRouter.ExactInputParams memory swapParams = ISwapRouter.ExactInputParams(
            path,
            address(this),
            deadline,
            amountIn,
            amountOutMin
        );

       return ISwapRouter(EXCHANGE).exactInput(swapParams);
    }

    function wrapToWETH() external ownerOrUser {
        _wrapToWETH();
    }

    function withdraw(address token, uint256 amount) external ownerOrUser {
        IERC20(token).transfer(owner, amount);
    }
}

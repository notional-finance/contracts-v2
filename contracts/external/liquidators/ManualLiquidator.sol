// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/Initializable.sol";
import {PortfolioAsset, BalanceAction, BalanceActionWithTrades} from "../../global/Types.sol";
import {FlashLiquidatorBase, TradeData} from "./FlashLiquidatorBase.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {IWstETH} from "../../../interfaces/IWstETH.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

contract ManualLiquidator is FlashLiquidatorBase, AccessControl, Initializable {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant USER_ROLE = keccak256("USER_ROLE");
    address public immutable NOTE;
    address internal immutable DEPLOYER;

    // @dev setting owner to address(0) because it is initialized in initialize()
    constructor(
        NotionalProxy notional_,
        address lendingPool_,
        address weth_,
        IWstETH wstETH_,
        address note_,
        address tradingModule_,
        bool unwrapStETH_
    )
        FlashLiquidatorBase(
            notional_,
            lendingPool_,
            weth_,
            wstETH_,
            address(0),
            tradingModule_,
            unwrapStETH_
        )
        initializer
    {
        NOTE = note_;
        DEPLOYER = msg.sender;
    }

    function initialize(uint16 ifCashCurrencyId_) external initializer {
        require(msg.sender == DEPLOYER);
        ifCashCurrencyId = ifCashCurrencyId_;
        owner = msg.sender;

        // Initialize the owner as the USER_ROLE admin
        _setRoleAdmin(USER_ROLE, ADMIN_ROLE);
        _setupRole(ADMIN_ROLE, msg.sender);

        // At this point the contract can only hold assets of this currency id
        NOTIONAL.enableBitmapCurrency(ifCashCurrencyId);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "invalid new owner");

        // Make new user the USER_ROLE admin
        grantRole(ADMIN_ROLE, newOwner);
        revokeRole(ADMIN_ROLE, msg.sender);

        // Update owner here because grantRole and revokeRole need the currency owner
        owner = newOwner;
    }

    function grantRole(bytes32 role, address account) public virtual override onlyOwner {
        // Hardcoding role to USER_ROLE for safety
        AccessControl.grantRole(USER_ROLE, account);
        // Allow ERC1155 trades to be authorized by owner for selling ifCash OTC
        NOTIONAL.setApprovalForAll(account, true);
    }

    function revokeRole(bytes32 role, address account) public virtual override onlyOwner {
        // Hardcoding role to USER_ROLE for safety
        AccessControl.revokeRole(USER_ROLE, account);
        // Revoke ERC1155 access
        NOTIONAL.setApprovalForAll(account, false);
    }

    modifier ownerOrUser() {
        require(hasRole(USER_ROLE, msg.sender) || msg.sender == owner, "User or owner required");
        _;
    }

    function batchBalanceTradeAction(BalanceActionWithTrades[] calldata actions)
        external
        ownerOrUser
    {
        NOTIONAL.batchBalanceAndTradeAction(address(this), actions);
    }

    function batchBalanceAction(BalanceAction[] calldata actions) external ownerOrUser {
        NOTIONAL.batchBalanceAction(address(this), actions);
    }

    function nTokenRedeem(
        uint96 tokensToRedeem,
        bool sellTokenAssets,
        bool acceptResidualAssets
    ) external ownerOrUser returns (int256) {
        return
            NOTIONAL.nTokenRedeem(
                address(this),
                ifCashCurrencyId,
                tokensToRedeem,
                sellTokenAssets,
                acceptResidualAssets
            );
    }

    function withdrawFromNotional(
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external ownerOrUser returns (uint256) {
        return NOTIONAL.withdraw(currencyId, amountInternalPrecision, redeemToUnderlying);
    }

    function claimNOTE() external ownerOrUser returns (uint256) {
        uint256 notesClaimed = NOTIONAL.nTokenClaimIncentives();
        IERC20(NOTE).transfer(owner, notesClaimed);
        return notesClaimed;
    }

    function liquidateLocalCurrency(
        address liquidateAccount,
        uint16 localCurrencyId,
        uint96 maxNTokenLiquidation
    ) external payable ownerOrUser returns (int256, int256) {
        return
            NOTIONAL.liquidateLocalCurrency{value: msg.value}(
                liquidateAccount,
                localCurrencyId,
                maxNTokenLiquidation
            );
    }

    function liquidateCollateralCurrency(
        address liquidateAccount,
        uint16 localCurrencyId,
        uint16 collateralCurrencyId,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        bool withdrawCollateral,
        bool redeemNToken
    )
        external payable
        ownerOrUser
        returns (
            int256,
            int256,
            int256
        )
    {
        return
            NOTIONAL.liquidateCollateralCurrency{value: msg.value}(
                liquidateAccount,
                localCurrencyId,
                collateralCurrencyId,
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                withdrawCollateral,
                redeemNToken
            );
    }

    function fcashLocalLiquidate(
        address liquidateAccount,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external payable ownerOrUser {
        NOTIONAL.liquidatefCashLocal{value: msg.value}(
            liquidateAccount,
            ifCashCurrencyId,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );
    }

    function fcashCrossCurrencyLiquidate(
        address liquidateAccount,
        uint16 localCurrencyId,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external payable ownerOrUser {
        NOTIONAL.liquidatefCashCrossCurrency{value: msg.value}(
            liquidateAccount,
            localCurrencyId,
            ifCashCurrencyId,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );
    }

    function executeDexTrade(TradeData calldata tradeData) external ownerOrUser {
        _executeDexTrade(tradeData);
    }

    function wrapToWETH() external ownerOrUser {
        _wrapToWETH();
    }

    function withdrawToOwner(address token, uint256 amount) external ownerOrUser {
        IERC20(token).transfer(owner, amount);
    }

    function _redeemAndWithdraw(
        uint16 nTokenCurrencyId,
        uint96 nTokenBalance,
        bool redeemToUnderlying
    ) internal override {
        NOTIONAL.nTokenRedeem(address(this), nTokenCurrencyId, nTokenBalance, true, true);

        // prettier-ignore
        (
            int256 cashBalance,
            /* int256 nTokenBalance */,
            /* uint256 lastClaimTime */
        ) = NOTIONAL.getAccountBalance(nTokenCurrencyId, address(this));

        PortfolioAsset[] memory assets = NOTIONAL.getAccountPortfolio(address(this));

        // Make sure we leave enough cash to cover the negative fCash residuals
        for (uint256 i; i < assets.length; i++) {
            if (assets[i].currencyId == nTokenCurrencyId && assets[i].notional < 0) {
                cashBalance = cashBalance.add(
                    NOTIONAL.convertUnderlyingToPrimeCash(assets[i].currencyId, assets[i].notional)
                );
            }
        }

        require(cashBalance >= 0 && cashBalance <= type(uint88).max, "Invalid cash balance");

        if (cashBalance > 0) {
            NOTIONAL.withdraw(nTokenCurrencyId, uint88(uint256(cashBalance)), redeemToUnderlying);
        }
    }

    function _sellfCashAssets(
        uint16 fCashCurrency,
        uint256[] memory fCashMaturities,
        int256[] memory fCashNotional,
        uint256 depositActionAmount,
        bool redeemToUnderlying
    ) internal override {
        /// NOTE: empty implementation here to reduce contract size because manual liquidator does not need this
    }
}

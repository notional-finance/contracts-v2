// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "./NotionalV2FlashLiquidatorBase.sol";
import "../../../interfaces/compound/CErc20Interface.sol";
import "../../../interfaces/compound/CEtherInterface.sol";
import "../../../interfaces/uniswap/v3/ISwapRouter.sol";
import "../../../interfaces/IWstETH.sol";
import "../../internal/markets/AssetRate.sol";

contract NotionalV2ManualLiquidator is NotionalV2FlashLiquidatorBase, AccessControl, Initializable {
    using SafeInt256 for int256;
    using SafeMath for uint256;
    using AssetRate for AssetRateParameters;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant USER_ROLE = keccak256("USER_ROLE");
    address public immutable NOTE;
    address internal immutable DEPLOYER;

    // @dev setting owner to address(0) because it is initialized in initialize()
    constructor(
        NotionalProxy notionalV2_,
        address lendingPool_,
        address weth_,
        IWstETH wstETH_,
        address note_,
        address dex1,
        address dex2
    )
        NotionalV2FlashLiquidatorBase(
            notionalV2_,
            lendingPool_,
            weth_,
            wstETH_,
            address(0),
            dex1,
            dex2
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
        NotionalV2.enableBitmapCurrency(ifCashCurrencyId);
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
        NotionalV2.setApprovalForAll(account, true);
    }

    function revokeRole(bytes32 role, address account) public virtual override onlyOwner {
        // Hardcoding role to USER_ROLE for safety
        AccessControl.revokeRole(USER_ROLE, account);
        // Revoke ERC1155 access
        NotionalV2.setApprovalForAll(account, false);
    }

    modifier ownerOrUser() {
        require(hasRole(USER_ROLE, msg.sender) || msg.sender == owner, "User or owner required");
        _;
    }

    function batchBalanceTradeAction(BalanceActionWithTrades[] calldata actions)
        external
        ownerOrUser
    {
        NotionalV2.batchBalanceAndTradeAction(address(this), actions);
    }

    function batchBalanceAction(BalanceAction[] calldata actions) external ownerOrUser {
        NotionalV2.batchBalanceAction(address(this), actions);
    }

    function nTokenRedeem(
        uint96 tokensToRedeem,
        bool sellTokenAssets,
        bool acceptResidualAssets
    ) external ownerOrUser returns (int256) {
        return
            NotionalV2.nTokenRedeem(
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
        return NotionalV2.withdraw(currencyId, amountInternalPrecision, redeemToUnderlying);
    }

    function claimNOTE() external ownerOrUser returns (uint256) {
        uint256 notesClaimed = NotionalV2.nTokenClaimIncentives();
        IERC20(NOTE).transfer(owner, notesClaimed);
        return notesClaimed;
    }

    function liquidateLocalCurrency(
        address liquidateAccount,
        uint16 localCurrencyId,
        uint96 maxNTokenLiquidation
    ) external ownerOrUser returns (int256, int256) {
        return
            NotionalV2.liquidateLocalCurrency(
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
        external
        ownerOrUser
        returns (
            int256,
            int256,
            int256
        )
    {
        return
            NotionalV2.liquidateCollateralCurrency(
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
    ) external ownerOrUser {
        NotionalV2.liquidatefCashLocal(
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
    ) external ownerOrUser {
        NotionalV2.liquidatefCashCrossCurrency(
            liquidateAccount,
            localCurrencyId,
            ifCashCurrencyId,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );
    }

    function mintCTokens(address[] calldata assets, uint256[] calldata amounts)
        external
        ownerOrUser
    {
        _mintCTokens(assets, amounts);
    }

    function redeemCTokens(address[] calldata assets) external ownerOrUser {
        _redeemCTokens(assets);
    }

    function executeDexTrade(uint256 ethValue, TradeData calldata tradeData) external ownerOrUser {
        _executeDexTrade(ethValue, tradeData);
    }

    function wrapToWETH() external ownerOrUser {
        _wrapToWETH();
    }

    function withdrawToOwner(address token, uint256 amount) external ownerOrUser {
        IERC20(token).transfer(owner, amount);
    }

    function _getAssetCashAmount(uint16 currencyId, int256 fCashValue)
        internal
        view
        returns (int256)
    {
        // prettier-ignore
        (
            /* Token memory assetToken */,
            /* Token memory underlyingToken */,
            /* ETHRate memory ethRate */,
            AssetRateParameters memory assetRate
        ) = NotionalV2.getCurrencyAndRates(currencyId);

        return assetRate.convertFromUnderlying(fCashValue);
    }

    function _redeemAndWithdraw(
        uint16 nTokenCurrencyId,
        uint96 nTokenBalance,
        bool redeemToUnderlying
    ) internal override {
        NotionalV2.nTokenRedeem(address(this), nTokenCurrencyId, nTokenBalance, true, true);

        // prettier-ignore
        (
            int256 cashBalance,
            /* int256 nTokenBalance */,
            /* uint256 lastClaimTime */
        ) = NotionalV2.getAccountBalance(nTokenCurrencyId, address(this));

        PortfolioAsset[] memory assets = NotionalV2.getAccountPortfolio(address(this));

        // Make sure we leave enough cash to cover the negative fCash residuals
        for (uint256 i; i < assets.length; i++) {
            if (assets[i].currencyId == nTokenCurrencyId && assets[i].notional < 0) {
                cashBalance = cashBalance.add(
                    _getAssetCashAmount(nTokenCurrencyId, assets[i].notional)
                );
            }
        }

        require(cashBalance >= 0 && cashBalance <= type(uint88).max, "Invalid cash balance");

        if (cashBalance > 0) {
            NotionalV2.withdraw(nTokenCurrencyId, uint88(uint256(cashBalance)), redeemToUnderlying);
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

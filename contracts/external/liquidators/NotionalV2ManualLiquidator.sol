// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "./NotionalV2BaseLiquidator.sol";
import "./NotionalV2UniV3SwapRouter.sol";
import "../../../interfaces/compound/CErc20Interface.sol";
import "../../../interfaces/compound/CEtherInterface.sol";
import "../../../interfaces/uniswap/v3/ISwapRouter.sol";

contract NotionalV2ManualLiquidator is
    NotionalV2BaseLiquidator,
    NotionalV2UniV3SwapRouter,
    AccessControl,
    Initializable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant USER_ROLE = keccak256("USER_ROLE");
    address public immutable NOTE;
    address internal immutable DEPLOYER;

    // @dev setting owner to address(0) because it is initialized in initialize()
    constructor(
        NotionalProxy notionalV2_,
        address weth_,
        address cETH_,
        ISwapRouter exchange_,
        address note_
    )
        NotionalV2BaseLiquidator(notionalV2_, weth_, cETH_, address(0))
        NotionalV2UniV3SwapRouter(exchange_)
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
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        owner = newOwner;
        // Make new user the USER_ROLE admin
        grantRole(ADMIN_ROLE, newOwner);
        revokeRole(ADMIN_ROLE, msg.sender);
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

    function nTokenRedeem(uint96 tokensToRedeem, bool sellTokenAssets)
        external
        ownerOrUser
        returns (int256)
    {
        return
            NotionalV2.nTokenRedeem(
                address(this),
                ifCashCurrencyId,
                tokensToRedeem,
                sellTokenAssets,
                false
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

    // path = [tokenAddr1, fee, tokenAddr2, fee, tokenAddr3]
    function executeDexTrade(
        bytes calldata path,
        uint256 deadline,
        uint256 amountIn,
        uint256 amountOutMin
    ) external ownerOrUser returns (uint256) {
        bytes memory encoded = abi.encode(path, deadline);

        return _executeDexTrade(amountIn, amountOutMin, encoded);
    }

    function wrapToWETH() external ownerOrUser {
        _wrapToWETH();
    }

    function withdrawToOwner(address token, uint256 amount) external ownerOrUser {
        IERC20(token).transfer(owner, amount);
    }
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "interfaces/notional/NotionalProxy.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../proxy/utils/UUPSUpgradeable.sol";

interface WETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function transfer(address dst, uint256 wad) external returns (bool);
}

abstract contract NotionalV2BaseLiquidator is Initializable, UUPSUpgradeable {
    enum LiquidationAction {
        LocalCurrency_NoTransferFee_Withdraw,
        CollateralCurrency_NoTransferFee_Withdraw,
        LocalfCash_NoTransferFee_Withdraw,
        CrossCurrencyfCash_NoTransferFee_Withdraw,
        LocalCurrency_WithTransferFee_Withdraw,
        CollateralCurrency_WithTransferFee_Withdraw,
        LocalfCash_WithTransferFee_Withdraw,
        CrossCurrencyfCash_WithTransferFee_Withdraw,
        LocalCurrency_NoTransferFee_NoWithdraw,
        CollateralCurrency_NoTransferFee_NoWithdraw,
        LocalfCash_NoTransferFee_NoWithdraw,
        CrossCurrencyfCash_NoTransferFee_NoWithdraw,
        LocalCurrency_WithTransferFee_NoWithdraw,
        CollateralCurrency_WithTransferFee_NoWithdraw,
        LocalfCash_WithTransferFee_NoWithdraw,
        CrossCurrencyfCash_WithTransferFee_NoWithdraw
    }

    NotionalProxy public NotionalV2;
    mapping(address => address) underlyingToCToken;
    address public WETH;
    address public cETH;
    address public OWNER;

    modifier onlyOwner() {
        require(OWNER == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /// @dev Only the owner may upgrade the contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function __NotionalV2BaseLiquidator_init(
        NotionalProxy notionalV2_,
        address weth_,
        address cETH_,
        address owner_
    ) internal initializer {
        NotionalV2 = notionalV2_;
        WETH = weth_;
        cETH = cETH_;
        OWNER = owner_;
    }

    function executeDexTrade(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal virtual;

    function checkAllowanceOrSet(address erc20, address spender) internal {
        if (IERC20(erc20).allowance(address(this), spender) < 2**128) {
            IERC20(erc20).approve(spender, type(uint256).max);
        }
    }

    function _hasTransferFees(LiquidationAction action) internal pure returns (bool) {
        return (action == LiquidationAction.LocalCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.LocalfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_NoWithdraw);
    }

    function _mintCTokens(address[] calldata assets, uint256[] calldata amounts) internal {
        for (uint256 i; i < assets.length; i++) {
            if (assets[i] == WETH) {
                // Withdraw WETH to ETH and mint CEth
                WETH9(WETH).withdraw(amounts[i]);
                CEtherInterface(cETH).mint{value: amounts[i]}();
            } else {
                address cToken = underlyingToCToken[assets[i]];
                if (cToken != address(0)) {
                    checkAllowanceOrSet(assets[i], cToken);
                    CErc20Interface(cToken).mint(amounts[i]);
                }
            }
        }
    }

    function _redeemCTokens(address[] calldata assets) internal {
        // Redeem cTokens to underlying to repay the flash loan
        for (uint256 i; i < assets.length; i++) {
            address cToken = assets[i] == WETH ? cETH : underlyingToCToken[assets[i]];
            if (cToken == address(0)) continue;

            CErc20Interface(cToken).redeem(IERC20(cToken).balanceOf(address(this)));
            // Wrap ETH into WETH for repayment
            if (assets[i] == WETH && address(this).balance > 0) {
                WETH9(WETH).deposit{value: address(this).balance}();
            }
        }
    }

    function _liquidateLocal(
        LiquidationAction action,
        bytes calldata params,
        address[] calldata assets
    ) internal {
        // prettier-ignore
        (
            /* uint8 action */,
            address liquidateAccount,
            uint256 localCurrency,
            uint96 maxNTokenLiquidation
        ) = abi.decode(params, (uint8, address, uint256, uint96));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NotionalV2));
            NotionalV2.depositUnderlyingToken(address(this), uint16(localCurrency), amount);
        }

        // prettier-ignore
        (
            /* int256 localAssetCashFromLiquidator */,
            int256 netNTokens
        ) = NotionalV2.liquidateLocalCurrency(liquidateAccount, localCurrency, maxNTokenLiquidation);

        // Will withdraw entire cash balance. Don't redeem local currency here because it has been flash
        // borrowed and we need to redeem the entire balance to underlying for the flash loan repayment.
        _redeemAndWithdraw(localCurrency, uint96(netNTokens), false);
    }

    function _liquidateCollateral(
        LiquidationAction action,
        bytes calldata params,
        address[] calldata assets
    ) internal {
        // prettier-ignore
        (
            /* uint8 action */,
            address liquidateAccount,
            uint256 localCurrency,
            /* uint256 localAddress */,
            uint256 collateralCurrency,
            address collateralAddress,
            /* address collateralUnderlyingAddress */,
            uint128 maxCollateralLiquidation,
            uint96 maxNTokenLiquidation
        ) = abi.decode(params, (uint8, address, uint256, address, uint256, address, address, uint128, uint96));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NotionalV2));
            NotionalV2.depositUnderlyingToken(address(this), uint16(localCurrency), amount);
        }

        // prettier-ignore
        (
            /* int256 localAssetCashFromLiquidator */,
            /* int256 collateralAssetCash */,
            int256 collateralNTokens
        ) = NotionalV2.liquidateCollateralCurrency(
            liquidateAccount,
            localCurrency,
            collateralCurrency,
            maxCollateralLiquidation,
            maxNTokenLiquidation,
            true, // Withdraw collateral
            false // Redeem to underlying (will happen later)
        );

        // Redeem to underlying for collateral because it needs to be traded on the DEX
        _redeemAndWithdraw(collateralCurrency, uint96(collateralNTokens), true);

        CErc20Interface(collateralAddress).redeem(
            IERC20(collateralAddress).balanceOf(address(this))
        );

        // Wrap everything to WETH for trading
        if (collateralCurrency == 1) WETH9(WETH).deposit{value: address(this).balance}();

        // Will withdraw all cash balance, no need to redeem local currency, it will be
        // redeemed later
        if (_hasTransferFees(action)) _redeemAndWithdraw(localCurrency, 0, false);
    }

    function _redeemAndWithdraw(
        uint256 nTokenCurrencyId,
        uint96 nTokenBalance,
        bool redeemToUnderlying
    ) internal {
        BalanceAction[] memory action = new BalanceAction[](1);
        // If nTokenBalance is zero still try to withdraw entire cash balance
        action[0].actionType = nTokenBalance == 0
            ? DepositActionType.None
            : DepositActionType.RedeemNToken;
        action[0].currencyId = uint16(nTokenCurrencyId);
        action[0].depositActionAmount = nTokenBalance;
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = redeemToUnderlying;
        NotionalV2.batchBalanceAction(address(this), action);
    }
}

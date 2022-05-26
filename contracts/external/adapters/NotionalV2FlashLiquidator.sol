// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./NotionalV2BaseLiquidator.sol";
import "./NotionalV2UniV3SwapRouter.sol";
import "../../math/SafeInt256.sol";
import "../../../interfaces/notional/NotionalProxy.sol";
import "../../../interfaces/compound/CTokenInterface.sol";
import "../../../interfaces/compound/CErc20Interface.sol";
import "../../../interfaces/compound/CEtherInterface.sol";
import "../../../interfaces/aave/IFlashLender.sol";
import "../../../interfaces/aave/IFlashLoanReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract NotionalV2FlashLiquidator is
    NotionalV2BaseLiquidator,
    NotionalV2UniV3SwapRouter,
    IFlashLoanReceiver
{
    using SafeInt256 for int256;
    using SafeMath for uint256;

    address public immutable LENDING_POOL;

    constructor(
        NotionalProxy notionalV2_,
        address lendingPool_,
        address weth_,
        address cETH_,
        address owner_,
        ISwapRouter exchange_
    )
        NotionalV2BaseLiquidator(notionalV2_, weth_, cETH_, owner_)
        NotionalV2UniV3SwapRouter(exchange_)
    {
        LENDING_POOL = lendingPool_;
    }

    function setCTokenAddress(address cToken) external onlyOwner {
        address underlying = _setCTokenAddress(cToken);
        // Lending pool needs to be able to pull underlying
        checkAllowanceOrSet(underlying, LENDING_POOL);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        owner = newOwner;
    }

    // Profit estimation
    function flashLoan(
        address flashLender,
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external onlyOwner returns (uint256) {
        IFlashLender(flashLender).flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
        return IERC20(assets[0]).balanceOf(address(this));
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == LENDING_POOL); // dev: unauthorized caller
        LiquidationAction action = LiquidationAction(abi.decode(params, (uint8)));

        // Mint cTokens for incoming assets, if required. If there are transfer fees
        // the we deposit underlying instead inside each _liquidate call instead
        if (!_hasTransferFees(action)) _mintCTokens(assets, amounts);

        if (
            action == LiquidationAction.LocalCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.LocalCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.LocalCurrency_NoTransferFee_NoWithdraw
        ) {
            _liquidateLocal(action, params, assets);
        } else if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_NoWithdraw
        ) {
            _liquidateCollateral(action, params, assets);
        } else if (
            action == LiquidationAction.LocalfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.LocalfCash_NoTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_NoTransferFee_NoWithdraw
        ) {
            _liquidateLocalfCash(action, params, assets);
        } else if (
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_NoWithdraw
        ) {
            _liquidateCrossCurrencyfCash(action, params, assets);
        }

        _redeemCTokens(assets);

        if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_NoWithdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_NoWithdraw
        ) {
            _dexTrade(action, assets[0], amounts[0], premiums[0], params);
        }

        if (
            action == LiquidationAction.LocalCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_NoTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_Withdraw
        ) {
            // Transfer profits to OWNER
            uint256 bal = IERC20(assets[0]).balanceOf(address(this));
            if (bal > amounts[0].add(premiums[0])) {
                IERC20(assets[0]).transfer(owner, bal.sub(amounts[0].add(premiums[0])));
            }
        }

        // The lending pool should have enough approval to pull the required amount from the contract
        return true;
    }

    function _dexTrade(
        LiquidationAction action,
        address to,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) internal {
        address collateralUnderlyingAddress;
        bytes memory tradeCallData;
        uint256 bal = IERC20(to).balanceOf(address(this));

        if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_NoWithdraw
        ) {
            // prettier-ignore
            (
                /* uint8 action */,
                /* address liquidateAccount */,
                /* uint256 localCurrency */,
                /* address localCurrencyAddress */,
                /* uint256 collateralCurrency */,
                /* address collateralAddress, */,
                collateralUnderlyingAddress,
                /* uint128 maxCollateralLiquidation */,
                /* uint96 maxNTokenLiquidation */,
                tradeCallData
            ) = abi.decode(params, (uint8, address, uint256, address, uint256, address, address, uint128, uint96, bytes));
        } else {
            // prettier-ignore
            (
                /* uint8 action */,
                /* address liquidateAccount */,
                /* uint256 localCurrency*/,
                /* address localCurrencyAddress */,
                /* uint256 collateralCurrency */,
                /* address collateralAddress, */,
                collateralUnderlyingAddress,
                /* fCashMaturities */,
                /* maxfCashLiquidateAmounts */,
                tradeCallData
            ) = abi.decode(params, (uint8, address, uint256, address, uint256, address, address, uint256[], uint256[], bytes));
        }

        _executeDexTrade(
            IERC20(collateralUnderlyingAddress).balanceOf(address(this)),
            amount.sub(bal).add(premium), // Amount needed to pay back flash loan
            tradeCallData
        );
    }

    function wrapToWETH() external {
        _wrapToWETH();
    }

    function withdraw(address token, uint256 amount) external {
        IERC20(token).transfer(owner, amount);
    }

    receive() external payable {}
}

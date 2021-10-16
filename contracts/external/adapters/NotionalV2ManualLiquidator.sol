// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./NotionalV2BaseLiquidator.sol";

contract NotionalV2ManualLiquidator is NotionalV2BaseLiquidator {
    address public immutable EXCHANGE;
    address public immutable LOCAL_CURRENCY;

    constructor(
        NotionalProxy notionalV2_,
        address weth_,
        address cETH_,
        address owner_,
        address exchange_,
        address localCurrency_
    ) NotionalV2BaseLiquidator(notionalV2_, weth_, cETH_, owner_) {
        EXCHANGE = exchange_;
        LOCAL_CURRENCY = localCurrency_;
    }

    function localLiquidateNoTransferFee(address account) public {}

    function localLiquidateWithTransferFee(address account) public {
        // _liquidateLocal() => nToken
        // redeemNtoken -> cTokens
    }

    function collateralLiquidateNoTransferFee(
        address account,
        uint16 localCurrencyId,
        address localCurrencyAddress,
        uint16 collateralCurrencyId,
        address collateralCurrencyAddress,
        address collateralUnderlyingAddress,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    ) public returns (uint256) {
        bytes memory encoded = abi.encode(
            LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw,
            account,
            localCurrencyId,
            localCurrencyAddress,
            collateralCurrencyId,
            collateralCurrencyAddress,
            collateralUnderlyingAddress,
            maxCollateralLiquidation,
            maxNTokenLiquidation
        );
        
        address[] memory assets = new address[](1);
        assets[0] = localCurrencyAddress;

        _liquidateCollateral(
            LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw,
            encoded,
            assets
        );

        // withdraw + redeem -> underlying or WETH
        return 0;
    }

    function collateralLiquidateWithTransferFee(
        address account,
        address localCurrency,
        bytes calldata params
    ) public {}

    function fcashLocalLiquidate(address account) public {}

    function fcashCrossCurrencyLiquidate(address account) public {}

    // 1M cDAI
    // 1 WBTC   20000 cDAI
    // 1.1 WBTC

    function tradeAndWrap(
        address assetFrom,  // cETH   cWBTC cDAI
        uint256 amountIn,
        address from,       // WETH   WBTC   DAI
        address to,         // DAI    USDC
        address assetTo     // cDAI   cUSDC
    ) public {
       /* uint256 amountIn = CEtherInterface(assetFrom).redeem(IERC(assetFrom).balanceOf(address(this)));

        bytes memory params = abi.encode(3000, block.timestamp + 3000, 0);
        
        uint256 amountOut = executeDexTrade(from, to, amountIn, 0, params); 

        CEtherInterface(asset).mint(amountOut); */
    }

    // tradeAll

    function executeDexTrade(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal override returns (uint256) {}
}

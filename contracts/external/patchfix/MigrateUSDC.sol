// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../global/LibStorage.sol";
import "../../proxy/nProxy.sol";
import "../../../interfaces/IERC20.sol";
import "./BasePatchFixRouter.sol";
import "../../internal/pCash/PrimeCashExchangeRate.sol";

contract MigrateUSDC is BasePatchFixRouter {
    IERC20 public constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 public constant USDC_E = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    address payable constant proxy = 0x1344A36A1B56144C3Bc62E7757377D288fDE0369;
    uint16 constant USDC_CURRENCY_ID = 3;
    address public constant FUNDING = 0x25F45C5Bf1E703667B1B2319c770d96fdC9b9Cd8;
    IPrimeCashHoldingsOracle immutable holdingsOracle;

    event TokenMigrated(uint16 currencyId) ;

    constructor(IPrimeCashHoldingsOracle _holdingsOracle) BasePatchFixRouter(
        nProxy(proxy).getImplementation(),
        nProxy(proxy).getImplementation(),
        NotionalProxy(proxy)
    ) {
        holdingsOracle = _holdingsOracle;
    }

    function _patchFix() internal override {
        mapping(address => uint256) storage store = LibStorage.getStoredTokenBalances();
        uint256 currentUSDC_E = USDC_E.balanceOf(address(this));
        // Confirm balances match
        require(store[address(USDC_E)] == currentUSDC_E);
        require(store[address(USDC)] == 0);

        USDC.transferFrom(FUNDING, address(this), currentUSDC_E);
        USDC_E.transfer(FUNDING, currentUSDC_E);
        uint256 currentUSDC = USDC.balanceOf(address(this));
        // Confirm transfer success
        require(currentUSDC == currentUSDC_E);
        require(USDC_E.balanceOf(address(this)) == 0);

        delete store[address(USDC_E)];
        store[address(USDC)] = currentUSDC_E;

        mapping(uint256 => mapping(bool => TokenStorage)) storage tokens = LibStorage.getTokenStorage();
        tokens[USDC_CURRENCY_ID][true].tokenAddress = address(USDC);

        emit TokenMigrated(USDC_CURRENCY_ID);

        PrimeCashExchangeRate.updatePrimeCashHoldingsOracle(USDC_CURRENCY_ID, holdingsOracle);
    }
}
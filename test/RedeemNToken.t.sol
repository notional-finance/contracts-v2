// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";

import { Router } from "../contracts/external/Router.sol";
import { BatchAction } from "../contracts/external/actions/BatchAction.sol";
import "../interfaces/notional/NotionalProxy.sol";

contract RedeemNToken is Test {
    NotionalProxy constant NOTIONAL = NotionalProxy(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    string ARBITRUM_RPC_URL = vm.envString("ARBITRUM_RPC_URL");
    uint256 ARBITRUM_FORK_BLOCK = 133312145;

    function getDeployedContracts() internal view returns (Router.DeployedContracts memory c) {
        Router r = Router(payable(address(NOTIONAL)));
        c.governance = r.GOVERNANCE();
        c.views = r.VIEWS();
        c.initializeMarket = r.INITIALIZE_MARKET();
        c.nTokenActions = r.NTOKEN_ACTIONS();
        c.batchAction = r.BATCH_ACTION();
        c.accountAction = r.ACCOUNT_ACTION();
        c.erc1155 = r.ERC1155();
        c.liquidateCurrency = r.LIQUIDATE_CURRENCY();
        c.liquidatefCash = r.LIQUIDATE_FCASH();
        c.treasury = r.TREASURY();
        c.calculationViews = r.CALCULATION_VIEWS();
        c.vaultAccountAction = r.VAULT_ACCOUNT_ACTION();
        c.vaultLiquidationAction = r.VAULT_LIQUIDATION_ACTION();
        c.vaultAccountHealth = r.VAULT_ACCOUNT_HEALTH();
    }

    function upgradeTo(Router.DeployedContracts memory c) internal returns (Router) {
        address r = address(new Router(c));
        vm.prank(NOTIONAL.owner());
        NOTIONAL.upgradeTo(address(r));
    }

    function setUp() public {
        vm.createSelectFork(ARBITRUM_RPC_URL, ARBITRUM_FORK_BLOCK);
        Router.DeployedContracts memory c = getDeployedContracts();
        c.batchAction = address(new BatchAction());

        upgradeTo(c);
    }

    function test_RedeemResiduals() public {
        address acct = 0xd74e7325dFab7D7D1ecbf22e6E6874061C50f243;
        uint16 USDC = 3;
        vm.startPrank(acct);
        (/* */, int256 nTokenBalance, /* */) = NOTIONAL.getAccountBalance(USDC, acct);

        BalanceAction[] memory t = new BalanceAction[](1);
        t[0] = BalanceAction({
            actionType: DepositActionType.RedeemNToken,
            currencyId: USDC,
            depositActionAmount: uint256(nTokenBalance),
            withdrawAmountInternalPrecision: 0,
            withdrawEntireCashBalance: true,
            redeemToUnderlying: true
        });
        NOTIONAL.batchBalanceAction(acct, t);


        // NOTE: the nToken's fCash position should be unchanged
    }
}
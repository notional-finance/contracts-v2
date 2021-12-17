// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./Router.sol";
import "interfaces/notional/NotionalTreasury.sol";

contract RouterV2 is Router {
    address public immutable TREASURY;
    
    constructor(
        address governance_,
        address views_,
        address initializeMarket_,
        address nTokenActions_,
        address nTokenRedeem_,
        address batchAction_,
        address accountAction_,
        address erc1155_,
        address liquidateCurrency_,
        address liquidatefCash_,
        address cETH_,
        address treasury_
    ) Router(
        governance_,
        views_,
        initializeMarket_,
        nTokenActions_,
        nTokenRedeem_,
        batchAction_,
        accountAction_,
        erc1155_,
        liquidateCurrency_,
        liquidatefCash_,
        cETH_
    ) {
        TREASURY = treasury_;
    }

    function getRouterImplementation(bytes4 sig) public override view returns (address) {
        if (
            sig == NotionalTreasury.claimCOMP.selector ||
            sig == NotionalTreasury.setTreasuryManager.selector
        ) {
            return TREASURY;
        }

        return Router.getRouterImplementation(sig);
    }
}
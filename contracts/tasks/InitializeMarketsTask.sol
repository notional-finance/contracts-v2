// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../global/Constants.sol";
import "../../interfaces/chainlink/KeeperCompatibleInterface.sol";
import "interfaces/notional/NotionalProxy.sol";

contract InitializeMarketsTask is KeeperCompatibleInterface {
    NotionalProxy public NotionalV2;
    address public OWNER;
    uint16 public CURRENCY_ID;
    uint256 public LAST_TIMESTAMP;

    constructor(uint16 currencyId_, NotionalProxy notionalV2_, address owner_) {
        NotionalV2 = notionalV2_;
        OWNER = owner_;
        CURRENCY_ID = currencyId_;
    }

    function checkUpkeep(bytes calldata /* checkData */) external override returns (bool upkeepNeeded, bytes memory /*performData*/) {
        address nToken = NotionalV2.nTokenAddress(CURRENCY_ID);
        (
            /*uint16 currencyId*/,
            /*uint256 totalSupply*/,
            /*uint256 incentiveAnnualEmissionRate*/,
            uint256 lastInitializedTime,
            /*bytes5 nTokenParameters*/,
            /*int256 cashBalance*/,
            /*uint256 integralTotalSupply*/,
            /*uint256 lastSupplyChangeTime*/
        ) = NotionalV2.getNTokenAccount(nToken);
        upkeepNeeded = (block.timestamp - lastInitializedTime) > Constants.QUARTER;
    }

    function performUpkeep(bytes calldata performData) external override {
        LAST_TIMESTAMP = block.timestamp;
        NotionalV2.initializeMarkets(CURRENCY_ID, false);
    }   
}

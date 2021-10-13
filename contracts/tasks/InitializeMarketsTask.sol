// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../global/Constants.sol";
import "../../interfaces/chainlink/KeeperCompatibleInterface.sol";
import "interfaces/notional/NotionalProxy.sol";

contract InitializeMarketsTask is KeeperCompatibleInterface {
    NotionalProxy public NotionalV2;
    address public OWNER;
    uint256 public LAST_TIMESTAMP;

    constructor(NotionalProxy notionalV2_, address owner_) {
        NotionalV2 = notionalV2_;
        OWNER = owner_;
    }

    function checkUpkeep(bytes calldata checkData) external override returns (bool upkeepNeeded, bytes memory performData) {
        uint16 currencyId = abi.decode(checkData, (uint16));
        address nToken = NotionalV2.nTokenAddress(currencyId);
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
        performData = checkData;
    }

    function performUpkeep(bytes calldata performData) external override {
        uint16 currencyId = abi.decode(performData, (uint16));
        NotionalV2.initializeMarkets(currencyId, false);
        LAST_TIMESTAMP = block.timestamp;
    }   
}

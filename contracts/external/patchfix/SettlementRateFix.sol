// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../global/LibStorage.sol";
import "../../global/Types.sol";

contract SettlementRateFix {
    uint256 private constant ETH = 1;
    uint256 private constant DAI = 2;
    uint256 private constant USDC = 3;
    uint256 private constant WBTC = 4;
    uint256 private constant MAR_29_2022 = 1648512000;
    uint256 private constant SEP_24_2022 = 1664064000;

    event SetSettlementRate(uint256 indexed currencyId, uint256 indexed maturity, uint128 rate);

    function _patchFixSettlementRates() internal {
        // Delete these settlement rates that have been set previously
        _deleteSettlementRate(ETH, MAR_29_2022);
        _deleteSettlementRate(DAI, MAR_29_2022);
        _deleteSettlementRate(USDC, MAR_29_2022);
        _deleteSettlementRate(WBTC, MAR_29_2022);
        _deleteSettlementRate(DAI, SEP_24_2022);
        _deleteSettlementRate(USDC, SEP_24_2022);
    }

    function _deleteSettlementRate(uint256 currencyId, uint256 maturity) private {
        mapping(uint256 => mapping(uint256 => SettlementRateStorage)) storage store = LibStorage.getSettlementRateStorage_deprecated();
        delete store[currencyId][maturity];
        emit SetSettlementRate(currencyId, maturity, 0);
    }

}
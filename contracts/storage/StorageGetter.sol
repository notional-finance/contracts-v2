// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";

library StorageGetter {
    uint internal constant MARKET_STORAGE_SLOT = 6;
    uint internal constant LIQUIDITY_STORAGE_SLOT = 7;

    function getMarketStorage(uint currencyId, uint maturity) internal view returns (MarketStorage memory) {
        bytes32 slot = keccak256(abi.encode(maturity, keccak256(abi.encode(currencyId, MARKET_STORAGE_SLOT))));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        MarketStorage memory m = MarketStorage({
            totalfCash: uint80(uint(data)),
            totalCurrentCash: uint80(uint(data >> 80)),
            lastImpliedRate: uint32(uint(data >> 160)),
            oracleRate: uint32(uint(data >> 192)),
            previousTradeTime: uint32(uint(data >> 224))
        });

        return m;
    }

    function getTotalLiquidity(uint currencyId, uint maturity) internal view returns (uint) {
        bytes32 slot = keccak256(abi.encode(maturity, keccak256(abi.encode(currencyId, LIQUIDITY_STORAGE_SLOT))));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        // TODO: can there be potential dirty bits here
        return uint(data);
    }

}

contract MockStorageUtils is StorageLayoutV1 {

    function _getMarketStorage(
        uint currencyId,
        uint maturity
    ) public view returns (MarketStorage memory) {
        return StorageGetter.getMarketStorage(currencyId, maturity);
    }

    function _getTotalLiquidity(
        uint currencyId,
        uint maturity
    ) public view returns (uint) {
        return StorageGetter.getTotalLiquidity(currencyId, maturity);
    }

    function setMarketStorage(
        uint currencyId,
        uint maturity,
        MarketStorage memory market
    ) public {
        marketStateMapping[currencyId][maturity] = market;
    }

    function setTotalLiquidity(
        uint currencyId,
        uint maturity,
        uint80 totalLiquidity
    ) public {
        marketTotalLiquidityMapping[currencyId][maturity] = totalLiquidity;
    }
}
// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";

library StorageGetter {
    uint internal constant ASSET_RATE_STORAGE_SLOT = 3;
    uint internal constant CASH_GROUP_STORAGE_SLOT = 5;
    uint internal constant MARKET_STORAGE_SLOT = 6;
    uint internal constant LIQUIDITY_STORAGE_SLOT = 7;
    uint internal constant BALANCE_STORAGE_SLOT = 12;

    function getMarketStorage(uint currencyId, uint maturity) internal view returns (MarketStorage memory) {
        bytes32 slot = keccak256(abi.encode(maturity, keccak256(abi.encode(currencyId, MARKET_STORAGE_SLOT))));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return MarketStorage({
            totalfCash: uint80(uint(data)),
            totalCurrentCash: uint80(uint(data >> 80)),
            lastImpliedRate: uint32(uint(data >> 160)),
            oracleRate: uint32(uint(data >> 192)),
            previousTradeTime: uint32(uint(data >> 224))
        });
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

    function getBalanceStorage(address account, uint currencyId) internal view returns (int, uint) {
        bytes32 slot = keccak256(abi.encode(currencyId, keccak256(abi.encode(account, BALANCE_STORAGE_SLOT))));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return (
            int(int128(int(data))), // Cash balance
            uint(data >> 128) // Perpetual token balance
        );
    }

    function getCashGroup(uint currencyId) internal view returns (bytes memory) {
        bytes32 slot = keccak256(abi.encode(currencyId, CASH_GROUP_STORAGE_SLOT));
        bytes32 data;

        assembly {
            data := sload(slot)
        }


        // A lot of overhead to decode these bytes, we will decode them if used.
        return abi.encodePacked(data);
    }

    function getAssetRate(uint currencyId) internal view returns (RateStorage memory) {
        bytes32 slot = keccak256(abi.encode(currencyId, ASSET_RATE_STORAGE_SLOT));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        // TODO: maybe split this out?
        return RateStorage({
            rateOracle: address(bytes20(data)),
            rateDecimalPlaces: uint8(uint(data >> 8)),
            mustInvert: bytes1(data >> 16) != 0x00,
            buffer: uint8(uint(data >> 24)),
            haircut: uint8(uint(data >> 32)),
            quoteDecimalPlaces: uint8(uint(data >> 40)),
            baseDecimalPlaces: uint8(uint(data >> 48))
        });
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

    function _getBalanceStorage(
        address account,
        uint currencyId
    ) public view returns (int, uint) {
        return StorageGetter.getBalanceStorage(account, currencyId);
    }

    function setBalanceStorage(
        address account,
        uint currencyId,
        BalanceStorage memory balance
    ) public {
        accountBalanceMapping[account][currencyId] = balance;
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
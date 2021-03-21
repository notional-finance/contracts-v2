// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/ExchangeRate.sol";
import "../common/CashGroup.sol";
import "../common/PerpetualToken.sol";
import "../storage/TokenHandler.sol";
import "../storage/StorageLayoutV1.sol";
import "../adapters/AssetRateAdapterInterface.sol";
import "../adapters/PerpetualTokenERC20.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @notice Governance methods can only be called by the timelock controller which is in turn
 * administered by the governance contract.
 */
contract GovernanceAction is StorageLayoutV1 {
    using AccountContextHandler for AccountStorage;

    // Emitted when a new currency is listed
    event ListCurrency(uint16 newCurrencyId);
    event UpdateETHRate(uint16 currencyId);
    event UpdateAssetRate(uint16 currencyId);
    event UpdateCashGroup(uint16 currencyId);
    event UpdatePerpetualDepositParameters(uint16 currencyId);
    event UpdateInitializationParameters(uint16 currencyId);
    event UpdateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate);
    // TODO: add gas price setting for liquidation
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @notice Lists a new currency along with its exchange rate to ETH.
     */
    function listCurrency(
        TokenStorage calldata assetToken,
        TokenStorage calldata underlyingToken,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external onlyOwner {
        uint16 currencyId = maxCurrencyId + 1;
        maxCurrencyId = currencyId;
        require(currencyId <= type(uint16).max, "G: max currency overflow");
        // TODO: should check for listing of duplicate tokens?

        // Set the underlying first because the asset token may set an approval using the underlying
        if (underlyingToken.tokenAddress != address(0)) {
            TokenHandler.setToken(currencyId, true, underlyingToken);
        }
        TokenHandler.setToken(currencyId, false, assetToken);

        _updateETHRate(currencyId, rateOracle, mustInvert, buffer, haircut, liquidationDiscount);

        // Set the new max currency id
        emit ListCurrency(currencyId);
    }

    function enableCashGroup(
        uint16 currencyId,
        address assetRateOracle,
        CashGroupParameterStorage calldata cashGroup
    ) external onlyOwner {
        _updateCashGroup(currencyId, cashGroup);
        _updateAssetRate(currencyId, assetRateOracle);

        // Creates the perpetual token erc20 proxy that points back to the main proxy
        // and routes methods to PerpetualTokenAction
        address perpetualTokenAddress = Create2.deploy(
            0,
            bytes32(uint(currencyId)),
            abi.encodePacked(type(PerpetualTokenERC20).creationCode, abi.encode(address(this), currencyId))
        );

        PerpetualToken.setPerpetualTokenAddress(currencyId, perpetualTokenAddress);

        // Turn on the ifcash bitmap for the perp token
        AccountStorage memory perpTokenContext = AccountContextHandler.getAccountContext(perpetualTokenAddress);
        perpTokenContext.bitmapCurrencyId = currencyId;
        perpTokenContext.setAccountContext(perpetualTokenAddress);
    }

    function updatePerpetualDepositParameters(
        uint16 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) external onlyOwner {
        PerpetualToken.setDepositParameters(currencyId, depositShares, leverageThresholds);
        emit UpdatePerpetualDepositParameters(currencyId);
    }

    function updateInitializationParameters(
        uint16 currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) external onlyOwner {
        PerpetualToken.setInitializationParameters(currencyId, rateAnchors, proportions);
        emit UpdateInitializationParameters(currencyId);
    }

    function updateIncentiveEmissionRate(
        uint16 currencyId,
        uint32 newEmissionRate
    ) external onlyOwner {
        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        require(perpTokenAddress != address(0), "Invalid currency");

        PerpetualToken.setIncentiveEmissionRate(perpTokenAddress, newEmissionRate);
        emit UpdateIncentiveEmissionRate(currencyId, newEmissionRate);
    }

    function updateCashGroup(
        uint16 currencyId,
        CashGroupParameterStorage calldata cashGroup
    ) external onlyOwner {
        _updateCashGroup(currencyId, cashGroup);
    }

    function updateAssetRate(
        uint16 currencyId,
        address rateOracle
    ) external onlyOwner {
        _updateAssetRate(currencyId, rateOracle);
    }

    function updateETHRate(
        uint16 currencyId,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external onlyOwner {
        _updateETHRate(currencyId, rateOracle, mustInvert, buffer, haircut, liquidationDiscount); 
    }

    function _updateCashGroup(
        uint currencyId,
        CashGroupParameterStorage calldata cashGroup
    ) internal {
        require(currencyId != 0, "G: invalid currency id");
        require(currencyId <= maxCurrencyId, "G: invalid currency id");

        CashGroup.setCashGroupStorage(currencyId, cashGroup);

        emit UpdateCashGroup(uint16(currencyId));
    }

    function _updateAssetRate(
        uint currencyId,
        address rateOracle
    ) internal {
        require(currencyId != 0, "G: invalid currency id");
        require(currencyId <= maxCurrencyId, "G: invalid currency id");

        // Sanity check that the rate oracle refers to the proper asset token
        address token = AssetRateAdapterInterface(rateOracle).token();
        Token memory assetToken = TokenHandler.getToken(currencyId, false);
        require(assetToken.tokenAddress == token, "G: invalid rate oracle");

        uint8 underlyingDecimals;
        if (currencyId == 1) {
            // If currencyId is one then this is referring to cETH and there is no underlying() to call
            underlyingDecimals = 18;
        } else {
            address underlyingToken = AssetRateAdapterInterface(rateOracle).underlying();
            underlyingDecimals = ERC20(underlyingToken).decimals();
        }

        assetToUnderlyingRateMapping[currencyId] = AssetRateStorage({
            rateOracle: rateOracle,
            underlyingDecimalPlaces: underlyingDecimals
        });

        emit UpdateAssetRate(uint16(currencyId));
    }

    function _updateETHRate(
        uint currencyId,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) internal {
        require(currencyId != 0, "G: invalid currency id");
        require(currencyId <= maxCurrencyId, "G: invalid currency id");

        uint8 rateDecimalPlaces;
        if (currencyId == ExchangeRate.ETH) {
            // ETH to ETH exchange rate is fixed at 1 and has no rate oracle
            rateOracle = address(0);
            rateDecimalPlaces = 18;
        } else {
            require(rateOracle != address(0), "G: zero rate oracle address");
            rateDecimalPlaces = AggregatorV2V3Interface(rateOracle).decimals();
        }
        require(buffer >= ExchangeRate.MULTIPLIER_DECIMALS, "G: buffer must be gte decimals");
        require(haircut <= ExchangeRate.MULTIPLIER_DECIMALS, "G: buffer must be lte decimals");
        require(liquidationDiscount > ExchangeRate.MULTIPLIER_DECIMALS, "G: discount must be gt decimals");

        underlyingToETHRateMapping[currencyId] = ETHRateStorage({
            rateOracle: rateOracle,
            rateDecimalPlaces: rateDecimalPlaces,
            mustInvert: mustInvert,
            buffer: buffer,
            haircut: haircut,
            liquidationDiscount: liquidationDiscount
        });

        emit UpdateETHRate(uint16(currencyId));
    }

}
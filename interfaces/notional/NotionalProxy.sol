// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../contracts/common/ExchangeRate.sol";
import "../../contracts/common/CashGroup.sol";
import "../../contracts/common/AssetRate.sol";
import "../../contracts/common/PerpetualToken.sol";

// TODO: split this proxy into smaller parts
interface NotionalProxy {
    event ListCurrency(uint newCurrencyId);
    event UpdateETHRate(uint currencyId);
    event UpdateAssetRate(uint currencyId);
    event UpdateCashGroup(uint currencyId);
    event UpdatePerpetualDepositParameters(uint currencyId);
    event UpdateInitializationParameters(uint currencyId);
    // TODO: add incentive settings
    // TODO: add max assets parameter
    // TODO: add gas price setting for liquidation
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /** Initialize Markets Action */
    function initializeMarkets(uint currencyId, bool isFirstInit) external;

    /** Governance Action */
    function transferOwnership(address newOwner) external;

    function listCurrency(
        address assetTokenAddress,
        bool tokenHasTransferFee,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external;

    function enableCashGroup(
        uint16 currencyId,
        address assetRateOracle,
        CashGroupParameterStorage calldata cashGroup
    ) external;

    function updatePerpetualDepositParameters(
        uint16 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) external;

    function updateInitializationParameters(
        uint16 currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) external;

    function updateCashGroup(
        uint16 currencyId,
        CashGroupParameterStorage calldata cashGroup
    ) external;

    function updateAssetRate(
        uint16 currencyId,
        address rateOracle
    ) external;

    function updateETHRate(
        uint16 currencyId,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external;

    /** Mint Perpetual Token Action */
    function calculatePerpetualTokensToMint(
        uint16 currencyId,
        uint88 amountToDeposit
    ) external view returns (uint);

    function perpetualTokenMint(
        uint16 currencyId,
        uint88 amountToDeposit,
        bool useCashBalance
    ) external returns (uint);

    function perpetualTokenMintFor(
        uint16 currencyId,
        address recipient,
        uint88 amountToDeposit,
        bool useCashBalance
    ) external returns (uint);

    function perpetualTokenRedeem(
        uint16 currencyId,
        uint88 tokensToRedeem
    ) external returns (bool);

    /** Perpetual Token Action */
    function perpetualTokenTotalSupply(address perpTokenAddress) external view returns (uint);

    function perpetualTokenTransferAllowance(
        uint16 currencyId,
        address owner,
        address spender
    ) external view returns (uint);

    function perpetualTokenBalanceOf(
        uint16 currencyId,
        address account
    ) external view returns (uint);

    function perpetualTokenTransferApprove(
        uint16 currencyId,
        address owner,
        address spender,
        uint amount
    ) external returns (bool);

    function perpetualTokenTransfer(
        uint16 currencyId,
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);

    function perpetualTokenTransferFrom(
        uint16 currencyId,
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);

    function perpetualTokenTransferApproveAll(
        address spender,
        uint amount
    ) external returns (bool);

    function perpetualTokenPresentValueAssetDenominated(
        uint16 currencyId
    ) external view returns (int);

    function perpetualTokenPresentValueUnderlyingDenominated(
        uint16 currencyId
    ) external view returns (int);

    /** Views */
    function getMaxCurrencyId() external view returns (uint16);
    function getCurrency(uint16 currencyId) external view returns (CurrencyStorage memory);
    function getETHRateStorage(uint16 currencyId) external view returns (ETHRateStorage memory);
    function getETHRate(uint16 currencyId) external view returns (ETHRate memory);
    function getCurrencyAndRate(uint16 currencyId) external view returns (CurrencyStorage memory, ETHRate memory);
    function getCashGroup(uint16 currencyId) external view returns (CashGroupParameterStorage memory);
    function getAssetRateStorage(uint16 currencyId) external view returns (AssetRateStorage memory);
    function getAssetRate(uint16 currencyId) external view returns (AssetRateParameters memory);
    function getCashGroupAndRate(
        uint16 currencyId
    ) external view returns (CashGroupParameterStorage memory, AssetRateParameters memory);
    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory);
    function getMarketsActiveAtBlockTime(
        uint16 currencyId,
        uint32 blockTime
    ) external view returns (MarketParameters[] memory);
    function getInitializationParameters(uint16 currencyId) external view returns (int[] memory, int[] memory);
    function getPerpetualDepositParameters(uint16 currencyId) external view returns (int[] memory, int[] memory);
    function getPerpetualTokenAddress(uint16 currencyId) external view returns (address);
    function getOwner() external view returns (address);
    function getAccountContext(
        address account
    ) external view returns (AccountStorage memory);
    function getAccountBalance(
        uint16 currencyId,
        address account
    ) external view returns (int, int);
    function getAccountPortfolio(
        address account
    ) external view returns (PortfolioAsset[] memory);
}

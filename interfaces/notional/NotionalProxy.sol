// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../contracts/actions/DepositWithdrawAction.sol";
import "../../contracts/common/ExchangeRate.sol";
import "../../contracts/common/CashGroup.sol";
import "../../contracts/common/AssetRate.sol";
import "../../contracts/common/PerpetualToken.sol";
import "../../contracts/storage/TokenHandler.sol";
import "./PerpetualTokenActionInterface.sol";

// TODO: split this proxy into smaller parts
interface NotionalProxy is PerpetualTokenActionInterface {
    event ListCurrency(uint16 newCurrencyId);
    event UpdateETHRate(uint16 currencyId);
    event UpdateAssetRate(uint16 currencyId);
    event UpdateCashGroup(uint16 currencyId);
    event UpdatePerpetualDepositParameters(uint16 currencyId);
    event UpdateInitializationParameters(uint16 currencyId);
    event UpdateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate);
    // TODO: add gas price setting for liquidation
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /** User trading events */
    event CashBalanceChange(address indexed account, uint16 currencyId, int amount);
    event PerpetualTokenSupplyChange(address indexed account, uint16 currencyId, int amount);
    event BatchTradeExecution(address account, uint16 currencyId);

    /** Initialize Markets Action */
    function initializeMarkets(uint currencyId, bool isFirstInit) external;

    /** Governance Action */
    function transferOwnership(address newOwner) external;

    function listCurrency(
        TokenStorage calldata assetToken,
        TokenStorage calldata underlyingToken,
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

    function updateIncentiveEmissionRate(
        uint16 currencyId,
        uint32 newEmissionRate
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
    function perpetualTokenMint(
        uint16 currencyId,
        uint88 amountToDeposit,
        bool useCashBalance
    ) external returns (uint);

    /** Redeem Perpetual Token Action */
    function perpetualTokenRedeem(
        uint16 currencyId,
        uint88 tokensToRedeem_,
        bool sellTokenAssets
    ) external;

    /** Deposit Withdraw Action */
    function depositUnderlyingToken(
        address account,
        uint16 currencyId,
        uint amountExternalPrecision
    ) external returns (uint);

    function depositAssetToken(
        address account,
        uint16 currencyId,
        uint amountExternalPrecision
    ) external returns (uint);

    function withdraw(
        address account,
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external returns (uint);

    function batchBalanceAction(
        address account,
        BalanceAction[] calldata actions
    ) external;

    function batchBalanceAndTradeAction(
        address account,
        BalanceActionWithTrades[] calldata actions
    ) external;

    /** Views */
    function getMaxCurrencyId() external view returns (uint16);
    function getCurrency(uint16 currencyId) external view returns (Token memory);
    function getUnderlying(uint16 currencyId) external view returns (Token memory);
    function getETHRateStorage(uint16 currencyId) external view returns (ETHRateStorage memory);
    function getETHRate(uint16 currencyId) external view returns (ETHRate memory);
    function getCurrencyAndRate(uint16 currencyId) external view returns (Token memory, ETHRate memory);
    function getCashGroup(uint16 currencyId) external view returns (CashGroupParameterStorage memory);
    function getAssetRateStorage(uint16 currencyId) external view returns (AssetRateStorage memory);
    function getAssetRate(uint16 currencyId) external view returns (AssetRateParameters memory);
    function getCashGroupAndRate(
        uint16 currencyId
    ) external view returns (CashGroupParameterStorage memory, AssetRateParameters memory);
    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory);
    function getActiveMarketsAtBlockTime(
        uint16 currencyId,
        uint32 blockTime
    ) external view returns (MarketParameters[] memory);
    function getInitializationParameters(uint16 currencyId) external view returns (int[] memory, int[] memory);
    function getPerpetualDepositParameters(uint16 currencyId) external view returns (int[] memory, int[] memory);
    function getPerpetualTokenAddress(uint16 currencyId) external view returns (address);
    function getOwner() external view returns (address);
    function getAccountContext(address account) external view returns (AccountStorage memory);
    function getAccountBalance(uint16 currencyId, address account) external view returns (int, int, uint);
    function getAccountPortfolio(address account) external view returns (PortfolioAsset[] memory);
    function getPerpetualTokenPortfolio(address tokenAddress) external view returns (PortfolioAsset[] memory, PortfolioAsset[] memory);
    function getifCashAssets(address account) external view returns (PortfolioAsset[] memory);
    function calculatePerpetualTokensToMint(uint16 currencyId, uint88 amountToDepositExternalPrecision) external view returns (uint);
    function getifCashNotional(address account, uint currencyId, uint maturity) external view returns (int);
    function getifCashBitmap(address account, uint currencyId) external view returns (bytes32);
    function getFreeCollateralView(address account) external view returns (int);
    function getIncentivesToMint(uint16 currencyId, uint perpetualTokenBalance, uint lastMintTime, uint blockTime) external view returns (uint);
}

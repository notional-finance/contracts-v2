// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../contracts/global/Types.sol";
import "./nTokenERC20.sol";

// TODO: split this proxy into smaller parts
interface NotionalProxy is nTokenERC20 {
    event ListCurrency(uint16 newCurrencyId);
    event UpdateETHRate(uint16 currencyId);
    event UpdateAssetRate(uint16 currencyId);
    event UpdateCashGroup(uint16 currencyId);
    event UpdateDepositParameters(uint16 currencyId);
    event UpdateInitializationParameters(uint16 currencyId);
    event UpdateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate);
    event UpdateTokenCollateralParameters(uint16 currencyId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /** User trading events */
    event CashBalanceChange(address indexed account, uint16 currencyId, int256 amount);
    event PerpetualTokenSupplyChange(address indexed account, uint16 currencyId, int256 amount);
    event AccountSettled(address indexed account);
    event BatchTradeExecution(address account, uint16 currencyId);
    // This is emitted from RedeemPerpetualTokenAction
    event nTokenRedeemed(address indexed redeemer, uint16 currencyId, uint96 tokensRedeemed);

    /** Initialize Markets Action */
    function initializeMarkets(uint256 currencyId, bool isFirstInit) external;

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

    function updateDepositParameters(
        uint16 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) external;

    function updateInitializationParameters(
        uint16 currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) external;

    function updateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate) external;

    function updateTokenCollateralParameters(
        uint16 currencyId,
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage
    ) external;

    function updateCashGroup(uint16 currencyId, CashGroupParameterStorage calldata cashGroup)
        external;

    function updateAssetRate(uint16 currencyId, address rateOracle) external;

    function updateETHRate(
        uint16 currencyId,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external;

    /** Redeem Perpetual Token Action */
    function nTokenRedeem(
        uint16 currencyId,
        uint88 tokensToRedeem_,
        bool sellTokenAssets
    ) external;

    /** Deposit Withdraw Action */
    function settleAccount(address account) external;

    function depositUnderlyingToken(
        address account,
        uint16 currencyId,
        uint256 amountExternalPrecision
    ) external payable returns (uint256);

    function depositAssetToken(
        address account,
        uint16 currencyId,
        uint256 amountExternalPrecision
    ) external returns (uint256);

    function withdraw(
        address account,
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external returns (uint256);

    function batchBalanceAction(address account, BalanceAction[] calldata actions) external payable;

    function batchBalanceAndTradeAction(address account, BalanceActionWithTrades[] calldata actions)
        external
        payable;

    /** Views */
    function getMaxCurrencyId() external view returns (uint16);

    function getCurrency(uint16 currencyId) external view returns (Token memory);

    function getUnderlying(uint16 currencyId) external view returns (Token memory);

    function getETHRateStorage(uint16 currencyId) external view returns (ETHRateStorage memory);

    function getETHRate(uint16 currencyId) external view returns (ETHRate memory);

    function getCurrencyAndRate(uint16 currencyId)
        external
        view
        returns (Token memory, ETHRate memory);

    function getCashGroup(uint16 currencyId)
        external
        view
        returns (CashGroupParameterStorage memory);

    function getAssetRateStorage(uint16 currencyId) external view returns (AssetRateStorage memory);

    function getAssetRate(uint16 currencyId) external view returns (AssetRateParameters memory);

    function getSettlementRate(uint16 currencyId, uint32 maturity)
        external
        view
        returns (AssetRateParameters memory);

    function getCashGroupAndRate(uint16 currencyId)
        external
        view
        returns (CashGroupParameterStorage memory, AssetRateParameters memory);

    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory);

    function getActiveMarketsAtBlockTime(uint16 currencyId, uint32 blockTime)
        external
        view
        returns (MarketParameters[] memory);

    function getInitializationParameters(uint16 currencyId)
        external
        view
        returns (int256[] memory, int256[] memory);

    function getPerpetualDepositParameters(uint16 currencyId)
        external
        view
        returns (int256[] memory, int256[] memory);

    function nTokenAddress(uint16 currencyId) external view returns (address);

    function getOwner() external view returns (address);

    function getAccountContext(address account) external view returns (AccountStorage memory);

    function getAccountBalance(uint16 currencyId, address account)
        external
        view
        returns (
            int256,
            int256,
            uint256
        );

    function getReserveBalance(uint16 currencyId) external view returns (int256);

    function getAccountPortfolio(address account) external view returns (PortfolioAsset[] memory);

    function getPerpetualTokenPortfolio(address tokenAddress)
        external
        view
        returns (PortfolioAsset[] memory, PortfolioAsset[] memory);

    function getifCashAssets(address account) external view returns (PortfolioAsset[] memory);

    function calculatePerpetualTokensToMint(
        uint16 currencyId,
        uint88 amountToDepositExternalPrecision
    ) external view returns (uint256);

    function getifCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) external view returns (int256);

    function getifCashBitmap(address account, uint256 currencyId) external view returns (bytes32);

    function getFreeCollateralView(address account) external view returns (int256);

    function getIncentivesToMint(
        uint16 currencyId,
        uint256 perpetualTokenBalance,
        uint256 lastMintTime,
        uint256 blockTime
    ) external view returns (uint256);

    function getfCashAmountGivenCashAmount(
        uint16 currencyId,
        int88 netCashToAccount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view returns (int256);

    function getCashAmountGivenfCashAmount(
        uint16 currencyId,
        int88 fCashAmount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view returns (int256, int256);
}

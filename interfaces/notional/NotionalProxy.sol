// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../contracts/global/Types.sol";
import "./nTokenERC20.sol";
import "./nERC1155Interface.sol";

// TODO: split this proxy into smaller parts
interface NotionalProxy is nTokenERC20, nERC1155Interface {
    event ListCurrency(uint16 newCurrencyId);
    event UpdateETHRate(uint16 currencyId);
    event UpdateAssetRate(uint16 currencyId);
    event UpdateCashGroup(uint16 currencyId);
    event UpdateDepositParameters(uint16 currencyId);
    event UpdateInitializationParameters(uint16 currencyId);
    event UpdateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate);
    event UpdateTokenCollateralParameters(uint16 currencyId);
    event UpdateGlobalTransferOperator(address operator, bool approved);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /** User trading events */
    event CashBalanceChange(address indexed account, uint16 currencyId, int256 netCashChange);
    event nTokenSupplyChange(address indexed account, uint16 currencyId, int256 tokenSupplyChange);
    event BatchTradeExecution(address account, uint16 currencyId);
    event SettledCashDebt(address settledAccount, uint16 currencyId, int256 amountToSettleAsset);
    event nTokenResidualPurchase(uint16 currencyId, uint40 maturity, int256 fCashAmountToPurchase);

    /// @notice Emitted whenever an account context has updated
    event AccountContextUpdate(address indexed account);
    /// @notice Emitted when an account has assets that are settled
    event AccountSettled(address indexed account);
    /// @notice Emitted when an asset rate is settled
    event SetSettlementRate(uint256 currencyId, uint256 maturity, uint128 rate);

    /* Liquidation Events */
    event LiquidateLocalCurrency(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        int256 netLocalFromLiquidator
    );

    event LiquidateCollateralCurrency(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        uint16 collateralCurrencyId,
        int256 netLocalFromLiquidator,
        int256 netCollateralTransfer,
        int256 netNTokenTransfer
    );

    event LiquidatefCashEvent(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        uint16 fCashCurrency,
        int256 netLocalFromLiquidator,
        uint256[] fCashMaturities,
        int256[] fCashNotionalTransfer
    );

    /** Initialize Markets Action */
    event MarketsInitialized(uint16 currencyId);

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
        CashGroupSettings calldata cashGroup,
        string calldata underlyingName,
        string calldata underlyingSymbol
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

    function updateCashGroup(uint16 currencyId, CashGroupSettings calldata cashGroup) external;

    function updateAssetRate(uint16 currencyId, address rateOracle) external;

    function updateETHRate(
        uint16 currencyId,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external;

    function updateGlobalTransferOperator(address operator, bool approved) external;

    /** Redeem nToken Action */
    function nTokenRedeem(
        address redeemer,
        uint16 currencyId,
        uint96 tokensToRedeem_,
        bool sellTokenAssets
    ) external;

    /** Account Action */
    function enableBitmapCurrency(uint16 currencyId) external;

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
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external returns (uint256);

    /** Batch Action */
    function batchBalanceAction(address account, BalanceAction[] calldata actions) external payable;

    function batchBalanceAndTradeAction(address account, BalanceActionWithTrades[] calldata actions)
        external
        payable;

    /** Liquidation Action */
    function calculateLocalCurrencyLiquidation(
        address liquidateAccount,
        uint256 localCurrency,
        uint96 maxNTokenLiquidation
    ) external returns (int256);

    function liquidateLocalCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint96 maxNTokenLiquidation
    ) external returns (int256);

    function calculateCollateralCurrencyLiquidation(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation
    )
        external
        returns (
            int256,
            int256,
            int256
        );

    function liquidateCollateralCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        bool withdrawCollateral,
        bool redeemToUnderlying
    )
        external
        returns (
            int256,
            int256,
            int256
        );

    function calculatefCashLocalLiquidation(
        address liquidateAccount,
        uint256 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external returns (int256[] memory, int256);

    function liquidatefCashLocal(
        address liquidateAccount,
        uint256 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external returns (int256[] memory, int256);

    function calculatefCashCrossCurrencyLiquidation(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external returns (int256[] memory, int256);

    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external returns (int256[] memory, int256);

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

    function getCashGroup(uint16 currencyId) external view returns (CashGroupSettings memory);

    function getAssetRateStorage(uint16 currencyId) external view returns (AssetRateStorage memory);

    function getAssetRate(uint16 currencyId) external view returns (AssetRateParameters memory);

    function getSettlementRate(uint16 currencyId, uint32 maturity)
        external
        view
        returns (AssetRateParameters memory);

    function getCashGroupAndRate(uint16 currencyId)
        external
        view
        returns (CashGroupSettings memory, AssetRateParameters memory);

    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory);

    function getActiveMarketsAtBlockTime(uint16 currencyId, uint32 blockTime)
        external
        view
        returns (MarketParameters[] memory);

    function getInitializationParameters(uint16 currencyId)
        external
        view
        returns (int256[] memory, int256[] memory);

    function getDepositParameters(uint16 currencyId)
        external
        view
        returns (int256[] memory, int256[] memory);

    function nTokenAddress(uint16 currencyId) external view returns (address);

    function getOwner() external view returns (address);

    function getAccountContext(address account) external view returns (AccountContext memory);

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

    function getNTokenPortfolio(address tokenAddress)
        external
        view
        returns (PortfolioAsset[] memory, PortfolioAsset[] memory);

    function calculateNTokensToMint(uint16 currencyId, uint88 amountToDepositExternalPrecision)
        external
        view
        returns (uint256);

    function getifCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) external view returns (int256);

    function getifCashBitmap(address account, uint256 currencyId) external view returns (bytes32);

    function getFreeCollateralView(address account) external view returns (int256, int256[] memory);

    function getIncentivesToMint(
        uint16 currencyId,
        uint256 nTokenBalance,
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

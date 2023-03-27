// SPDX-License-Identifier: BSUL-1.1
pragma solidity >=0.7.6;
pragma abicoder v2;

import "../../contracts/global/Deployments.sol";
import "../../contracts/global/Types.sol";
import "../../interfaces/chainlink/AggregatorV2V3Interface.sol";
import "../../interfaces/notional/NotionalGovernance.sol";
import "../../interfaces/notional/IRewarder.sol";
import "../../interfaces/aave/ILendingPool.sol";

interface NotionalGovernance {
    event ListCurrency(uint16 newCurrencyId);
    event UpdateETHRate(uint16 currencyId);
    event UpdateAssetRate(uint16 currencyId);
    event UpdateCashGroup(uint16 currencyId);
    event DeployNToken(uint16 currencyId, address nTokenAddress);
    event UpdateDepositParameters(uint16 currencyId);
    event UpdateInitializationParameters(uint16 currencyId);
    event UpdateTokenCollateralParameters(uint16 currencyId);
    event UpdateGlobalTransferOperator(address operator, bool approved);
    event UpdateAuthorizedCallbackContract(address operator, bool approved);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PauseRouterAndGuardianUpdated(address indexed pauseRouter, address indexed pauseGuardian);
    event UpdateSecondaryIncentiveRewarder(uint16 indexed currencyId, address rewarder);
    event UpdateLendingPool(address pool);
    event UpdateInterestRateCurve(uint16 indexed currencyId, uint8 indexed marketIndex);

    function transferOwnership(address newOwner, bool direct) external;

    function claimOwnership() external;

    function upgradeBeacon(Deployments.BeaconType proxy, address newBeacon) external;

    function setPauseRouterAndGuardian(address pauseRouter_, address pauseGuardian_) external;

    function listCurrency(
        TokenStorage calldata underlyingToken,
        ETHRateStorage memory ethRate,
        InterestRateCurveSettings calldata primeDebtCurve,
        IPrimeCashHoldingsOracle primeCashHoldingsOracle,
        bool allowPrimeCashDebt,
        uint8 rateOracleTimeWindow5Min,
        string calldata underlyingName,
        string calldata underlyingSymbol
    ) external returns (uint16 currencyId);

    function enableCashGroup(
        uint16 currencyId,
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
        uint32[] calldata annualizedAnchorRates,
        uint32[] calldata proportions
    ) external;


    function updateTokenCollateralParameters(
        uint16 currencyId,
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage
    ) external;

    function updateCashGroup(uint16 currencyId, CashGroupSettings calldata cashGroup) external;

    function updateInterestRateCurve(
        uint16 currencyId,
        uint8[] calldata marketIndices,
        InterestRateCurveSettings[] calldata settings
    ) external;

    function setMaxUnderlyingSupply(
        uint16 currencyId,
        uint256 maxUnderlyingSupply
    ) external;

    function updatePrimeCashHoldingsOracle(
        uint16 currencyId,
        IPrimeCashHoldingsOracle primeCashHoldingsOracle
    ) external;

    function updatePrimeCashCurve(
        uint16 currencyId,
        InterestRateCurveSettings calldata primeDebtCurve
    ) external;

    function enablePrimeDebt(
        uint16 currencyId,
        string calldata underlyingName,
        string calldata underlyingSymbol
    ) external;

    function updateETHRate(
        uint16 currencyId,
        AggregatorV2V3Interface rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external;

    function updateAuthorizedCallbackContract(address operator, bool approved) external;
}

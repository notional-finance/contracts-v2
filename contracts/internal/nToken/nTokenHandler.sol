// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./nTokenSupply.sol";
import "../markets/CashGroup.sol";
import "../markets/AssetRate.sol";
import "../portfolio/PortfolioHandler.sol";
import "../balances/BalanceHandler.sol";
import "../../global/LibStorage.sol";
import "../../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library nTokenHandler {
    using SafeInt256 for int256;

    /// @dev Mirror of the value in LibStorage, solidity compiler does not allow assigning
    /// two constants to each other.
    uint256 private constant NUM_NTOKEN_MARKET_FACTORS = 14;

    /// @notice Returns an account context object that is specific to nTokens.
    function getNTokenContext(address tokenAddress)
        internal
        view
        returns (
            uint16 currencyId,
            uint256 incentiveAnnualEmissionRate,
            uint256 lastInitializedTime,
            uint8 assetArrayLength,
            bytes5 parameters
        )
    {
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];

        currencyId = context.currencyId;
        incentiveAnnualEmissionRate = context.incentiveAnnualEmissionRate;
        lastInitializedTime = context.lastInitializedTime;
        assetArrayLength = context.assetArrayLength;
        parameters = context.nTokenParameters;
    }

    /// @notice Returns the nToken token address for a given currency
    function nTokenAddress(uint256 currencyId) internal view returns (address tokenAddress) {
        mapping(uint256 => address) storage store = LibStorage.getNTokenAddressStorage();
        return store[currencyId];
    }

    /// @notice Called by governance to set the nToken token address and its reverse lookup. Cannot be
    /// reset once this is set.
    function setNTokenAddress(uint16 currencyId, address tokenAddress) internal {
        mapping(uint256 => address) storage addressStore = LibStorage.getNTokenAddressStorage();
        require(addressStore[currencyId] == address(0), "PT: token address exists");

        mapping(address => nTokenContext) storage contextStore = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = contextStore[tokenAddress];
        require(context.currencyId == 0, "PT: currency exists");

        // This will initialize all other context slots to zero
        context.currencyId = currencyId;
        addressStore[currencyId] = tokenAddress;
    }

    /// @notice Set nToken token collateral parameters
    function setNTokenCollateralParameters(
        address tokenAddress,
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage
    ) internal {
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];

        require(liquidationHaircutPercentage <= Constants.PERCENTAGE_DECIMALS, "Invalid haircut");
        // The pv haircut percentage must be less than the liquidation percentage or else liquidators will not
        // get profit for liquidating nToken.
        require(pvHaircutPercentage < liquidationHaircutPercentage, "Invalid pv haircut");
        // Ensure that the cash withholding buffer is greater than the residual purchase incentive or
        // the nToken may not have enough cash to pay accounts to buy its negative ifCash
        require(residualPurchaseIncentive10BPS <= cashWithholdingBuffer10BPS, "Invalid discounts");

        bytes5 parameters =
            (bytes5(uint40(residualPurchaseIncentive10BPS)) |
            (bytes5(uint40(pvHaircutPercentage)) << 8) |
            (bytes5(uint40(residualPurchaseTimeBufferHours)) << 16) |
            (bytes5(uint40(cashWithholdingBuffer10BPS)) << 24) |
            (bytes5(uint40(liquidationHaircutPercentage)) << 32));

        // Set the parameters
        context.nTokenParameters = parameters;
    }

    /// @notice Sets a secondary rewarder contract on an nToken so that incentives can come from a different
    /// contract, aside from the native NOTE token incentives.
    function setSecondaryRewarder(
        uint16 currencyId,
        IRewarder rewarder
    ) internal {
        address tokenAddress = nTokenAddress(currencyId);
        // nToken must exist for a secondary rewarder
        require(tokenAddress != address(0));
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];

        // Setting the rewarder to address(0) will disable it. We use a context setting here so that
        // we can save a storage read before getting the rewarder
        context.hasSecondaryRewarder = (address(rewarder) != address(0));
        LibStorage.getSecondaryIncentiveRewarder()[tokenAddress] = rewarder;
    }

    /// @notice Returns the secondary rewarder if it is set
    function getSecondaryRewarder(address tokenAddress) internal view returns (IRewarder) {
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];
        
        if (context.hasSecondaryRewarder) {
            return LibStorage.getSecondaryIncentiveRewarder()[tokenAddress];
        } else {
            return IRewarder(address(0));
        }
    }

    function setArrayLengthAndInitializedTime(
        address tokenAddress,
        uint8 arrayLength,
        uint256 lastInitializedTime
    ) internal {
        require(lastInitializedTime >= 0 && uint256(lastInitializedTime) < type(uint32).max); // dev: next settle time overflow
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];
        context.lastInitializedTime = uint32(lastInitializedTime);
        context.assetArrayLength = arrayLength;
    }

    /// @notice Returns the array of deposit shares and leverage thresholds for nTokens
    function getDepositParameters(uint256 currencyId, uint256 maxMarketIndex)
        internal
        view
        returns (int256[] memory depositShares, int256[] memory leverageThresholds)
    {
        mapping(uint256 => uint32[NUM_NTOKEN_MARKET_FACTORS]) storage store = LibStorage.getNTokenDepositStorage();
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage depositParameters = store[currencyId];
        (depositShares, leverageThresholds) = _getParameters(depositParameters, maxMarketIndex, false);
    }

    /// @notice Sets the deposit parameters
    /// @dev We pack the values in alternating between the two parameters into either one or two
    // storage slots depending on the number of markets. This is to save storage reads when we use the parameters.
    function setDepositParameters(
        uint256 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) internal {
        require(
            depositShares.length <= Constants.MAX_TRADED_MARKET_INDEX,
            "PT: deposit share length"
        );
        require(depositShares.length == leverageThresholds.length, "PT: leverage share length");

        uint256 shareSum;
        for (uint256 i; i < depositShares.length; i++) {
            // This cannot overflow in uint 256 with 9 max slots
            shareSum = shareSum + depositShares[i];
            require(
                leverageThresholds[i] > 0 && leverageThresholds[i] < Constants.RATE_PRECISION,
                "PT: leverage threshold"
            );
        }

        // Total deposit share must add up to 100%
        require(shareSum == uint256(Constants.DEPOSIT_PERCENT_BASIS), "PT: deposit shares sum");

        mapping(uint256 => uint32[NUM_NTOKEN_MARKET_FACTORS]) storage store = LibStorage.getNTokenDepositStorage();
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage depositParameters = store[currencyId];
        _setParameters(depositParameters, depositShares, leverageThresholds);
    }

    /// @notice Sets the initialization parameters for the markets, these are read only when markets
    /// are initialized
    function setInitializationParameters(
        uint256 currencyId,
        uint32[] calldata annualizedAnchorRates,
        uint32[] calldata proportions
    ) internal {
        require(annualizedAnchorRates.length <= Constants.MAX_TRADED_MARKET_INDEX, "PT: annualized anchor rates length");
        require(proportions.length == annualizedAnchorRates.length, "PT: proportions length");

        for (uint256 i; i < proportions.length; i++) {
            // Proportions must be between zero and the rate precision
            require(annualizedAnchorRates[i] > 0, "NT: anchor rate zero");
            require(
                proportions[i] > 0 && proportions[i] < Constants.RATE_PRECISION,
                "PT: invalid proportion"
            );
        }

        mapping(uint256 => uint32[NUM_NTOKEN_MARKET_FACTORS]) storage store = LibStorage.getNTokenInitStorage();
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage initParameters = store[currencyId];
        _setParameters(initParameters, annualizedAnchorRates, proportions);
    }

    /// @notice Returns the array of initialization parameters for a given currency.
    function getInitializationParameters(uint256 currencyId, uint256 maxMarketIndex)
        internal
        view
        returns (int256[] memory annualizedAnchorRates, int256[] memory proportions)
    {
        mapping(uint256 => uint32[NUM_NTOKEN_MARKET_FACTORS]) storage store = LibStorage.getNTokenInitStorage();
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage initParameters = store[currencyId];
        (annualizedAnchorRates, proportions) = _getParameters(initParameters, maxMarketIndex, true);
    }

    function _getParameters(
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage slot,
        uint256 maxMarketIndex,
        bool noUnset
    ) private view returns (int256[] memory, int256[] memory) {
        uint256 index = 0;
        int256[] memory array1 = new int256[](maxMarketIndex);
        int256[] memory array2 = new int256[](maxMarketIndex);
        for (uint256 i; i < maxMarketIndex; i++) {
            array1[i] = slot[index];
            index++;
            array2[i] = slot[index];
            index++;

            if (noUnset) {
                require(array1[i] > 0 && array2[i] > 0, "PT: init value zero");
            }
        }

        return (array1, array2);
    }

    function _setParameters(
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage slot,
        uint32[] calldata array1,
        uint32[] calldata array2
    ) private {
        uint256 index = 0;
        for (uint256 i = 0; i < array1.length; i++) {
            slot[index] = array1[i];
            index++;

            slot[index] = array2[i];
            index++;
        }
    }

    function loadNTokenPortfolioNoCashGroup(nTokenPortfolio memory nToken, uint16 currencyId)
        internal
        view
    {
        nToken.tokenAddress = nTokenAddress(currencyId);
        // prettier-ignore
        (
            /* currencyId */,
            /* incentiveRate */,
            uint256 lastInitializedTime,
            uint8 assetArrayLength,
            bytes5 parameters
        ) = getNTokenContext(nToken.tokenAddress);

        // prettier-ignore
        (
            uint256 totalSupply,
            /* accumulatedNOTEPerNToken */,
            /* lastAccumulatedTime */
        ) = nTokenSupply.getStoredNTokenSupplyFactors(nToken.tokenAddress);

        nToken.lastInitializedTime = lastInitializedTime;
        nToken.totalSupply = int256(totalSupply);
        nToken.parameters = parameters;

        nToken.portfolioState = PortfolioHandler.buildPortfolioState(
            nToken.tokenAddress,
            assetArrayLength,
            0
        );

        // prettier-ignore
        (
            nToken.cashBalance,
            /* nTokenBalance */,
            /* lastClaimTime */,
            /* accountIncentiveDebt */
        ) = BalanceHandler.getBalanceStorage(nToken.tokenAddress, currencyId);
    }

    /// @notice Uses buildCashGroupStateful
    function loadNTokenPortfolioStateful(nTokenPortfolio memory nToken, uint16 currencyId)
        internal
    {
        loadNTokenPortfolioNoCashGroup(nToken, currencyId);
        nToken.cashGroup = CashGroup.buildCashGroupStateful(currencyId);
    }

    /// @notice Uses buildCashGroupView
    function loadNTokenPortfolioView(nTokenPortfolio memory nToken, uint16 currencyId)
        internal
        view
    {
        loadNTokenPortfolioNoCashGroup(nToken, currencyId);
        nToken.cashGroup = CashGroup.buildCashGroupView(currencyId);
    }

    /// @notice Returns the next settle time for the nToken which is 1 quarter away
    function getNextSettleTime(nTokenPortfolio memory nToken) internal pure returns (uint256) {
        if (nToken.lastInitializedTime == 0) return 0;
        return DateTime.getReferenceTime(nToken.lastInitializedTime) + Constants.QUARTER;
    }

}

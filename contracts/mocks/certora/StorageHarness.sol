// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../external/actions/GovernanceAction.sol";
import "../../internal/valuation/ExchangeRate.sol";
import "../../internal/markets/CashGroup.sol";
import "../../internal/nTokenHandler.sol";
import "../../internal/AccountContextHandler.sol";
import "../../math/SafeInt256.sol";

contract StorageHarness is GovernanceAction {
    using SafeInt256 for int256;

    function getMaxCurrencyId() external view returns (uint16) {
        return maxCurrencyId;
    }

    function listCurrencyHarness(
        address assetToken,
        bool assetTokenHasFee,
        TokenType assetTokenType,
        address underlyingToken,
        bool underlyingTokenHasFee,
        TokenType underlyingTokenType,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external {
        this.listCurrency(
            TokenStorage(assetToken, assetTokenHasFee, assetTokenType),
            TokenStorage(underlyingToken, underlyingTokenHasFee, underlyingTokenType),
            rateOracle,
            mustInvert,
            buffer,
            haircut,
            liquidationDiscount
        );
    }

    function getToken(uint16 currencyId, bool isUnderlying)
        external
        view
        returns (
            address tokenAddress,
            bool hasTransferFee,
            int256 decimals,
            uint8 tokenType
        )
    {
        Token memory t = TokenHandler.getToken(currencyId, isUnderlying);
        return (t.tokenAddress, t.hasTransferFee, t.decimals, uint8(t.tokenType));
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function getNTokenAccount(address tokenAddress)
        external
        view
        returns (
            uint256 currencyId,
            uint256 totalSupply,
            uint256 incentiveAnnualEmissionRate,
            uint256 lastInitializedTime,
            bytes6 nTokenParameters,
            uint256 integralTotalSupply,
            uint256 lastSupplyChangeTime
        )
    {
        (
            currencyId,
            incentiveAnnualEmissionRate,
            lastInitializedTime,
            nTokenParameters
        ) = nTokenHandler.getNTokenContext(tokenAddress);

        // prettier-ignore
        (
            totalSupply,
            integralTotalSupply,
            lastSupplyChangeTime
        ) = nTokenHandler.getStoredNTokenSupplyFactors(tokenAddress);
    }

    function nTokenAddress(uint16 currencyId) external view returns (address) {
        return nTokenHandler.nTokenAddress(currencyId);
    }

    function getNTokenParameters(address tokenAddress)
        external
        view
        returns (
            uint8,
            uint8,
            uint8,
            uint8,
            uint8,
            uint8,
            uint256,
            uint256,
            uint256
        )
    {
        // prettier-ignore
        (
            uint256 currencyId,
            uint256 incentiveAnnualEmissionRate,
            uint256 lastInitializedTime,
            bytes6 nTokenParameters
        ) = nTokenHandler.getNTokenContext(tokenAddress);

        return (
            uint8(nTokenParameters[Constants.RESIDUAL_PURCHASE_INCENTIVE]),
            uint8(nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]),
            uint8(nTokenParameters[Constants.RESIDUAL_PURCHASE_TIME_BUFFER]),
            uint8(nTokenParameters[Constants.CASH_WITHHOLDING_BUFFER]),
            uint8(nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]),
            uint8(nTokenParameters[Constants.ASSET_ARRAY_LENGTH]),
            currencyId,
            incentiveAnnualEmissionRate,
            lastInitializedTime
        );
    }

    function setArrayLengthAndInitializedTime(
        address tokenAddress,
        uint8 arrayLength,
        uint256 lastInitializedTime
    ) public {
        nTokenHandler.setArrayLengthAndInitializedTime(
            tokenAddress,
            arrayLength,
            lastInitializedTime
        );
    }

    function changeNTokenSupply(
        address tokenAddress,
        int256 netChange,
        uint256 blockTime
    ) public returns (uint256) {
        return nTokenHandler.changeNTokenSupply(tokenAddress, netChange, blockTime);
    }

    function addIsEqual(
        uint256 totalSupply,
        int256 netChange,
        uint256 totalSupplyAfter
    ) public view returns (bool) {
        require(totalSupply < uint256(type(int256).max));
        require(totalSupplyAfter < uint256(type(int256).max));
        int256 newTotalSupply = int256(totalSupply).add(netChange);
        return int256(totalSupplyAfter) == newTotalSupply;
    }

    function verifyDepositParameters(
        uint16 currencyId,
        uint32[] memory _depositShares,
        uint32[] memory _leverageThresholds
    ) external view returns (bool) {
        (int256[] memory depositShares, int256[] memory leverageThresholds) = nTokenHandler
            .getDepositParameters(currencyId, 7);

        for (uint256 i; i < _depositShares.length; i++) {
            if (depositShares[i] != int256(_depositShares[i])) return false;
            if (leverageThresholds[i] != int256(_leverageThresholds[i])) return false;
        }

        return true;
    }

    function verifyInitializationParameters(
        uint16 currencyId,
        uint32[] memory _annualizedAnchorRates,
        uint32[] memory _proportions
    ) external view returns (bool) {
        (int256[] memory annualizedAnchorRates, int256[] memory proportions) = nTokenHandler
            .getInitializationParameters(currencyId, 7);

        for (uint256 i; i < _annualizedAnchorRates.length; i++) {
            if (annualizedAnchorRates[i] != int256(_annualizedAnchorRates[i])) return false;
            if (proportions[i] != int256(_proportions[i])) return false;
        }

        return true;
    }

    function setCashGroupStorageAndVerify(
        uint16 currencyId,
        uint8 maxMarketIndex,
        uint8 rateOracleTimeWindowMin,
        uint8 totalFeeBPS,
        uint8 reserveFeeShare,
        uint8 debtBuffer5BPS,
        uint8 fCashHaircut5BPS,
        uint8 settlementPenaltyRate5BPS,
        uint8 liquidationfCashHaircut5BPS,
        uint8 liquidationDebtBuffer5BPS,
        uint8[] memory liquidityTokenHaircuts,
        uint8[] memory rateScalars
    ) external returns (bool) {
        CashGroupSettings memory s = CashGroupSettings(
            maxMarketIndex,
            rateOracleTimeWindowMin,
            totalFeeBPS,
            reserveFeeShare,
            debtBuffer5BPS,
            fCashHaircut5BPS,
            settlementPenaltyRate5BPS,
            liquidationfCashHaircut5BPS,
            liquidationDebtBuffer5BPS,
            liquidityTokenHaircuts,
            rateScalars
        );
        this.updateCashGroup(currencyId, s);

        CashGroupSettings memory _s = CashGroup.deserializeCashGroupStorage(currencyId);

        if (s.maxMarketIndex != _s.maxMarketIndex) return false;
        if (s.rateOracleTimeWindowMin != _s.rateOracleTimeWindowMin) return false;
        if (s.totalFeeBPS != _s.totalFeeBPS) return false;
        if (s.reserveFeeShare != _s.reserveFeeShare) return false;
        if (s.debtBuffer5BPS != _s.debtBuffer5BPS) return false;
        if (s.fCashHaircut5BPS != _s.fCashHaircut5BPS) return false;
        if (s.settlementPenaltyRate5BPS != _s.settlementPenaltyRate5BPS) return false;
        if (s.liquidationfCashHaircut5BPS != _s.liquidationfCashHaircut5BPS) return false;
        if (s.liquidationDebtBuffer5BPS != _s.liquidationDebtBuffer5BPS) return false;
        if (liquidityTokenHaircuts.length != rateScalars.length) return false;

        for (uint256 i; i < liquidityTokenHaircuts.length; i++) {
            if (liquidityTokenHaircuts[i] != _s.liquidityTokenHaircuts[i]) return false;
        }

        for (uint256 i; i < rateScalars.length; i++) {
            if (rateScalars[i] != _s.rateScalars[i]) return false;
        }

        return true;
    }

    function getETHRate(uint16 currencyId)
        external
        view
        returns (
            int256,
            int256,
            uint8,
            uint8,
            uint8
        )
    {
        ETHRate memory er = ExchangeRate.buildExchangeRate(currencyId);
        require(0 < er.buffer && er.buffer < 255);
        require(0 < er.haircut && er.haircut < 255);
        require(0 < er.liquidationDiscount && er.liquidationDiscount < 255);

        return (
            er.rateDecimals,
            er.rate,
            uint8(uint256(er.buffer)),
            uint8(uint256(er.haircut)),
            uint8(uint256(er.liquidationDiscount))
        );
    }

    function getAssetRate(uint16 currencyId)
        external
        returns (
            address rateOracle,
            int256 rate,
            int256 underlyingDecimalPlaces
        )
    {
        AssetRateParameters memory ar = AssetRate.buildAssetRateStateful(currencyId);

        return (ar.rateOracle, ar.rate, ar.underlyingDecimals);
    }

    function verifySetAccountContext(address account, AccountContext memory accountContext)
        public
        returns (bool)
    {
        AccountContextHandler.setAccountContext(accountContext, account);
        AccountContext memory ac = AccountContextHandler.getAccountContext(account);

        if (ac.nextSettleTime != accountContext.nextSettleTime) return false;
        if (ac.hasDebt != accountContext.hasDebt) return false;
        if (ac.assetArrayLength != accountContext.assetArrayLength) return false;
        if (ac.activeCurrencies != accountContext.activeCurrencies) return false;

        return true;
    }

    function setAssetsBitmap(
        address account,
        uint256 currencyId,
        bytes32 bitmap
    ) external {
        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, bitmap);
    }

    function getAssetsBitmap(address account, uint256 currencyId) external view returns (bytes32) {
        return BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
    }

    function setifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 nextSettleTime,
        int256 notional
    ) external returns (int256) {
        bytes32 bitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
        (bytes32 newBitmap, int256 finalNotional) = BitmapAssetsHandler.addifCashAsset(
            account,
            currencyId,
            maturity,
            nextSettleTime,
            notional,
            bitmap
        );
        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, newBitmap);

        return finalNotional;
    }

    function verifyfCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity,
        int256 notional
    ) external view returns (bool) {
        return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity) == notional;
    }
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../storage/StorageLayoutV1.sol";

contract MockPerpetualToken is StorageLayoutV1 {

    function getPerpetualTokenCurrencyIdAndSupply(
        address tokenAddress
    ) external view returns (uint, uint, uint) {
        (
            uint currencyId,
            uint totalSupply,
            uint incentiveRate
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(tokenAddress);
        assert(PerpetualToken.getPerpetualTokenAddress(currencyId) == tokenAddress);

        return (currencyId, totalSupply, incentiveRate);
    }

    function getPerpetualTokenAddress(
        uint currencyId
    ) external view returns (address) {
        address tokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        (
            uint currencyIdStored,
            /* uint totalSupply */,
            /* incentiveRate */
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(tokenAddress);
        assert(currencyIdStored == currencyId);

        return tokenAddress;
    }

    function setPerpetualTokenAddress(
        uint16 currencyId,
        address tokenAddress
    ) external {
        PerpetualToken.setPerpetualTokenAddress(currencyId, tokenAddress);

        // Test the assertions
        this.getPerpetualTokenAddress(currencyId);
        this.getPerpetualTokenCurrencyIdAndSupply(tokenAddress);
    }

    function getDepositParameters(
        uint currencyId,
        uint maxMarketIndex
    ) external view returns (int[] memory, int[] memory) {
        return PerpetualToken.getDepositParameters(currencyId, maxMarketIndex);
    }

    function setDepositParameters(
        uint currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) external {
        PerpetualToken.setDepositParameters(currencyId, depositShares, leverageThresholds);
    }

    function getInitializationParameters(
        uint currencyId,
        uint maxMarketIndex
    ) external view returns (int[] memory, int[] memory) {
        return PerpetualToken.getInitializationParameters(currencyId, maxMarketIndex);
    }

    function setInitializationParameters(
        uint currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) external {
        PerpetualToken.setInitializationParameters(currencyId, rateAnchors, proportions);
    }

    function getPerpetualTokenPV(
        uint currencyId,
        uint blockTime
    ) external view returns (int) {
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioView(
            currencyId
        );

        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(perpToken.tokenAddress);

        (int assetPv, /* ifCashBitmap */ ) = PerpetualToken.getPerpetualTokenPV(
            perpToken,
            accountContext,
            blockTime
        );

        return assetPv;
    }

    function calculateTokensToMint(
        uint currencyId,
        int assetCashDeposit,
        uint blockTime
    ) external view returns (int) {
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioView(
            currencyId
        );

        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(perpToken.tokenAddress);

        (int assetPv, /* ifCashBitmap */ ) = PerpetualToken.calculateTokensToMint(
            perpToken,
            accountContext,
            assetCashDeposit,
            blockTime
        );

        return assetPv;
    }

    function mintPerpetualToken(
        uint currencyId,
        int assetCashDeposit,
        uint blockTime
    ) external returns (int) {
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(
            currencyId
        );
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(perpToken.tokenAddress);
        AssetStorage[] storage perpTokenAssetStorage = assetArrayMapping[perpToken.tokenAddress];

        return PerpetualToken.mintPerpetualToken(
            perpToken,
            accountContext,
            assetCashDeposit,
            blockTime,
            perpTokenAssetStorage
        );
    }
}
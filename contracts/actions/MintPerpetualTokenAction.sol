// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/BalanceHandler.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MintPerpetualTokenAction is StorageLayoutV1, ReentrancyGuard {
    using SafeInt256 for int256;
    using BalanceHandler for BalanceState;

    /**
     * @notice Converts the given amount of cash to perpetual tokens in the same currency. This method can
     * only be called by the contract itself.
     */
    function perpetualTokenMintViaBatch(
        uint16 currencyId,
        uint88 amountToDepositInternal
    ) external nonReentrant returns (int) {
        require(msg.sender == address(this), "Unauthorized caller");
        uint blockTime = block.timestamp;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(currencyId);
        AccountStorage memory perpTokenContext = AccountContextHandler.getAccountContext(perpToken.tokenAddress);
        // TODO: make this a library and fetch these
        AssetStorage[] storage perpTokenAssetStorage = assetArrayMapping[perpToken.tokenAddress];

        int tokensMinted = PerpetualToken.mintPerpetualToken(
            perpToken,
            perpTokenContext,
            amountToDepositInternal,
            blockTime,
            perpTokenAssetStorage
        );
        require(tokensMinted >= 0, "Invalid token amount");

        return tokensMinted;
    }
}

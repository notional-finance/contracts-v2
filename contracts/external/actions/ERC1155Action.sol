// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./BatchAction.sol";
import "./nTokenRedeemAction.sol";
import "../FreeCollateralExternal.sol";
import "../../global/StorageLayoutV1.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/portfolio/TransferAssets.sol";
import "interfaces/IERC1155TokenReceiver.sol";
import "interfaces/notional/nERC1155Interface.sol";

contract ERC1155Action is nERC1155Interface, StorageLayoutV1 {
    using AccountContextHandler for AccountContext;

    // bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))
    bytes4 internal constant ERC1155_ACCEPTED = 0xf23a6e61;
    // bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))
    bytes4 internal constant ERC1155_BATCH_ACCEPTED = 0xbc197c81;
    bytes4 internal constant ERC1155_INTERFACE = 0xd9b67a26;

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == ERC1155_INTERFACE;
    }

    function balanceOf(address account, uint256 id) external view override returns (uint256) {}

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        override
        returns (uint256[] memory)
    {}

    /// @notice Transfer of a single fCash or liquidity token asset between accounts. Allows `from` account to transfer more fCash
    /// than they have as long as they pass a subsequent free collateral check. This enables OTC trading of fCash assets.
    /// @param from account to transfer from
    /// @param to account to transfer to
    /// @param id ERC1155 id of the asset
    /// @param amount amount to transfer
    /// @param data arbitratry data passed to ERC1155Receiver (if contract) and if properly specified can be used to initiate
    /// a trading action on Notional for the `from` address
    /// @dev emit:TransferSingle
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external override {
        require(amount <= uint256(type(int256).max)); // dev: int overflow
        _validateAccounts(from, to);

        PortfolioAsset[] memory assets = new PortfolioAsset[](1);
        (assets[0].currencyId, assets[0].maturity, assets[0].assetType) = TransferAssets
            .decodeAssetId(id);
        assets[0].notional = int256(amount);
        _assertValidMaturity(assets[0].currencyId, assets[0].maturity, block.timestamp);

        AccountContext memory fromContext = _transfer(from, to, assets);

        emit TransferSingle(msg.sender, from, to, id, amount);

        // If code size > 0 call onERC1155received
        uint256 codeSize;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            codeSize := extcodesize(to)
        }
        if (codeSize > 0) {
            require(
                IERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, id, amount, data) ==
                    ERC1155_ACCEPTED,
                "Not accepted"
            );
        }

        _checkPostTransferEvent(from, fromContext, data);
    }

    /// @notice Transfer of a batch of fCash or liquidity token assets between accounts. Allows `from` account to transfer more fCash
    /// than they have as long as they pass a subsequent free collateral check. This enables OTC trading of fCash assets.
    /// @param from account to transfer from
    /// @param to account to transfer to
    /// @param ids ERC1155 ids of the assets
    /// @param amounts amounts to transfer
    /// @param data arbitratry data passed to ERC1155Receiver (if contract) and if properly specified can be used to initiate
    /// a trading action on Notional for the `from` address
    /// @dev emit:TransferBatch
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external override {
        _validateAccounts(from, to);

        PortfolioAsset[] memory assets = decodeToAssets(ids, amounts);
        AccountContext memory fromContext = _transfer(from, to, assets);

        emit TransferBatch(msg.sender, from, to, ids, amounts);

        // If code size > 0 call onERC1155received
        uint256 codeSize;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            codeSize := extcodesize(to)
        }
        if (codeSize > 0) {
            require(
                IERC1155TokenReceiver(to).onERC1155BatchReceived(
                    msg.sender,
                    from,
                    ids,
                    amounts,
                    data
                ) == ERC1155_BATCH_ACCEPTED,
                "Not accepted"
            );
        }

        _checkPostTransferEvent(from, fromContext, data);
    }

    /// @dev Validates accounts on transfer
    function _validateAccounts(address from, address to) private view {
        require(from != to && to != address(0), "Invalid address");
        require(msg.sender == from || isApprovedForAll(from, msg.sender), "Unauthorized");
        _assertNotNToken(from);
        _assertNotNToken(to);
    }

    /// @dev Ensures that transfers to not occur to the nToken
    function _assertNotNToken(address account) private view {
        // prettier-ignore
        (
            uint256 currencyId,
            /* uint totalSupply */,
            /* incentiveRate */,
            /* lastInitializedTime */,
            /* parameters */
        ) = nTokenHandler.getNTokenContext(account);
        require(currencyId == 0, "Cannot transfer to nToken");
    }

    /// @notice Decodes ids and amounts to PortfolioAsset objects
    /// @param ids array of ERC1155 ids
    /// @param amounts amounts to transfer
    /// @return array of portfolio asset objects
    function decodeToAssets(uint256[] calldata ids, uint256[] calldata amounts)
        public
        view
        override
        returns (PortfolioAsset[] memory)
    {
        uint256 blockTime = block.timestamp;
        PortfolioAsset[] memory assets = new PortfolioAsset[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            (assets[i].currencyId, assets[i].maturity, assets[i].assetType) = TransferAssets
                .decodeAssetId(ids[i]);

            require(amounts[i] <= uint256(type(int256).max)); // dev: int overflow
            _assertValidMaturity(assets[i].currencyId, assets[i].maturity, blockTime);
            assets[i].notional = int256(amounts[i]);
        }

        return assets;
    }

    /// @notice Encodes parameters into an ERC1155 id
    /// @param currencyId currency id of the asset
    /// @param maturity timestamp of the maturity
    /// @param assetType id of the asset type
    /// @return ERC1155 id
    function encodeToId(
        uint16 currencyId,
        uint40 maturity,
        uint8 assetType
    ) external pure override returns (uint256) {
        return TransferAssets.encodeAssetId(currencyId, maturity, assetType);
    }

    /// @dev Ensures that all maturities specified are valid for the currency id (i.e. they do not
    /// go past the max maturity date)
    function _assertValidMaturity(
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) private view {
        require(
            DateTime.isValidMaturity(CashGroup.getMaxMarketIndex(currencyId), maturity, blockTime),
            "Invalid maturity"
        );
    }

    /// @dev Internal asset transfer event between accounts
    function _transfer(
        address from,
        address to,
        PortfolioAsset[] memory assets
    ) internal returns (AccountContext memory) {
        AccountContext memory fromContext = AccountContextHandler.getAccountContext(from);
        AccountContext memory toContext = AccountContextHandler.getAccountContext(to);

        TransferAssets.placeAssetsInAccount(to, toContext, assets);
        TransferAssets.invertNotionalAmountsInPlace(assets);
        TransferAssets.placeAssetsInAccount(from, fromContext, assets);

        toContext.setAccountContext(to);
        fromContext.setAccountContext(from);

        return fromContext;
    }

    /// @dev Checks post transfer events which will either be initiating one of the batch trading events or a free collateral
    /// check if required.
    function _checkPostTransferEvent(
        address from,
        AccountContext memory fromContext,
        bytes calldata data
    ) internal {
        bytes4 sig;
        if (data.length >= 32) {
            // Method signature is not abi encoded so decode to bytes32 first and take the first 4 bytes. This works
            // because all the methods we want to call below require more than 32 bytes in the calldata
            bytes32 tmp = abi.decode(data, (bytes32));
            sig = bytes4(tmp);
        }

        // These are the only three methods allowed to occur in a post transfer event. These actions allow `from`
        // accounts to take any sort of trading action as a result of their transfer. All of these actions will
        // handle checking free collateral so no additional check is necessary here.
        if (
            sig == nTokenRedeemAction.nTokenRedeem.selector ||
            sig == BatchAction.batchBalanceAction.selector ||
            sig == BatchAction.batchBalanceAndTradeAction.selector
        ) {
            // Ensure that the "account" parameter of the call is set to the from address
            require(abi.decode(data[4:36], (address)) == from, "Unauthorized call");
            (bool status, ) = address(this).delegatecall(data);
            require(status, "Call failed");
        } else if (fromContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(from);
        }
    }

    /// @notice Allows an account to set approval for an operator
    /// @param operator address of the operator
    /// @param approved state of the approval
    /// @dev emit:ApprovalForAll
    function setApprovalForAll(address operator, bool approved) external override {
        accountAuthorizedTransferOperator[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @notice Checks approval state for an account, will first check if global transfer operator is enabled
    /// before falling through to an account specific transfer operator.
    /// @param account address of the account
    /// @param operator address of the operator
    /// @return true for approved
    function isApprovedForAll(address account, address operator)
        public
        view
        override
        returns (bool)
    {
        if (globalTransferOperator[operator]) return true;

        return accountAuthorizedTransferOperator[account][operator];
    }
}

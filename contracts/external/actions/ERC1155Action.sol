// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./ActionGuards.sol";
import "../FreeCollateralExternal.sol";
import "../../global/StorageLayoutV1.sol";
import "../../math/SafeInt256.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/portfolio/TransferAssets.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../../interfaces/notional/NotionalProxy.sol";
import "../../../interfaces/IERC1155TokenReceiver.sol";
import "../../../interfaces/notional/nERC1155Interface.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract ERC1155Action is nERC1155Interface, ActionGuards {
    using SafeInt256 for int256;
    using AccountContextHandler for AccountContext;

    bytes4 internal constant ERC1155_ACCEPTED = bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    bytes4 internal constant ERC1155_BATCH_ACCEPTED = bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155).interfaceId;
    }

    /// @notice Returns the balance of an ERC1155 id on an account. WARNING: the balances returned by
    /// this method do not show negative fCash balances because only unsigned integers are returned. They
    /// are represented by zero here. Use `signedBalanceOf` to get a signed return value.
    /// @param account account to get the id for
    /// @param id the ERC1155 id
    /// @return Balance of the ERC1155 id as an unsigned integer (negative fCash balances return zero)
    function balanceOf(address account, uint256 id) public view override returns (uint256) {
        int256 notional = signedBalanceOf(account, id);
        return notional < 0 ? 0 : notional.toUint();
    }

    /// @notice Returns the balance of an ERC1155 id on an account.
    /// @param account account to get the id for
    /// @param id the ERC1155 id
    /// @return notional balance of the ERC1155 id as a signed integer
    function signedBalanceOf(address account, uint256 id) public view override returns (int256 notional) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);

        if (accountContext.isBitmapEnabled()) {
            notional = _balanceInBitmap(account, accountContext.bitmapCurrencyId, id);
        } else {
            notional = _balanceInArray(
                PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength),
                id
            );
        }
    }

    /// @notice Returns the balance of a batch of accounts and ids.
    /// @param accounts array of accounts to get balances for
    /// @param ids array of ids to get balances for
    /// @return Returns an array of signed balances
    function signedBalanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        override
        returns (int256[] memory)
    {
        require(accounts.length == ids.length);
        int256[] memory amounts = new int256[](accounts.length);

        for (uint256 i; i < accounts.length; i++) {
            // This is pretty inefficient but gets the job done
            amounts[i] = signedBalanceOf(accounts[i], ids[i]);
        }

        return amounts;
    }

    /// @notice Returns the balance of a batch of accounts and ids. WARNING: negative fCash balances are represented
    /// as zero balances in the array. 
    /// @param accounts array of accounts to get balances for
    /// @param ids array of ids to get balances for
    /// @return Returns an array of unsigned balances
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        override
        returns (uint256[] memory)
    {
        require(accounts.length == ids.length);
        uint256[] memory amounts = new uint256[](accounts.length);

        for (uint256 i; i < accounts.length; i++) {
            // This is pretty inefficient but gets the job done
            amounts[i] = balanceOf(accounts[i], ids[i]);
        }

        return amounts;
    }

    /// @dev Returns the balance from a bitmap given the id
    function _balanceInBitmap(
        address account,
        uint256 bitmapCurrencyId,
        uint256 id
    ) internal view returns (int256) {
        (uint256 currencyId, uint256 maturity, uint256 assetType) = TransferAssets.decodeAssetId(id);

        if (
            currencyId != bitmapCurrencyId ||
            assetType != Constants.FCASH_ASSET_TYPE
        ) {
            // Neither of these are possible for a bitmap group
            return 0;
        } else {
            return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity);
        }
    }

    /// @dev Searches an array for the matching asset
    function _balanceInArray(PortfolioAsset[] memory portfolio, uint256 id)
        internal
        pure
        returns (int256)
    {
        (uint256 currencyId, uint256 maturity, uint256 assetType) = TransferAssets.decodeAssetId(id);

        for (uint256 i; i < portfolio.length; i++) {
            PortfolioAsset memory asset = portfolio[i];
            if (
                asset.currencyId == currencyId &&
                asset.maturity == maturity &&
                asset.assetType == assetType
            ) return asset.notional;
        }
    }

    /// @notice Transfer of a single fCash or liquidity token asset between accounts. Allows `from` account to transfer more fCash
    /// than they have as long as they pass a subsequent free collateral check. This enables OTC trading of fCash assets.
    /// @param from account to transfer from
    /// @param to account to transfer to
    /// @param id ERC1155 id of the asset
    /// @param amount amount to transfer
    /// @param data arbitrary data passed to ERC1155Receiver (if contract) and if properly specified can be used to initiate
    /// a trading action on Notional for the `from` address
    /// @dev emit:TransferSingle, emit:AccountContextUpdate, emit:AccountSettled
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external payable override {
        // NOTE: there is no re-entrancy guard on this method because that would prevent a callback in 
        // _checkPostTransferEvent. The external call to the receiver is done at the very end after all stateful
        // updates have occurred.
        _validateAccounts(from, to);

        // When amount is set to zero this method can be used as a way to execute trades via a transfer operator
        AccountContext memory fromContext;
        if (amount > 0) {
            PortfolioAsset[] memory assets = new PortfolioAsset[](1);
            PortfolioAsset memory asset = assets[0];

            (asset.currencyId, asset.maturity, asset.assetType) = TransferAssets.decodeAssetId(id);
            // This ensures that asset.notional is always a positive amount
            asset.notional = SafeInt256.toInt(amount);
            _requireValidMaturity(asset.currencyId, asset.maturity, block.timestamp);

            // prettier-ignore
            (fromContext, /* toContext */) = _transfer(from, to, assets);

            emit TransferSingle(msg.sender, from, to, id, amount);
        } else {
            fromContext = AccountContextHandler.getAccountContext(from);
        }

        // toContext is always empty here because we cannot have bidirectional transfers in `safeTransferFrom`
        AccountContext memory toContext;
        _checkPostTransferEvent(from, to, fromContext, toContext, data, false);

        // Do this external call at the end to prevent re-entrancy
        if (Address.isContract(to)) {
            require(
                IERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, id, amount, data) ==
                    ERC1155_ACCEPTED,
                "Not accepted"
            );
        }
    }

    /// @notice Transfer of a batch of fCash or liquidity token assets between accounts. Allows `from` account to transfer more fCash
    /// than they have as long as they pass a subsequent free collateral check. This enables OTC trading of fCash assets.
    /// @param from account to transfer from
    /// @param to account to transfer to
    /// @param ids ERC1155 ids of the assets
    /// @param amounts amounts to transfer
    /// @param data arbitrary data passed to ERC1155Receiver (if contract) and if properly specified can be used to initiate
    /// a trading action on Notional for the `from` address
    /// @dev emit:TransferBatch, emit:AccountContextUpdate, emit:AccountSettled
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external payable override {
        // NOTE: there is no re-entrancy guard on this method because that would prevent a callback in 
        // _checkPostTransferEvent. The external call to the receiver is done at the very end.
        _validateAccounts(from, to);

        (PortfolioAsset[] memory assets, bool toTransferNegative) = _decodeToAssets(ids, amounts);
        // When doing a bidirectional transfer must ensure that the `to` account has given approval
        // to msg.sender as well.
        if (toTransferNegative) require(isApprovedForAll(to, msg.sender), "Unauthorized");

        (AccountContext memory fromContext, AccountContext memory toContext) = _transfer(
            from,
            to,
            assets
        );

        _checkPostTransferEvent(from, to, fromContext, toContext, data, toTransferNegative);
        emit TransferBatch(msg.sender, from, to, ids, amounts);

        // Do this at the end to prevent re-entrancy
        if (Address.isContract(to)) {
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
    }

    /// @dev Validates accounts on transfer
    function _validateAccounts(address from, address to) private view {
        // Cannot transfer to self, cannot transfer to zero address
        require(from != to && to != address(0) && to != address(this), "Invalid address");
        // Authentication is valid
        require(msg.sender == from || isApprovedForAll(from, msg.sender), "Unauthorized");
        // nTokens will not accept transfers because they do not implement the ERC1155
        // receive method

        // Defensive check to ensure that an authorized operator does not call these methods
        // with an invalid `from` account
        requireValidAccount(from);
    }

    /// @notice Decodes ids and amounts to PortfolioAsset objects
    /// @param ids array of ERC1155 ids
    /// @param amounts amounts to transfer
    /// @return array of portfolio asset objects
    function decodeToAssets(uint256[] calldata ids, uint256[] calldata amounts)
        external
        view
        override
        returns (PortfolioAsset[] memory)
    {
        // prettier-ignore
        (PortfolioAsset[] memory assets, /* */) = _decodeToAssets(ids, amounts);
        return assets;
    }

    function _decodeToAssets(uint256[] calldata ids, uint256[] calldata amounts)
        internal
        view
        returns (PortfolioAsset[] memory, bool)
    {
        require(ids.length == amounts.length);
        bool toTransferNegative = false;
        PortfolioAsset[] memory assets = new PortfolioAsset[](ids.length);

        for (uint256 i; i < ids.length; i++) {
            // Require that ids are not duplicated, there is no valid reason to have duplicate ids
            if (i > 0) require(ids[i] > ids[i - 1], "IDs must be sorted");

            PortfolioAsset memory asset = assets[i];
            (asset.currencyId, asset.maturity, asset.assetType) = TransferAssets.decodeAssetId(ids[i]);

            _requireValidMaturity(asset.currencyId, asset.maturity, block.timestamp);
            // Although amounts is encoded as uint256 we allow it to be negative here. This will
            // allow for bidirectional transfers of fCash. Internally fCash assets are always stored
            // as int128 (for bitmap portfolio) or int88 (for array portfolio) so there is no potential
            // that a uint256 value that is greater than type(int256).max would actually valid.
            asset.notional = int256(amounts[i]);
            // If there is a negative transfer we mark it as such, this will force us to do a free collateral
            // check on the `to` address as well.
            if (asset.notional < 0) toTransferNegative = true;
        }

        return (assets, toTransferNegative);
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
    function _requireValidMaturity(
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
    ) internal returns (AccountContext memory, AccountContext memory) {
        // Finalize all parts of a transfer for each account separately. Settlement must happen
        // before the call to placeAssetsInAccount so that we load the proper portfolio state.
        AccountContext memory toContext = AccountContextHandler.getAccountContext(to);
        if (toContext.mustSettleAssets()) {
            toContext = SettleAssetsExternal.settleAccount(to, toContext);
        }
        toContext = TransferAssets.placeAssetsInAccount(to, toContext, assets);
        toContext.setAccountContext(to);

        // Will flip the sign of notional in the assets array in memory
        TransferAssets.invertNotionalAmountsInPlace(assets);

        // Now finalize the from account
        AccountContext memory fromContext = AccountContextHandler.getAccountContext(from);
        if (fromContext.mustSettleAssets()) {
            fromContext = SettleAssetsExternal.settleAccount(from, fromContext);
        }
        fromContext = TransferAssets.placeAssetsInAccount(from, fromContext, assets);
        fromContext.setAccountContext(from);

        return (fromContext, toContext);
    }

    /// @dev Checks post transfer events which will either be initiating one of the batch trading events or a free collateral
    /// check if required.
    function _checkPostTransferEvent(
        address from,
        address to,
        AccountContext memory fromContext,
        AccountContext memory toContext,
        bytes calldata data,
        bool toTransferNegative
    ) internal {
        bytes4 sig = 0;
        address transactedAccount = address(0);
        if (data.length >= 32) {
            // Method signature is not abi encoded so decode to bytes32 first and take the first 4 bytes. This works
            // because all the methods we want to call below require more than 32 bytes in the calldata
            bytes32 tmp = abi.decode(data, (bytes32));
            sig = bytes4(tmp);
        }

        // These are the only four methods allowed to occur in a post transfer event. These actions allow `from`
        // accounts to take any sort of trading action as a result of their transfer. All of these actions will
        // handle checking free collateral so no additional check is necessary here.
        if (
            sig == NotionalProxy.nTokenRedeem.selector ||
            sig == NotionalProxy.batchLend.selector ||
            sig == NotionalProxy.batchBalanceAction.selector ||
            sig == NotionalProxy.batchBalanceAndTradeAction.selector
        ) {
            transactedAccount = abi.decode(data[4:36], (address));
            // Ensure that the "transactedAccount" parameter of the call is set to the from address or the
            // to address. If it is the "to" address then ensure that the msg.sender has approval to
            // execute operations
            require(
                transactedAccount == from ||
                    (transactedAccount == to && isApprovedForAll(to, msg.sender)),
                "Unauthorized call"
            );

            // We can only call back to Notional itself at this point, account context is already
            // stored and all three of the whitelisted methods above will check free collateral.
            (bool status, bytes memory result) = address(this).call{value: msg.value}(data);
            require(status, _getRevertMsg(result));
        }

        // The transacted account will have its free collateral checked above so there is
        // no need to recheck here.
        // If transactedAccount == 0 then will check fc
        // If transactedAccount == to then will check fc
        // If transactedAccount == from then will skip, prefer call above
        if (transactedAccount != from && fromContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(from);
        }

        // Check free collateral if the `to` account has taken on a negative fCash amount
        // If toTransferNegative is false then will not check
        // If transactedAccount == 0 then will check fc
        // If transactedAccount == from then will check fc
        // If transactedAccount == to then will skip, prefer call above
        if (toTransferNegative && transactedAccount != to && toContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(to);
        }
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "Transaction reverted silently";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
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

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address, address) {
        return (address(FreeCollateralExternal), address(SettleAssetsExternal));
    }
}

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./DepositWithdrawAction.sol";
import "./RedeemPerpetualTokenAction.sol";
import "./FreeCollateralExternal.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/AccountContextHandler.sol";
import "../common/TransferAssets.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "interfaces/IERC1155TokenReceiver.sol";

contract ERC1155 is IERC1155, StorageLayoutV1 {
    using AccountContextHandler for AccountStorage;

    // bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))
    bytes4 internal constant ERC1155_ACCEPTED = 0xf23a6e61;
    // bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))
    bytes4 internal constant ERC1155_BATCH_ACCEPTED = 0xbc197c81;
    bytes4 internal constant ERC1155_INTERFACE = 0xd9b67a26;

    function supportsInterface(bytes4 interfaceId) external override view returns (bool) {
        return interfaceId == ERC1155_INTERFACE;
    }

    function balanceOf(address account, uint256 id) external override view returns (uint256) {

    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids) external override view returns (uint256[] memory) {
        
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external override {
        require(to != address(0), "Invalid address");
        require(msg.sender == from || isApprovedForAll(from, msg.sender), "Unauthorized");
        require(amount <= uint(type(int).max)); // dev: int overflow

        PortfolioAsset[] memory assets = new PortfolioAsset[](1);
        (
            assets[0].currencyId,
            assets[0].maturity,
            assets[0].assetType
        ) = decodeId(id);
        assets[0].notional = int(amount);

        AccountStorage memory fromContext = _transfer(from, to, assets);

        emit TransferSingle(msg.sender, from, to, id, amount);

        // If code size > 0 call onERC1155received
        uint256 codeSize;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            codeSize := extcodesize(to)
        }
        if (codeSize > 0) {
            require(
                IERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, id, amount, data) == ERC1155_ACCEPTED,
                "Not accepted"
            );
        }

        _checkPostTransferEvent(from, fromContext, data);
    }

    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external override {
        require(to != address(0), "Invalid address");
        require(msg.sender == from || isApprovedForAll(from, msg.sender), "Unauthorized");

        PortfolioAsset[] memory assets; // = decodeToAssets(ids, amounts);
        AccountStorage memory fromContext = _transfer(from, to, assets);

        emit TransferBatch(msg.sender, from, to, ids, amounts);

        // If code size > 0 call onERC1155received
        uint256 codeSize;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            codeSize := extcodesize(to)
        }
        if (codeSize > 0) {
            require(
                IERC1155TokenReceiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data) ==
                    ERC1155_BATCH_ACCEPTED,
                "Not accepted"
            );
        }

        _checkPostTransferEvent(from, fromContext, data);
    }

    function decodeToAssets(uint[] calldata ids, uint[] calldata amounts) public pure returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory assets = new PortfolioAsset[](ids.length);
        for (uint i; i < ids.length; i++) {
            (
                assets[i].currencyId,
                assets[i].maturity,
                assets[i].assetType
            ) = decodeId(ids[i]);

            require(amounts[i] <= uint(type(int).max)); // dev: int overflow
            assets[i].notional = int(amounts[i]);
        }

        return assets;
    }

    function decodeId(uint id) public pure returns (uint16, uint40, uint8) {
        return (
            uint16(uint(bytes32(id) >> 48)),
            uint40(uint(bytes32(id) >> 8)),
            uint8(uint(bytes32(id)))
        );
    }

    function encodeAsset(uint16 currencyId, uint40 maturity, uint8 assetType) public pure returns (uint) {
        return uint(
            bytes32(uint(currencyId)) << 48 |
            bytes32(uint(maturity)) << 8 |
            bytes32(uint(assetType))
        );
    }

    function _transfer(address from, address to, PortfolioAsset[] memory assets) internal returns (AccountStorage memory) {
        AccountStorage memory fromContext = AccountContextHandler.getAccountContext(from);
        AccountStorage memory toContext = AccountContextHandler.getAccountContext(to);

        TransferAssets.placeAssetsInAccount(to, toContext, assets);
        TransferAssets.invertNotionalAmountsInPlace(assets);
        TransferAssets.placeAssetsInAccount(from, fromContext, assets);

        toContext.setAccountContext(to);
        fromContext.setAccountContext(from);

        return fromContext;
    }

    function _checkPostTransferEvent(address from, AccountStorage memory fromContext, bytes calldata data) internal {
        bytes4 sig = abi.decode(data[:4], (bytes4));

        if (sig == RedeemPerpetualTokenAction.perpetualTokenRedeem.selector ||
            sig == DepositWithdrawAction.batchBalanceAndTradeAction.selector) {
            // Ensure that the "account" parameter of the call is set to the from address
            require(abi.decode(data[4:32], (address)) == from, "Unauthorized call");
            (bool status,) = address(this).delegatecall(data);
            require(status);

            return;
        } 
        
        if (fromContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(from);
        }
    }

    function setApprovalForAll(address operator, bool approved) external override {
        accountAuthorizedTransferOperator[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address account, address operator) public override view returns (bool) {
        if (globalTransferOperator[operator]) return true;

        return accountAuthorizedTransferOperator[account][operator];
    }
}
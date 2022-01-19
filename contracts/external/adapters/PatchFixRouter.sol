// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/StorageLayoutV1.sol";
import "../../internal/balances/TokenHandler.sol";
import "../../proxy/utils/UUPSUpgradeable.sol";
import "../../global/Types.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PatchFixRouter is StorageLayoutV1, UUPSUpgradeable {
    address private immutable DEPLOYER;
    uint16 private constant WBTC_ID = 4;

    constructor() {
        DEPLOYER = msg.sender;
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        // Authorizes an upgrade back to the original router
        require(msg.sender == DEPLOYER);
    }

    function patchFix() external {
        // This should be called using upgradeToAndCallSecure
        require(msg.sender == DEPLOYER);
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(WBTC_ID);
        Token memory assetToken = TokenHandler.getAssetToken(WBTC_ID);
        ERC20(underlyingToken.tokenAddress).approve(
            assetToken.tokenAddress,
            type(uint256).max
        );

        ERC20(underlyingToken.tokenAddress).approve(
            0xC11b1268C1A384e55C48c2391d8d480264A3A7F4, // cWBTC1
            0
        );
    }

    function destroy() external {
        require(msg.sender == DEPLOYER);
        selfdestruct(payable(DEPLOYER));
    }

}
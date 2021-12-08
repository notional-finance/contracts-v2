// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "./NoteERC20.sol";
import "interfaces/arbitrum/ICustomToken.sol";
import "interfaces/arbitrum/gateway/IL1CustomGateway.sol";
import "interfaces/arbitrum/gateway/IL1GatewayRouter.sol";

contract ArbitrumL1NoteERC20 is NoteERC20, ICustomToken {
    address public immutable arbitrumGateway;
    address public immutable arbitrumRouter;
    bool private shouldRegisterGateway;

    constructor (address _customGateway, address _gatewayRouter) NoteERC20() {
        arbitrumGateway = _customGateway;
        arbitrumRouter = _gatewayRouter;
    }

    /// @dev we only set shouldRegisterGateway to true when in `registerTokenOnL2`
    function isArbitrumEnabled() external view override returns (uint8) {
        require(shouldRegisterGateway, "NOT_EXPECTED_CALL");
        return uint8(0xa4b1);
    }

    function registerTokenOnL2(
        address l2CustomTokenAddress,
        uint256 maxSubmissionCostForCustomBridge,
        uint256 maxSubmissionCostForRouter,
        uint256 maxGasForCustomBridge,
        uint256 maxGasForRouter,
        uint256 gasPriceBid,
        uint256 valueForGateway,
        uint256 valueForRouter
    ) public payable override onlyOwner {
        // we temporarily set `shouldRegisterGateway` to true for the callback in registerTokenToL2 to succeed
        bool prev = shouldRegisterGateway;
        shouldRegisterGateway = true;

        IL1CustomGateway(arbitrumGateway).registerTokenToL2{value: valueForGateway}(
            l2CustomTokenAddress,
            maxGasForCustomBridge,
            gasPriceBid,
            maxSubmissionCostForCustomBridge,
            msg.sender
        );

        IL1GatewayRouter(arbitrumRouter).setGateway{value: valueForRouter}(
            arbitrumGateway,
            maxGasForRouter,
            gasPriceBid,
            maxSubmissionCostForRouter,
            msg.sender
        );

        shouldRegisterGateway = prev;
    }

}
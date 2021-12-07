// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "./NoteERC20.sol";
import "interfaces/arbitrum/ICustomToken.sol";
import "interfaces/arbitrum/gateway/IL1CustomGateway.sol";
import "interfaces/arbitrum/gateway/IL1GatewayRouter.sol";

contract ArbitrumL1NoteERC20 is NoteERC20, ICustomToken {
    address public immutable arbitrumBridge;
    address public immutable arbitrumRouter;
    bool private shouldRegisterGateway;

    constructor (address _bridge, address _router) NoteERC20() {
        arbitrumBridge = _bridge;
        arbitrumRouter = _router;
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
        uint256 valueForRouter,
        address creditBackAddress
    ) public payable override {
        // we temporarily set `shouldRegisterGateway` to true for the callback in registerTokenToL2 to succeed
        bool prev = shouldRegisterGateway;
        shouldRegisterGateway = true;

        // L1CustomGateway(bridge).registerTokenToL2{value: valueForGateway}(
        IL1CustomGateway(arbitrumBridge).registerTokenToL2(
            l2CustomTokenAddress,
            maxGasForCustomBridge,
            gasPriceBid,
            maxSubmissionCostForCustomBridge,
            creditBackAddress
        );

        // L1GatewayRouter(router).setGateway{value: valueForRouter}(
        IL1GatewayRouter(arbitrumRouter).setGateway(
            arbitrumBridge,
            maxGasForRouter,
            gasPriceBid,
            maxSubmissionCostForRouter,
            creditBackAddress
        );

        shouldRegisterGateway = prev;
    }

}
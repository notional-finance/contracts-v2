// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.7.0;

interface IL1GatewayRouter {
    function setGateway(
        address _gateway,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost,
        address _creditBackAddress
    ) external payable returns (uint256);
}
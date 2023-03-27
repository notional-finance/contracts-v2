// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "../external/governance/GovernorAlpha.sol";

contract MockTimelockAttack {
    address payable public governor;
    address[] public targets;
    uint256[] public values;
    bytes[] public calldatas;
    uint256 public proposalId;

    function setScheduleVars(
        address payable _governor,
        address[] memory _targets,
        uint256[] memory _values,
        bytes[] memory _calldatas,
        uint256 _proposalId
    ) external {
        governor = _governor;
        targets = _targets;
        values = _values;
        calldatas = _calldatas;
        proposalId = _proposalId;
    }

    function scheduleBatchInitial() external {
        GovernorAlpha(governor).scheduleBatch(targets, values, calldatas, bytes32(0), bytes32(proposalId), 0);
    }

    function executeArbitrary(
        address target,
        uint256 value,
        bytes calldata data
    ) external {
        GovernorAlpha(governor).schedule(target, value, data, bytes32(0), bytes32(0), 0);
        GovernorAlpha(governor).execute(target, value, data, bytes32(0), bytes32(0));
    }
}
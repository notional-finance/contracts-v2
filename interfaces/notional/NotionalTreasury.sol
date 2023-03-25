// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;
pragma abicoder v2;

interface NotionalTreasury {
    event UpdateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate);

    struct RebalancingTargetConfig {
        address holding;
        uint8 target;
    }

    /// @notice Emitted when reserve balance is updated
    event ReserveBalanceUpdated(uint16 indexed currencyId, int256 newBalance);
    /// @notice Emitted when reserve balance is harvested
    event ExcessReserveBalanceHarvested(uint16 indexed currencyId, int256 harvestAmount);
    /// @dev Emitted when treasury manager is updated
    event TreasuryManagerChanged(address indexed previousManager, address indexed newManager);
    /// @dev Emitted when reserve buffer value is updated
    event ReserveBufferUpdated(uint16 currencyId, uint256 bufferAmount);

    event RebalancingTargetsUpdated(uint16 currencyId, RebalancingTargetConfig[] targets);

    event RebalancingCooldownUpdated(uint16 currencyId, uint40 cooldownTimeInSeconds);

    event CurrencyRebalanced(uint16 currencyId, uint256 underlyingScalar, uint256 annualizedInterestRate);

    function claimCOMPAndTransfer(address[] calldata ctokens) external returns (uint256);

    function transferReserveToTreasury(uint16[] calldata currencies)
        external
        returns (uint256[] memory);

    function setTreasuryManager(address manager) external;

    function setReserveBuffer(uint16 currencyId, uint256 amount) external;

    function setReserveCashBalance(uint16 currencyId, int256 reserveBalance) external;

    function setRebalancingTargets(uint16 currencyId, RebalancingTargetConfig[] calldata targets) external;

    function setRebalancingCooldown(uint16 currencyId, uint40 cooldownTimeInSeconds) external;

    function rebalance(uint16[] calldata currencyId) external;

    function updateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate) external;
}

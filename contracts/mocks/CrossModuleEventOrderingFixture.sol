// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test-only fixture for V2-SC-133. It has no production protocol authority.
/// @dev Each hop authenticates its immediate caller and forwards the correlation id
///      unchanged. Reverts at any depth roll back every event and storage write.
abstract contract CorrelatedFixtureModule {
    error UnauthorizedCaller(address caller);
    error ZeroAddress();
    error ZeroCorrelationId();

    address public immutable upstream;

    event ModuleEntered(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);
    event ModuleCompleted(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);

    constructor(address upstream_) {
        if (upstream_ == address(0)) revert ZeroAddress();
        upstream = upstream_;
    }

    modifier onlyUpstream(bytes32 correlationId) {
        if (msg.sender != upstream) revert UnauthorizedCaller(msg.sender);
        if (correlationId == bytes32(0)) revert ZeroCorrelationId();
        _;
    }
}

contract TreasuryOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("TREASURY");
    mapping(bytes32 => uint256) public reconciledClaim;

    constructor(address upstream_) CorrelatedFixtureModule(upstream_) {}

    function reconcile(bytes32 correlationId, uint256 claimId, bool fail) external onlyUpstream(correlationId) {
        emit ModuleEntered(correlationId, MODULE_ID, claimId);
        if (fail) revert("TREASURY_FAILURE");
        reconciledClaim[correlationId] = claimId;
        emit ModuleCompleted(correlationId, MODULE_ID, claimId);
    }
}

contract RewardsOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("REWARDS");
    TreasuryOrderingFixture public immutable downstream;

    constructor(address upstream_, TreasuryOrderingFixture downstream_) CorrelatedFixtureModule(upstream_) {
        if (address(downstream_) == address(0)) revert ZeroAddress();
        downstream = downstream_;
    }

    function allocate(bytes32 correlationId, uint256 claimId, bool fail) external onlyUpstream(correlationId) {
        emit ModuleEntered(correlationId, MODULE_ID, claimId);
        downstream.reconcile(correlationId, claimId, fail);
        emit ModuleCompleted(correlationId, MODULE_ID, claimId);
    }
}

contract SettlementOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("SETTLEMENT");
    RewardsOrderingFixture public immutable downstream;

    constructor(address upstream_, RewardsOrderingFixture downstream_) CorrelatedFixtureModule(upstream_) {
        if (address(downstream_) == address(0)) revert ZeroAddress();
        downstream = downstream_;
    }

    function settle(bytes32 correlationId, uint256 claimId, bool fail) external onlyUpstream(correlationId) {
        emit ModuleEntered(correlationId, MODULE_ID, claimId);
        downstream.allocate(correlationId, claimId, fail);
        emit ModuleCompleted(correlationId, MODULE_ID, claimId);
    }
}

contract CustodyOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("CUSTODY");
    SettlementOrderingFixture public immutable downstream;

    constructor(address upstream_, SettlementOrderingFixture downstream_) CorrelatedFixtureModule(upstream_) {
        if (address(downstream_) == address(0)) revert ZeroAddress();
        downstream = downstream_;
    }

    function release(bytes32 correlationId, uint256 claimId, bool fail) external onlyUpstream(correlationId) {
        emit ModuleEntered(correlationId, MODULE_ID, claimId);
        downstream.settle(correlationId, claimId, fail);
        emit ModuleCompleted(correlationId, MODULE_ID, claimId);
    }
}

contract ClaimsOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("CLAIMS");
    CustodyOrderingFixture public immutable downstream;

    constructor(address upstream_, CustodyOrderingFixture downstream_) CorrelatedFixtureModule(upstream_) {
        if (address(downstream_) == address(0)) revert ZeroAddress();
        downstream = downstream_;
    }

    function finalize(bytes32 correlationId, uint256 claimId, bool fail) external onlyUpstream(correlationId) {
        emit ModuleEntered(correlationId, MODULE_ID, claimId);
        downstream.release(correlationId, claimId, fail);
        emit ModuleCompleted(correlationId, MODULE_ID, claimId);
    }
}

contract GovernanceOrderingFixture {
    error UnauthorizedCaller(address caller);
    error ZeroAddress();
    error ZeroCorrelationId();
    error CorrelationAlreadyConsumed(bytes32 correlationId);

    bytes32 public constant MODULE_ID = keccak256("GOVERNANCE");
    address public immutable timelock;
    ClaimsOrderingFixture public immutable downstream;
    mapping(bytes32 => bool) public consumed;

    event ModuleEntered(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);
    event ModuleCompleted(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);

    constructor(address timelock_, ClaimsOrderingFixture downstream_) {
        if (timelock_ == address(0) || address(downstream_) == address(0)) revert ZeroAddress();
        timelock = timelock_;
        downstream = downstream_;
    }

    function execute(bytes32 correlationId, uint256 claimId, bool fail) external {
        if (msg.sender != timelock) revert UnauthorizedCaller(msg.sender);
        if (correlationId == bytes32(0)) revert ZeroCorrelationId();
        if (consumed[correlationId]) revert CorrelationAlreadyConsumed(correlationId);

        consumed[correlationId] = true;
        emit ModuleEntered(correlationId, MODULE_ID, claimId);
        downstream.finalize(correlationId, claimId, fail);
        emit ModuleCompleted(correlationId, MODULE_ID, claimId);
    }
}

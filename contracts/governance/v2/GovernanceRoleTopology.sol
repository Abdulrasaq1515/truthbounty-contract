// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TruthBountyGovernor} from "./TruthBountyGovernor.sol";

/**
 * @title GovernanceRoleTopology
 * @notice Wires production role topology between governor and timelock (V2-SC-026 dependency).
 * @dev Guardian receives an individual canceller role grant on the timelock; the governor is the sole proposer. Execution is permissionless after the timelock delay.
 */
library GovernanceRoleTopology {
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    /// @notice Emitted after the timelock role topology is configured.
    /// @param timelock Timelock receiving roles.
    /// @param governor Governor receiving proposer and canceller rights.
    /// @param guardian Guardian receiving cancellation rights.
    /// @param minDelay Configured timelock minimum delay in seconds.
    event GovernanceTopologyConfigured(
        address indexed timelock,
        address indexed governor,
        address indexed guardian,
        uint256 minDelay
    );

    /**
     * @dev Assign canonical timelock roles after governor deployment.
     * @param timelock Timelock receiving the role topology.
     * @param governor Governor receiving proposer and canceller rights.
     * @param guardian Guardian receiving an individual canceller-only role grant.
     * @param minDelay Configured minimum execution delay in seconds.
     */
    function configure(
        TimelockController timelock,
        TruthBountyGovernor governor,
        address guardian,
        uint256 minDelay
    ) internal {
        timelock.grantRole(PROPOSER_ROLE, address(governor));
        timelock.grantRole(CANCELLER_ROLE, address(governor));
        timelock.grantRole(CANCELLER_ROLE, guardian);
        timelock.grantRole(EXECUTOR_ROLE, address(0));

        emit GovernanceTopologyConfigured(address(timelock), address(governor), guardian, minDelay);
    }

    /**
     * @dev Hand timelock self-administration to the timelock itself after bootstrap.
     * @param timelock Timelock whose administrator role is finalized.
     * @param currentAdmin Bootstrap administrator whose role is revoked.
     */
    function finalizeTimelockAdmin(TimelockController timelock, address currentAdmin) internal {
        timelock.grantRole(TIMELOCK_ADMIN_ROLE, address(timelock));
        timelock.revokeRole(TIMELOCK_ADMIN_ROLE, currentAdmin);
    }
}

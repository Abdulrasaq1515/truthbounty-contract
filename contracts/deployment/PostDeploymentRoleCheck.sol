// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";

/**
 * @title PostDeploymentRoleCheck
 * @notice Pure on-chain library for verifying deployer/script role renunciation (V2-SC-127).
 * @dev After deployment and handoff every deployer EOA and bootstrap script must hold
 *      zero protocol roles. This library enumerates the canonical V2 role catalog and
 *      checks each role on each target contract. Violations are collected and emitted
 *      so off-chain auditors and CI can deterministically validate the handoff.
 *
 *      Usage:
 *        RoleViolation[] memory v = PostDeploymentRoleCheck.checkAllRoles(deployer, targets);
 *        require(v.length == 0, "deployer retains unauthorized roles");
 *
 *      The catalog deliberately over-includes roles — a role that does not exist on a
 *      contract causes a revert in `hasRole` only if the target is not an IAccessControl
 *      implementation. For non-AccessControl contracts the caller must use `safeCheckRole`.
 */
library PostDeploymentRoleCheck {
    // ────────────────────────────────────────────────────────────────────
    //  Canonical V2 role catalog
    // ────────────────────────────────────────────────────────────────────

    /// @dev AccessControl sentinel — every AccessControl contract has this.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // Governance & timelock
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // Module administration
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 internal constant REGISTRY_UPDATER_ROLE = keccak256("REGISTRY_UPDATER_ROLE");

    // Upgrade
    bytes32 internal constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");
    bytes32 internal constant EMERGENCY_UPGRADE_ROLE = keccak256("EMERGENCY_UPGRADE_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant UPGRADE_CONTROLLER_ROLE = keccak256("UPGRADE_CONTROLLER_ROLE");

    // Operations
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 internal constant ROUND_MANAGER_ROLE = keccak256("ROUND_MANAGER_ROLE");
    bytes32 internal constant CRITICAL_SLASHER_ROLE = keccak256("CRITICAL_SLASHER_ROLE");

    // Treasury & settlement
    bytes32 internal constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 internal constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 internal constant SETTLEMENT_ROLE = keccak256("RESOLVER_ROLE"); // alias

    // Evidence & verification
    bytes32 internal constant EVIDENCE_ADMIN_ROLE = keccak256("EVIDENCE_ADMIN_ROLE");
    bytes32 internal constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");
    bytes32 internal constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");
    bytes32 internal constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    // Migration
    bytes32 internal constant MIGRATOR_ROLE = keccak256("MIGRATOR_ROLE");

    // Minting (ERC20 extensions)
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Registry
    bytes32 internal constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");

    /// @dev Total distinct roles checked (used for static array sizing).
    uint256 internal constant ROLE_CATALOG_SIZE = 27;

    // ────────────────────────────────────────────────────────────────────
    //  Types
    // ────────────────────────────────────────────────────────────────────

    struct RoleViolation {
        address target;
        bytes32 role;
    }

    // ────────────────────────────────────────────────────────────────────
    //  Events
    // ────────────────────────────────────────────────────────────────────

    /// @notice Emitted when a full check completes with zero violations.
    event RoleRenunciationCheckPassed(
        address indexed deployer,
        uint256 contractsChecked,
        uint256 rolesChecked
    );

    /// @notice Emitted for every retained role discovered.
    event RoleRenunciationViolation(
        address indexed deployer,
        address indexed target,
        bytes32 indexed role
    );

    // ────────────────────────────────────────────────────────────────────
    //  Core check logic
    // ────────────────────────────────────────────────────────────────────

    /**
     * @notice Build the full role catalog as a memory array.
     * @dev Returned array contains all distinct role hashes the protocol defines.
     *      Duplicate aliases (e.g. SETTLEMENT_ROLE == RESOLVER_ROLE) are intentionally
     *      de-duplicated by the compiler since they share the same keccak value.
     */
    function roleCatalog() internal pure returns (bytes32[] memory roles) {
        roles = new bytes32[](ROLE_CATALOG_SIZE);
        uint256 i;
        roles[i++] = DEFAULT_ADMIN_ROLE;
        roles[i++] = PROPOSER_ROLE;
        roles[i++] = EXECUTOR_ROLE;
        roles[i++] = CANCELLER_ROLE;
        roles[i++] = TIMELOCK_ADMIN_ROLE;
        roles[i++] = GUARDIAN_ROLE;
        roles[i++] = GOVERNANCE_ROLE;
        roles[i++] = ADMIN_ROLE;
        roles[i++] = REGISTRY_ADMIN_ROLE;
        roles[i++] = REGISTRY_UPDATER_ROLE;
        roles[i++] = UPGRADE_ROLE;
        roles[i++] = EMERGENCY_UPGRADE_ROLE;
        roles[i++] = UPGRADER_ROLE;
        roles[i++] = UPGRADE_CONTROLLER_ROLE;
        roles[i++] = PAUSER_ROLE;
        roles[i++] = RESOLVER_ROLE;
        roles[i++] = ROUND_MANAGER_ROLE;
        roles[i++] = CRITICAL_SLASHER_ROLE;
        roles[i++] = TREASURY_ROLE;
        roles[i++] = TREASURY_MANAGER_ROLE;
        roles[i++] = EVIDENCE_ADMIN_ROLE;
        roles[i++] = EVALUATOR_ROLE;
        roles[i++] = CONFIG_ADMIN_ROLE;
        roles[i++] = VALIDATOR_ROLE;
        roles[i++] = MIGRATOR_ROLE;
        roles[i++] = MINTER_ROLE;
        roles[i++] = REGISTRY_ROLE;
    }

    /**
     * @notice Check whether `deployer` holds any role from the catalog on any of `targets`.
     * @param deployer The address to check for retained roles.
     * @param targets  Array of AccessControl-compatible contract addresses.
     * @return violations Array of (target, role) pairs where the deployer still holds the role.
     */
    function checkAllRoles(
        address deployer,
        address[] memory targets
    ) internal view returns (RoleViolation[] memory violations) {
        if (deployer == address(0)) return violations;

        bytes32[] memory roles = roleCatalog();
        uint256 maxViolations = targets.length * roles.length;
        RoleViolation[] memory buffer = new RoleViolation[](maxViolations);
        uint256 count;

        for (uint256 t; t < targets.length; ++t) {
            if (targets[t] == address(0)) continue;
            for (uint256 r; r < roles.length; ++r) {
                if (_safeHasRole(targets[t], roles[r], deployer)) {
                    buffer[count++] = RoleViolation({target: targets[t], role: roles[r]});
                }
            }
        }

        // Compact buffer → violations
        violations = new RoleViolation[](count);
        for (uint256 k; k < count; ++k) {
            violations[k] = buffer[k];
        }
    }

    /**
     * @notice Check a single role on a single target with error handling.
     * @dev If the target does not implement `hasRole` (no code, or different ABI),
     *      the static call will fail and this returns false instead of reverting.
     */
    function safeCheckRole(
        address target,
        bytes32 role,
        address account
    ) internal view returns (bool hasIt) {
        return _safeHasRole(target, role, account);
    }

    /**
     * @notice Check all roles and emit events for each violation. Reverts if any violations found.
     * @param deployer The deployer/script address to check.
     * @param targets  Array of AccessControl-compatible contract addresses.
     */
    function assertNoRolesRetained(
        address deployer,
        address[] memory targets
    ) internal {
        RoleViolation[] memory violations = checkAllRoles(deployer, targets);

        if (violations.length > 0) {
            for (uint256 i; i < violations.length; ++i) {
                emit RoleRenunciationViolation(
                    deployer,
                    violations[i].target,
                    violations[i].role
                );
            }
            revert("PostDeploymentRoleCheck: deployer retains unauthorized roles");
        }

        bytes32[] memory roles = roleCatalog();
        emit RoleRenunciationCheckPassed(deployer, targets.length, roles.length);
    }

    // ────────────────────────────────────────────────────────────────────
    //  Internals
    // ────────────────────────────────────────────────────────────────────

    function _safeHasRole(
        address target,
        bytes32 role,
        address account
    ) private view returns (bool) {
        // Guard: target must have code
        if (target.code.length == 0) return false;

        (bool ok, uint256 value, uint256 returnSize) = BoundedStaticCall.staticcallWord(
            target,
            abi.encodeCall(IAccessControl.hasRole, (role, account))
        );
        if (!ok || returnSize < 32 || value > 1) return false;
        return value == 1;
    }
}

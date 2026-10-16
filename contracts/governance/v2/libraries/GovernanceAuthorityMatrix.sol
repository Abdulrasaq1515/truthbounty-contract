// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGovernanceAuthorityBoundaries as IAuthority} from "../IGovernanceAuthorityBoundaries.sol";

/**
 * @title GovernanceAuthorityMatrix
 * @notice Canonical, immutable authority matrix for the TruthBounty V2 governance topology (V2-SC-111).
 * @dev Encodes the exact (role, capability) grants of the protocol. Every capability is owned by a
 *      single authority except `CANCEL_PROPOSAL`, which Governor and Guardian intentionally share as a
 *      veto path. Because the matrix is pure, a deployment cannot drift into overlapping or
 *      fail-open authority and no unbounded storage reads are required for authorization checks.
 */
library GovernanceAuthorityMatrix {
    uint256 internal constant ROLE_COUNT = 7;
    uint256 internal constant CAPABILITY_COUNT = 11;

    /**
     * @dev Returns true when `role` is canonically allowed to exercise `capability`.
     *      Bounded, branch-only evaluation with no external calls or loops over unbounded input.
     */
    function isAllowed(IAuthority.AuthorityRole role, IAuthority.Capability capability)
        internal
        pure
        returns (bool)
    {
        if (role == IAuthority.AuthorityRole.GOVERNOR) {
            return capability == IAuthority.Capability.PROPOSE_PROPOSAL
                || capability == IAuthority.Capability.QUEUE_PROPOSAL
                || capability == IAuthority.Capability.CANCEL_PROPOSAL;
        }
        if (role == IAuthority.AuthorityRole.TIMELOCK) {
            return capability == IAuthority.Capability.EXECUTE_PROPOSAL
                || capability == IAuthority.Capability.SET_TIMELOCK_ROLES
                || capability == IAuthority.Capability.UPGRADE_IMPLEMENTATION;
        }
        if (role == IAuthority.AuthorityRole.GUARDIAN) {
            return capability == IAuthority.Capability.CANCEL_PROPOSAL
                || capability == IAuthority.Capability.PAUSE_PROTOCOL;
        }
        if (role == IAuthority.AuthorityRole.REGISTRY) {
            return capability == IAuthority.Capability.REGISTER_GOVERNED_MODULE;
        }
        if (role == IAuthority.AuthorityRole.CONFIGURATION) {
            return capability == IAuthority.Capability.SET_PROTOCOL_PARAMETER;
        }
        if (role == IAuthority.AuthorityRole.TREASURY) {
            return capability == IAuthority.Capability.RELEASE_TREASURY_FUNDS;
        }
        return capability == IAuthority.Capability.ROTATE_OPERATIONAL_ROLE;
    }

    /**
     * @dev Returns true when `capability` must be held by exactly one authority.
     *      `CANCEL_PROPOSAL` is the single intentionally shared capability.
     */
    function isExclusive(IAuthority.Capability capability) internal pure returns (bool) {
        return capability != IAuthority.Capability.CANCEL_PROPOSAL;
    }

    /**
     * @dev Returns every authority canonically allowed to exercise `capability`, in enum order.
     *      The result is bounded by {ROLE_COUNT}.
     */
    function rolesFor(IAuthority.Capability capability)
        internal
        pure
        returns (IAuthority.AuthorityRole[] memory roles)
    {
        roles = new IAuthority.AuthorityRole[](ROLE_COUNT);
        uint256 count;
        for (uint256 i = 0; i < ROLE_COUNT; ++i) {
            IAuthority.AuthorityRole role = IAuthority.AuthorityRole(i);
            if (isAllowed(role, capability)) {
                roles[count] = role;
                ++count;
            }
        }
        assembly {
            mstore(roles, count)
        }
    }

    /**
     * @dev Returns every capability canonically granted to `role`, in enum order.
     *      The result is bounded by {CAPABILITY_COUNT}.
     */
    function capabilitiesFor(IAuthority.AuthorityRole role)
        internal
        pure
        returns (IAuthority.Capability[] memory capabilities)
    {
        capabilities = new IAuthority.Capability[](CAPABILITY_COUNT);
        uint256 count;
        for (uint256 i = 0; i < CAPABILITY_COUNT; ++i) {
            IAuthority.Capability capability = IAuthority.Capability(i);
            if (isAllowed(role, capability)) {
                capabilities[count] = capability;
                ++count;
            }
        }
        assembly {
            mstore(capabilities, count)
        }
    }

    /**
     * @dev Returns the single authority owning an exclusive `capability`.
     *      Reverts with {SharedCapability} for the shared veto capability and with
     *      {NoRoleForCapability} if the matrix has no owner (guards against drift).
     */
    function soleRoleFor(IAuthority.Capability capability) internal pure returns (IAuthority.AuthorityRole) {
        if (!isExclusive(capability)) {
            revert IAuthority.SharedCapability(capability);
        }
        for (uint256 i = 0; i < ROLE_COUNT; ++i) {
            IAuthority.AuthorityRole role = IAuthority.AuthorityRole(i);
            if (isAllowed(role, capability)) {
                return role;
            }
        }
        revert IAuthority.NoRoleForCapability(capability);
    }

    /**
     * @dev Reverts with {CapabilityNotGranted} unless `role` may exercise `capability`.
     *      Rejects fail-open authorization by defaulting to a revert.
     */
    function enforce(IAuthority.AuthorityRole role, IAuthority.Capability capability) internal pure {
        if (!isAllowed(role, capability)) {
            revert IAuthority.CapabilityNotGranted(role, capability);
        }
    }
}

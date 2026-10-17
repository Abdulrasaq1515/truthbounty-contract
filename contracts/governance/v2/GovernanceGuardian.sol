// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ITruthBountyGovernor} from "./ITruthBountyGovernor.sol";

/**
 * @title GovernanceGuardian
 * @notice Separate emergency guardian with veto/cancel powers but no execution authority.
 * @dev Guardian may cancel active or queued proposals and pause registered modules.
 *      Guardian cannot execute proposals, bypass timelock delays, or settle claims.
 */
contract GovernanceGuardian is AccessControl, Pausable {
    /// @notice Role permitted to veto proposals and request module pauses.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Governor used for guardian-authorized proposal cancellation.
    ITruthBountyGovernor public immutable governor;

    /// @notice Emitted after the guardian successfully cancels a proposal.
    /// @param proposalId Cancelled proposal.
    /// @param guardian Guardian that requested cancellation.
    event ProposalVetoed(uint256 indexed proposalId, address indexed guardian);

    /// @notice Emitted when the guardian signals a module pause request.
    /// @param module Module targeted by the request.
    /// @param guardian Guardian that emitted the request.
    event GuardianModulePauseRequested(address indexed module, address indexed guardian);

    /// @notice Governor address must not be zero.
    error ZeroGovernorAddress();
    /// @notice Caller is not authorized for the guardian operation.
    /// @param caller Unauthorized caller.
    error NotGuardian(address caller);

    /// @param admin Bootstrap administrator receiving the default admin role.
    /// @param guardian Guardian authorized to veto and request pauses.
    /// @param governor_ Governor contract used for veto cancellation.
    constructor(address admin, address guardian, ITruthBountyGovernor governor_) {
        if (address(governor_) == address(0)) revert ZeroGovernorAddress();
        governor = governor_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    /**
     * @notice Cancel (veto) a governance proposal. Delegates to the governor cancel path.
     * @dev Authorization is enforced by the governor: the call only succeeds while the proposal is
     *      in a non-terminal state and is attributed {TruthBountyGovernor.CancelAuthority-GUARDIAN}
     *      by {TruthBountyGovernor-cancellationAuthority}; any other outcome reverts with
     *      {TruthBountyGovernor-ProposalCancellationUnauthorized} (V2-SC-066). Re-cancelling an
     *      already-cancelled proposal always reverts, so a veto cannot be replayed.
     * @param proposalId The proposal to veto.
     * @notice Cancel a governance proposal. Delegates to the governor cancel path.
     * @dev Guardian cancellation is authorized inside {TruthBountyGovernor._validateCancel}. The external governor call must succeed before the event is emitted; it cannot execute queued operations.
     * @param proposalId Proposal to cancel.
     */
    function vetoProposal(uint256 proposalId) external onlyRole(GUARDIAN_ROLE) {
        governor.cancel(proposalId);
        emit ProposalVetoed(proposalId, msg.sender);
    }

    /**
     * @notice Signal an emergency pause request for a module. Does not execute module calls.
     * @param module Module targeted by the request; this function never calls the module.
     */
    function requestModulePause(address module) external onlyRole(GUARDIAN_ROLE) {
        emit GuardianModulePauseRequested(module, msg.sender);
    }

    /**
     * @notice Guardian-controlled circuit breaker for the guardian contract itself.
     * @dev Pausing this contract does not prevent `vetoProposal()` or `requestModulePause()` from being called; it is not a module-level pause and does not execute calls.
     */
    function guardianPause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Restores guardian operations under the default administrator authority.
    /// @dev This contract does not impose a cooldown; operational recovery policy is enforced by the deployment's governance process.
    function guardianUnpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}

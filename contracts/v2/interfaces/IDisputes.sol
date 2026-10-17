// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";

/// @notice Dispute opening and resolution interface.
/// @dev Only the configured dispute authority may resolve a dispute, and the allowed state machine must be enforced before storage changes.
interface IDisputes is IV2Module {
    /// @notice Emitted when a dispute is opened against a claim.
    /// @param disputeId Newly assigned dispute identifier.
    /// @param claimId Disputed claim.
    /// @param opener Account that opened the dispute.
    /// @param reasonHash Digest of the off-chain dispute reason.
    event DisputeOpened(uint256 indexed disputeId, uint256 indexed claimId, address indexed opener, bytes32 reasonHash);

    /// @notice Emitted when an authorized resolver reaches a terminal decision.
    /// @param disputeId Resolved dispute.
    /// @param status Terminal or escalated status selected by the authority.
    /// @param resolver Authorized resolver that made the decision.
    event DisputeResolved(uint256 indexed disputeId, IV2Types.DisputeStatus status, address indexed resolver);

    /// @notice Opens a dispute during the configured challenge window.
    /// @dev Must validate claim existence, window, reason digest, opener authorization, and any required bond before creating the dispute.
    /// @param claimId Claim to dispute.
    /// @param reasonHash Digest of the reason; raw reason data remains off-chain.
    /// @param evidence Opaque evidence commitment or reference bytes.
    /// @return disputeId Newly assigned dispute identifier.
    function openDispute(uint256 claimId, bytes32 reasonHash, bytes calldata evidence) external returns (uint256 disputeId);

    /// @notice Resolves or escalates a dispute under the resolver authority.
    /// @dev Must enforce the configured transition graph, resolver role, and evidence/decision validation; invalid decisions leave state unchanged.
    /// @param disputeId Dispute to update.
    /// @param status New permitted status.
    /// @param decision Opaque decision payload or commitment; the EVM does not infer its meaning.
    function resolveDispute(uint256 disputeId, IV2Types.DisputeStatus status, bytes calldata decision) external;

    /// @notice Reads a dispute record.
    /// @param disputeId Dispute to inspect.
    /// @return dispute Stored dispute fields.
    function getDispute(uint256 disputeId) external view returns (IV2Types.Dispute memory dispute);
}

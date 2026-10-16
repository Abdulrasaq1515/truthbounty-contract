// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";

/// @notice Content-addressed evidence commitment and status interface.
/// @dev The contract stores digests, not raw evidence. Content availability and
///      cryptographic interpretation are external assumptions. Fail-closed on
///      zero digests, duplicates, invalid nonces, closed windows, finalized
///      claims, invalid status transitions, and failed external lookups.
interface IEvidence is IV2Module {
    /// @notice Metadata exceeded the 1 KiB calldata limit.
    /// @param actual Supplied metadata size in bytes.
    /// @param maximum Maximum accepted metadata size in bytes.
    error MetadataTooLarge(uint256 actual, uint256 maximum);

    /// @notice Emitted when an evidence commitment is accepted.
    /// @param evidenceId Deterministically derived evidence identifier.
    /// @param claimId Claim receiving the evidence.
    /// @param submitter Account that supplied the commitment.
    /// @param contentHash Digest of off-chain content.
    event EvidenceSubmitted(uint256 indexed evidenceId, uint256 indexed claimId, address indexed submitter, bytes32 contentHash);

    /// @param evidenceId Evidence whose status changed.
    /// @param previousStatus Status before the change.
    /// @param newStatus Status after the change.
    /// @param actor Authorized administrator.
    event EvidenceStatusChanged(uint256 indexed evidenceId, IV2Types.EvidenceStatus previousStatus, IV2Types.EvidenceStatus newStatus, address indexed actor);

    /// @notice Submits an evidence commitment for an active claim.
    /// @dev Wraps commitEvidence, deriving the metadata digest and contributor nonce automatically.
    /// @param claimId Existing claim receiving evidence.
    /// @param contentHash Digest of off-chain content.
    /// @param metadata Opaque metadata bytes; its keccak256 digest is stored on-chain.
    /// @return evidenceId Deterministically derived identifier.
    function submitEvidence(uint256 claimId, bytes32 contentHash, bytes calldata metadata) external returns (uint256 evidenceId);

    /// @notice Sets the evidence acceptance status under the evidence administrator authority.
    /// @dev Enforces a bounded state-transition matrix: NONE is unreachable as a
    ///      destination, SUBMITTED may transition anywhere except NONE, and a
    ///      terminal status (ACCEPTED / REJECTED / REVOKED) is sticky.
    /// @param evidenceId Evidence to update.
    /// @param status New evidence status.
    function setEvidenceStatus(uint256 evidenceId, IV2Types.EvidenceStatus status) external;

    /// @notice Reads the public evidence record.
    /// @param evidenceId Evidence to read.
    /// @return evidence Public evidence fields; the metadata digest is excluded.
    function getEvidence(uint256 evidenceId) external view returns (IV2Types.Evidence memory evidence);

    /// @notice Returns a bounded page of evidence IDs for a claim.
    /// @dev Pagination follows deterministic insertion order. An out-of-range cursor returns an empty page.
    /// @param claimId Claim whose evidence IDs are read.
    /// @param cursor Zero-based index at which to start.
    /// @param limit Maximum number of IDs to return; must be within the implementation bound.
    /// @return evidenceIds Ordered page of evidence identifiers.
    /// @return nextCursor Cursor for the next page, equal to the claim's count when exhausted.
    function claimEvidence(uint256 claimId, uint256 cursor, uint256 limit) external view returns (uint256[] memory evidenceIds, uint256 nextCursor);

    /// @notice Computes the deterministic identifier for a commitment without storing it.
    /// @dev Domain-separated by chain id, contract address, claim id, contributor, digests, and nonce.
    /// @return evidenceId Deterministic identifier; not an existence proof.
    function computeEvidenceId(uint256 claimId, address contributor, bytes32 contentDigest, bytes32 metadataDigest, uint256 nonce) external view returns (uint256 evidenceId);

    /// @notice Verifies that a caller-supplied commitment tuple matches the stored record
    ///         and that the stored evidenceId matches the domain-separated derivation.
    /// @dev Fails closed unless every field matches and the deterministic ID check passes.
    /// @return ok True only if the record exists and all fields match the derivation.
    function verifyEvidenceCommitment(uint256 evidenceId, uint256 claimId, address contributor, bytes32 contentDigest, bytes32 metadataDigest, uint256 nonce) external view returns (bool ok);

    /// @notice Returns the next required nonce for a contributor.
    function nextContributorNonce(address contributor) external view returns (uint256 nonce);

    /// @notice Returns the number of evidence commitments associated with a claim.
    function evidenceCount(uint256 claimId) external view returns (uint256 count);
}

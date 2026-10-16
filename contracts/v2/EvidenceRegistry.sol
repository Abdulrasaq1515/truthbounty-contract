// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IClaimRegistry} from "../interfaces/IClaimRegistry.sol";
import {ITruthBountyEvents} from "../interfaces/ITruthBountyEvents.sol";
import {EmergencyGuarded} from "./EmergencyGuarded.sol";
import {IEvidence} from "./interfaces/IEvidence.sol";
import {IV2Module} from "./interfaces/IV2Module.sol";
import {IV2Types} from "./interfaces/IV2Types.sol";
import {V2Errors} from "./libraries/V2Errors.sol";
import {V2SafeCast} from "./libraries/V2SafeCast.sol";
import {V2Scopes} from "./libraries/V2Scopes.sol";
import {V2WiredPauseGuard} from "./libraries/V2PauseGuard.sol";
import {PauseMatrix} from "./libraries/PauseMatrix.sol";
import {ProtocolExecutionBounds} from "../performance/ProtocolExecutionBounds.sol";

/// @title EvidenceRegistry
/// @notice Content-addressed V2 evidence commitment registry.
/// @dev Stores only immutable digests and deterministic IDs. Raw evidence
///      content, CIDs, URLs, signatures, and private data stay off-chain.
///      Fail-closed on zero digests, duplicates, invalid nonces, closed windows,
///      finalized claims, paused state, invalid status transitions, and failed
///      external registry lookups.
///
///      Pause matrix (V2-SC-162, `PauseMatrix` v1): evidence submission and
///      adjudication fail closed under the scoped `SCOPE_EVIDENCE` pause of the
///      wired V2 pause authority *and* under this module's local `Pausable`
///      switch (nested pause: either one blocks, lifting one never reopens the
///      other). `pause()` is a protective RISK_REDUCING action; `unpause()` only
///      lifts the local switch and can never override the scoped authority.
contract EvidenceRegistry is ERC165, AccessControl, Pausable, IEvidence, ITruthBountyEvents, V2WiredPauseGuard, EmergencyGuarded {
    bytes32 public constant EVIDENCE_ADMIN_ROLE = keccak256("EVIDENCE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    uint256 public constant MAX_PAGE_SIZE = 100;
    uint256 public constant MAX_EVIDENCE_PER_CLAIM = ProtocolExecutionBounds.MAX_EVIDENCE_PER_CLAIM;
    /// @notice Maximum metadata calldata hashed for one evidence commitment.
    uint256 public constant MAX_METADATA_BYTES = 1_024;

    /// @notice Fixed, domain-separated reason attached to admin-driven pause logs.
    /// @dev `EmergencyPauseActivatedV1` requires a `bytes32 reason`; the pause
    ///      authority for this module is the `PAUSER_ROLE` holder and no
    ///      per-call reason is collected, so the constant keeps the log
    ///      deterministic across deployments.
    bytes32 public constant ADMIN_PAUSE_REASON = keccak256("EVIDENCE_REGISTRY_ADMIN_PAUSE");

    IClaimRegistry public immutable claimRegistry;

    struct EvidenceCommitment {
        uint256 id;
        uint256 claimId;
        address contributor;
        bytes32 contentDigest;
        bytes32 metadataDigest;
        uint256 nonce;
        uint64 committedAt;
        IV2Types.EvidenceStatus status;
    }

    mapping(uint256 => EvidenceCommitment) private _evidenceById;
    mapping(uint256 => uint256[]) private _claimEvidenceIds;
    mapping(address => uint256) private _nextContributorNonce;
    mapping(bytes32 => bool) private _commitmentExists;


    /// @notice Constructor was given a zero administrator.
    error ZeroAdmin();
    error ZeroClaimRegistry();
    error ZeroDigest();
    error InvalidClaim(uint256 claimId);
    error EvidenceWindowClosed(uint256 claimId, uint64 deadline, uint64 timestamp);
    error ClaimFinalized(uint256 claimId, IClaimRegistry.ClaimStatus status);
    error InvalidNonce(address contributor, uint256 expected, uint256 provided);
    error DuplicateEvidence(bytes32 commitmentKey);
    error EvidenceNotFound(uint256 evidenceId);
    error InvalidPageLimit(uint256 limit);
    error EvidenceLimitReached(uint256 claimId, uint256 max);
    /// @notice Attempted evidence status transition is forbidden by the state machine.
    /// @param evidenceId Evidence whose transition was rejected.
    /// @param from Current status.
    /// @param to Requested destination status.
    error InvalidEvidenceStatusTransition(uint256 evidenceId, IV2Types.EvidenceStatus from, IV2Types.EvidenceStatus to);
    /// @notice Stored evidence commitment failed the content-addressed integrity check.
    /// @param evidenceId Evidence identifier whose derivation mismatched.
    error CommitmentIdMismatch(uint256 evidenceId);
    /// @notice Caller-supplied commitment tuple does not match the stored record.
    /// @param evidenceId Evidence identifier that failed verification.
    error CommitmentVerificationFailed(uint256 evidenceId);
    /// @notice External claim registry returned an inconsistent claim record.
    /// @param claimId Claim whose existence flag and record disagreed.
    error ClaimRegistryInconsistent(uint256 claimId);

    /// @param claimId Claim receiving the evidence.
    /// @param evidenceId Deterministic evidence identifier.
    /// @param contributor Account that committed the evidence.
    /// @param contentDigest Digest of off-chain content.
    /// @param metadataDigest Digest of off-chain metadata.
    /// @param nonce Contributor sequence number used for identity derivation.
    /// @param timestamp Commit timestamp in Unix seconds.
    /// @param version Event schema version.
    event EvidenceCommitted(
        uint256 indexed claimId,
        uint256 indexed evidenceId,
        address indexed contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 nonce,
        uint64 timestamp,
        uint16 version
    );

    /// @param initialAdmin Account receiving default admin, evidence admin, and pauser roles.
    /// @param claimRegistry_ Claim registry consulted for claim existence and deadlines.
    constructor(address initialAdmin, address claimRegistry_) {
        if (initialAdmin == address(0)) revert V2Errors.ZeroAdmin();
        if (claimRegistry_ == address(0)) revert V2Errors.ZeroClaimRegistry();

        claimRegistry = IClaimRegistry(claimRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(EVIDENCE_ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    /// @inheritdoc IV2Module
    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    /// @param interfaceId Interface identifier to query.
    /// @return supported True when the interface is implemented.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, AccessControl, IERC165) returns (bool supported) {
        return
            interfaceId == type(IV2Module).interfaceId ||
            interfaceId == type(IEvidence).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @notice Wires this registry to the canonical emergency control plane.
    /// @dev Deliberately not emergency-guarded: governance must be able to repair the reference
    ///      while the module is paused. Until this is called, every guarded mutation reverts.
    function setEmergencyControls(address controls) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setEmergencyControls(controls);
    }

    /// @inheritdoc IEvidence
    function submitEvidence(uint256 claimId, bytes32 contentHash, bytes calldata metadata)
        external
        override
        returns (uint256 evidenceId)
    {
        if (metadata.length > MAX_METADATA_BYTES) {
            revert MetadataTooLarge(metadata.length, MAX_METADATA_BYTES);
        }
        return commitEvidence(claimId, contentHash, keccak256(metadata), _nextContributorNonce[msg.sender]);
    }

    /// @notice Commit evidence digests to an existing claim.
    /// @dev Permissionless when the claim is active and unpaused.  ID derivation is
    ///      domain-separated by chain, contract, claim, contributor, digests, and
    ///      nonce.  Duplicates are rejected per (claim, contributor, digests).  The
    ///      nonce must equal the contributor's next sequential nonce.  The derived
    ///      evidenceId is asserted against the stored record for integrity.
    /// @param claimId Existing claim that receives the evidence commitment.
    /// @param contentDigest Digest of the off-chain evidence content.
    /// @param metadataDigest Digest of off-chain evidence metadata.
    /// @param nonce Contributor nonce used in deterministic evidence ID derivation.
    /// @return evidenceId Deterministic ID bound to the commitment and contributor nonce.
    function commitEvidence(uint256 claimId, bytes32 contentDigest, bytes32 metadataDigest, uint256 nonce)
        public
        whenOperationAllowed(V2Scopes.EVIDENCE_SUBMISSION)
        returns (uint256 evidenceId)
    {
        _requireScopeNotPaused(PauseMatrix.SCOPE_EVIDENCE);
        if (contentDigest == bytes32(0) || metadataDigest == bytes32(0)) revert V2Errors.ZeroDigest();
        if (!claimRegistry.claimExists(claimId)) revert V2Errors.InvalidClaim(claimId);

        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);
        if (!_acceptsEvidence(claim.status)) revert V2Errors.ClaimFinalized(claimId, uint8(claim.status));

        // V2-SC-161: `committedAt` is uint64; never truncate the clock into storage.
        uint64 now_ = V2SafeCast.timestamp64(V2SafeCast.FIELD_EVIDENCE_COMMITTED_AT);
        if (now_ > claim.verificationDeadline) {
            revert V2Errors.EvidenceWindowClosed(claimId, claim.verificationDeadline, now_);
        }

        uint256 expectedNonce = _nextContributorNonce[msg.sender];
        if (nonce != expectedNonce) revert V2Errors.InvalidNonce(msg.sender, expectedNonce, nonce);

        bytes32 commitmentKey = keccak256(abi.encode(claimId, msg.sender, contentDigest, metadataDigest));
        if (_commitmentExists[commitmentKey]) revert V2Errors.DuplicateEvidence(commitmentKey);
        if (_claimEvidenceIds[claimId].length >= MAX_EVIDENCE_PER_CLAIM) {
            revert EvidenceLimitReached(claimId, MAX_EVIDENCE_PER_CLAIM);
        }

        evidenceId = computeEvidenceId(claimId, msg.sender, contentDigest, metadataDigest, nonce);
        if (_evidenceById[evidenceId].status != IV2Types.EvidenceStatus.NONE) {
            revert CommitmentIdMismatch(evidenceId);
        }

        _commitmentExists[commitmentKey] = true;
        _nextContributorNonce[msg.sender] = nonce + 1;
        assert(_nextContributorNonce[msg.sender] == nonce + 1);

        _evidenceById[evidenceId] = EvidenceCommitment({
            id: evidenceId,
            claimId: claimId,
            contributor: msg.sender,
            contentDigest: contentDigest,
            metadataDigest: metadataDigest,
            nonce: nonce,
            committedAt: now_,
            status: IV2Types.EvidenceStatus.SUBMITTED
        });
        _claimEvidenceIds[claimId].push(evidenceId);

        EvidenceCommitment storage stored = _evidenceById[evidenceId];
        if (stored.id != evidenceId || stored.contributor != msg.sender || stored.nonce != nonce) {
            revert CommitmentIdMismatch(evidenceId);
        }

        emit EvidenceSubmitted(evidenceId, claimId, msg.sender, contentDigest);
        emit EvidenceSubmittedV1(claimId, evidenceId, msg.sender, contentDigest, now_, EVENT_SCHEMA_VERSION);
        emit EvidenceCommitted(
            claimId, evidenceId, msg.sender, contentDigest, metadataDigest, nonce, now_, EVENT_SCHEMA_VERSION
        );
    }

    /// @notice Sets the evidence acceptance status under the evidence administrator authority.
    /// @dev Enforces a bounded state-transition matrix: NONE is unreachable as a
    ///      destination, SUBMITTED may transition anywhere except NONE, and a
    ///      terminal status (ACCEPTED / REJECTED / REVOKED) is sticky.
    /// @param evidenceId Evidence to update.
    /// @param status New evidence status.
    function setEvidenceStatus(uint256 evidenceId, IV2Types.EvidenceStatus status)
        external
        override
        onlyRole(EVIDENCE_ADMIN_ROLE)
        whenOperationAllowed(V2Scopes.EVIDENCE_STATUS)
    {
        _requireScopeNotPaused(PauseMatrix.SCOPE_EVIDENCE);
        EvidenceCommitment storage evidence = _evidenceById[evidenceId];
        if (evidence.status == IV2Types.EvidenceStatus.NONE) revert V2Errors.EvidenceNotFound(evidenceId);

        IV2Types.EvidenceStatus previous = evidence.status;
        if (!_isAllowedStatusTransition(previous, status)) {
            revert InvalidEvidenceStatusTransition(evidenceId, previous, status);
        }
        evidence.status = status;
        emit EvidenceStatusChanged(evidenceId, previous, status, msg.sender);
    }

    /// @inheritdoc IEvidence
    function getEvidence(uint256 evidenceId) external view override returns (IV2Types.Evidence memory) {
        EvidenceCommitment storage evidence = _existingEvidence(evidenceId);
        return IV2Types.Evidence({
            id: evidence.id,
            claimId: evidence.claimId,
            submitter: evidence.contributor,
            contentHash: evidence.contentDigest,
            submittedAt: evidence.committedAt,
            status: evidence.status
        });
    }

    /// @notice Returns the full digest commitment for an evidence ID.
    /// @param evidenceId Evidence identifier to read.
    /// @return commitment Full commitment including metadata digest and contributor nonce.
    function getEvidenceCommitment(uint256 evidenceId) external view returns (EvidenceCommitment memory commitment) {
        return _existingEvidence(evidenceId);
    }

    /// @notice Verifies that a caller-supplied commitment tuple matches the stored record
    ///         and that the stored evidenceId matches the domain-separated derivation.
    /// @dev Fails closed unless every field matches and the deterministic ID check passes.
    /// @param evidenceId Evidence identifier to verify.
    /// @param claimId Expected claim identifier.
    /// @param contributor Expected contributor.
    /// @param contentDigest Expected content digest.
    /// @param metadataDigest Expected metadata digest.
    /// @param nonce Expected contributor nonce.
    /// @return ok True only if the record exists and all fields match the derivation.
    function verifyEvidenceCommitment(
        uint256 evidenceId,
        uint256 claimId,
        address contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 nonce
    ) external view returns (bool ok) {
        EvidenceCommitment storage evidence = _existingEvidence(evidenceId);
        if (
            evidence.claimId != claimId ||
            evidence.contributor != contributor ||
            evidence.contentDigest != contentDigest ||
            evidence.metadataDigest != metadataDigest ||
            evidence.nonce != nonce
        ) {
            revert CommitmentVerificationFailed(evidenceId);
        }
        uint256 expectedId = computeEvidenceId(claimId, contributor, contentDigest, metadataDigest, nonce);
        if (expectedId != evidenceId) revert CommitmentVerificationFailed(evidenceId);
        return true;
    }

    /// @inheritdoc IEvidence
    function claimEvidence(uint256 claimId, uint256 cursor, uint256 limit)
        external
        view
        override
        returns (uint256[] memory evidenceIds, uint256 nextCursor)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert V2Errors.InvalidPageLimit(limit);

        uint256[] storage ids = _claimEvidenceIds[claimId];
        uint256 length = ids.length;
        if (cursor >= length) return (new uint256[](0), length);

        uint256 end = cursor + limit;
        if (end > length) end = length;

        evidenceIds = new uint256[](end - cursor);
        for (uint256 i = cursor; i < end;) {
            evidenceIds[i - cursor] = ids[i];
            unchecked {
                ++i;
            }
        }

        return (evidenceIds, end);
    }

    /// @notice Computes the deterministic identifier for a commitment without storing it.
    /// @dev Domain-separated by chain id, contract address, claim id, contributor,
    ///      content digest, metadata digest, and contributor nonce.  The result is
    ///      not an existence proof; call verifyEvidenceCommitment for that.
    /// @param claimId Claim identifier.
    /// @param contributor Contributor address.
    /// @param contentDigest Content digest.
    /// @param metadataDigest Metadata digest.
    /// @param nonce Contributor sequence number.
    /// @return evidenceId Deterministic identifier.
    function computeEvidenceId(
        uint256 claimId,
        address contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 nonce
    ) public view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(block.chainid, address(this), claimId, contributor, contentDigest, metadataDigest, nonce)
            )
        );
    }

    /// @notice Returns the next required nonce for a contributor.
    /// @param contributor Contributor address.
    /// @return nonce Next nonce accepted for that contributor.
    function nextContributorNonce(address contributor) external view returns (uint256 nonce) {
        return _nextContributorNonce[contributor];
    }

    /// @notice Returns the number of evidence commitments associated with a claim.
    /// @param claimId Claim to inspect.
    /// @return count Commitment count.
    function evidenceCount(uint256 claimId) external view returns (uint256 count) {
        return _claimEvidenceIds[claimId].length;
    }

    /// @notice Pauses evidence submission; existing evidence remains readable.
    /// @dev Pausing is fail-closed for commit operations and is restricted to `PAUSER_ROLE`.
    ///      Emits `EmergencyPauseActivatedV1`: the pause flag gates every
    ///      `commitEvidence` call, so it is an authoritative read cell
    ///      (V2-SC-132) and is published as a canonical family-15 log instead of
    ///      mutating silently.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit EmergencyPauseActivatedV1(msg.sender, ADMIN_PAUSE_REASON, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Resumes evidence submission after the pauser restores the registry.
    /// @dev Lifts only the module-local switch; a scoped `SCOPE_EVIDENCE` pause on the wired
    ///      V2 pause authority keeps submission fail-closed (V2-SC-162).
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit EmergencyPauseRecoveredV1(msg.sender, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Wires the V2 pause authority exactly once (V2-SC-162).
    /// @dev NEUTRAL: wiring only tightens control and can never be replaced or removed.
    /// @param authority `IEmergencyControls` implementation (e.g. `EmergencyGatekeeper`).
    function setPauseAuthority(address authority) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _wirePauseAuthority(authority);
    }

    function _loadClaimOrRevert(uint256 claimId) private view returns (IClaimRegistry.Claim memory claim) {
        bool exists = claimRegistry.claimExists(claimId);
        if (!exists) revert InvalidClaim(claimId);
        claim = claimRegistry.getClaim(claimId);
        if (claim.id != claimId) revert ClaimRegistryInconsistent(claimId);
    }

    function _existingEvidence(uint256 evidenceId) private view returns (EvidenceCommitment storage evidence) {
        evidence = _evidenceById[evidenceId];
        if (evidence.status == IV2Types.EvidenceStatus.NONE) revert V2Errors.EvidenceNotFound(evidenceId);
    }

    function _acceptsEvidence(IClaimRegistry.ClaimStatus status) private pure returns (bool) {
        return status == IClaimRegistry.ClaimStatus.Pending || status == IClaimRegistry.ClaimStatus.UnderVerification;
    }

    function _isAllowedStatusTransition(IV2Types.EvidenceStatus from, IV2Types.EvidenceStatus to)
        private
        pure
        returns (bool)
    {
        if (to == IV2Types.EvidenceStatus.NONE) return false;
        if (from == IV2Types.EvidenceStatus.SUBMITTED) return true;
        if (from == to) return true;
        return false;
    }
}

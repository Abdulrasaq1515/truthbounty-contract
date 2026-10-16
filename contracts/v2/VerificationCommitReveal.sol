// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SignatureNonces} from "./SignatureNonces.sol";
import {V2ReplayDomain} from "./libraries/V2ReplayDomain.sol";

/// @title VerificationCommitReveal
/// @notice PREWAVE-SC-085: a verifier's commitment can be revealed exactly once. A second reveal, a
///         changed decision or rationale, a wrong salt / verifier / round, and a replayed signature
///         are all rejected without touching stored state.
/// @dev Each `(verifier, claimId, roundId)` slot holds at most one commitment for its whole life:
///      `commit` can never overwrite it and `reveal` moves it `Committed -> Revealed` once.
///      Commitments use `abi.encode` (never `abi.encodePacked`) and bind chain id, this contract,
///      the verifier, claim, round, decision, rationale hash and salt.
///      Events preserve privacy until reveal (only the commitment hash is emitted on commit) and
///      never emit the salt. A revert rolls back everything, so a failed reveal leaves the
///      commitment (and any signature nonce) exactly as it was.
///      This is a self-contained building block: it does not change any existing V2 module.
contract VerificationCommitReveal is SignatureNonces {
    /// @notice Lifecycle of one commitment slot.
    enum Status {
        None,
        Committed,
        Revealed
    }

    /// @notice Stored state of one commitment slot.
    struct Record {
        Status status;
        bytes32 commitment;
        bool decision; // only meaningful once status == Revealed
        bytes32 rationaleHash; // only meaningful once status == Revealed
        uint64 committedAt;
        uint64 revealedAt;
    }

    /// @notice Domain tag mixed into every commitment.
    bytes32 public constant COMMITMENT_TYPEHASH = keccak256(
        "VerificationCommitment(uint256 chainId,address verifyingContract,address verifier,uint256 claimId,uint256 roundId,bool decision,bytes32 rationaleHash,bytes32 salt)"
    );

    /// @notice Replay-domain action type for relayed (signed) reveals.
    bytes32 public constant REVEAL_ACTION = keccak256("verification_reveal");

    /// @dev key = keccak256(abi.encode(verifier, claimId, roundId))
    mapping(bytes32 => Record) private _records;

    /// @notice Emitted on commit. Carries only the hash, so the decision stays private.
    event Committed(address indexed verifier, uint256 indexed claimId, uint256 indexed roundId, bytes32 commitment);

    /// @notice Emitted once per commitment, when it is revealed. Never includes the salt.
    event Revealed(
        address indexed verifier,
        uint256 indexed claimId,
        uint256 indexed roundId,
        bytes32 commitment,
        bool decision,
        bytes32 rationaleHash
    );

    /// @notice The commitment hash is zero.
    error ZeroCommitment();
    /// @notice The salt is zero (trivially guessable commitments are refused).
    error ZeroSalt();
    /// @notice This verifier already has a commitment for this claim and round.
    error CommitmentAlreadyExists();
    /// @notice No commitment exists for this verifier, claim and round.
    error NoCommitment();
    /// @notice The commitment was already revealed; it settles only once.
    error AlreadyRevealed();
    /// @notice The revealed fields do not hash to the stored commitment.
    error CommitmentMismatch();
    /// @notice The signature is malformed or was not made by the stated verifier for this reveal.
    error InvalidSignature();

    // ---------------------------------------------------------------------------------------
    // Commit
    // ---------------------------------------------------------------------------------------

    /// @notice Stores the caller's commitment for `(claimId, roundId)`.
    /// @dev The slot is write-once: an existing commitment (revealed or not) can never be replaced.
    function commit(uint256 claimId, uint256 roundId, bytes32 commitment) external {
        if (commitment == bytes32(0)) revert ZeroCommitment();
        bytes32 key = _key(msg.sender, claimId, roundId);
        Record storage rec = _records[key];
        if (rec.status != Status.None) revert CommitmentAlreadyExists();

        rec.status = Status.Committed;
        rec.commitment = commitment;
        rec.committedAt = uint64(block.timestamp);

        emit Committed(msg.sender, claimId, roundId, commitment);
    }

    // ---------------------------------------------------------------------------------------
    // Reveal
    // ---------------------------------------------------------------------------------------

    /// @notice Reveals the caller's own commitment. Settles once.
    function reveal(uint256 claimId, uint256 roundId, bool decision, bytes32 rationaleHash, bytes32 salt) external {
        _reveal(msg.sender, claimId, roundId, decision, rationaleHash, salt);
    }

    /// @notice Reveals `verifier`'s commitment on their behalf using their signature.
    /// @dev The signed digest binds action, this contract, chain id, signer, the commitment hash,
    ///      a single-use nonce and a deadline. Replays fail because the nonce is consumed and the
    ///      commitment can only be revealed once.
    function revealWithSignature(
        address verifier,
        uint256 claimId,
        uint256 roundId,
        bool decision,
        bytes32 rationaleHash,
        bytes32 salt,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        // Cheap state checks first; the full reveal logic below re-checks them.
        Record storage rec = _records[_key(verifier, claimId, roundId)];
        if (rec.status == Status.None) revert NoCommitment();
        if (rec.status == Status.Revealed) revert AlreadyRevealed();

        bytes32 commitment = computeCommitment(verifier, claimId, roundId, decision, rationaleHash, salt);
        bytes32 digest =
            V2ReplayDomain.liveDigest(REVEAL_ACTION, address(this), verifier, uint256(commitment), nonce, deadline);
        if (_recover(digest, signature) != verifier) revert InvalidSignature();

        _useCheckedNonce(verifier, nonce, deadline);
        _reveal(verifier, claimId, roundId, decision, rationaleHash, salt);
    }

    function _reveal(
        address verifier,
        uint256 claimId,
        uint256 roundId,
        bool decision,
        bytes32 rationaleHash,
        bytes32 salt
    ) private {
        if (salt == bytes32(0)) revert ZeroSalt();

        Record storage rec = _records[_key(verifier, claimId, roundId)];
        if (rec.status == Status.None) revert NoCommitment();
        if (rec.status == Status.Revealed) revert AlreadyRevealed();

        bytes32 expected = computeCommitment(verifier, claimId, roundId, decision, rationaleHash, salt);
        if (expected != rec.commitment) revert CommitmentMismatch();

        rec.status = Status.Revealed;
        rec.decision = decision;
        rec.rationaleHash = rationaleHash;
        rec.revealedAt = uint64(block.timestamp);

        emit Revealed(verifier, claimId, roundId, expected, decision, rationaleHash);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice Computes the commitment a verifier must store to later reveal these exact fields.
    function computeCommitment(
        address verifier,
        uint256 claimId,
        uint256 roundId,
        bool decision,
        bytes32 rationaleHash,
        bytes32 salt
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                COMMITMENT_TYPEHASH,
                block.chainid,
                address(this),
                verifier,
                claimId,
                roundId,
                decision,
                rationaleHash,
                salt
            )
        );
    }

    /// @notice Reads the stored record for a slot.
    function getRecord(address verifier, uint256 claimId, uint256 roundId) external view returns (Record memory) {
        return _records[_key(verifier, claimId, roundId)];
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _key(address verifier, uint256 claimId, uint256 roundId) private pure returns (bytes32) {
        return keccak256(abi.encode(verifier, claimId, roundId));
    }

    /// @dev Strict ECDSA recovery: 65-byte signatures, canonical low-s, v in {27, 28}.
    ///      Returns address(0) on any malformed input so the caller can fail closed.
    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/ITruthBountyEvents.sol";
import {V2SafeCast} from "../v2/libraries/V2SafeCast.sol";

/// @title CanonicalEventLibrary
/// @notice Helper library providing protocol-wide event schema constants and validation utilities.
library CanonicalEventLibrary {
    /// @notice Canonical schema version for all V1 events.
    uint16 public constant EVENT_SCHEMA_VERSION_V1 = 1;

    /// @notice Protocol release identifier commitment.
    bytes32 public constant PROTOCOL_RELEASE_V2 = keccak256("TRUTH_BOUNTY_V2");

    /// @notice Returns current block timestamp as uint64 seconds for event emission.
    /// @dev V2-SC-161: fails closed with `V2Errors.SafeCastOverflow` instead of truncating.
    function currentTimestamp() internal view returns (uint64) {
        return V2SafeCast.timestamp64(V2SafeCast.FIELD_CANONICAL_EVENT_TIMESTAMP);
    }

    /// @notice Computes a deterministic metadata hash for off-chain content references.
    /// @param data Raw payload or URI string bytes.
    /// @return hash Keccak256 commitment of the data.
    function computeMetadataHash(bytes memory data) internal pure returns (bytes32 hash) {
        return keccak256(data);
    }

    /// @notice Version tag of the operation-identifier scheme (V2-SC-160).
    /// @dev = 0x8c64e5c5cfa178c0038b286a8308bc8123d76ea44174910a08ded4a9b9cf443e. It is the first
    ///      ABI word of every V2 operation-id preimage, so a V2 id can never equal an id produced by
    ///      the retired V1 packed scheme (whose preimage starts with the raw `domain` bytes), nor a
    ///      digest of any other TruthBounty commitment schema.
    bytes32 public constant OPERATION_ID_SCHEME_V2 =
        keccak256("TruthBounty.CanonicalEventLibrary.operationId.v2");

    /// @notice Computes a deterministic operation identifier for financial/treasury actions.
    /// @dev V2-SC-160: typed, length-delimited `abi.encode` under `OPERATION_ID_SCHEME_V2`.
    ///      The retired V1 packed form let a caller-chosen `domain` absorb bytes of another
    ///      packed schema (e.g. the V1 upgrade proposal id), producing cross-schema collisions;
    ///      see docs/ENCODE_PACKED_POLICY.md and test/vectors/encode-packed-commitments.vectors.json.
    ///      Off-chain: keccak256(AbiCoder.encode(["bytes32","string","uint256","address"],
    ///      [OPERATION_ID_SCHEME_V2, domain, nonce, actor])).
    /// @param domain Domain separator string (e.g. "TREASURY_TRANSFER", "WITHDRAWAL").
    /// @param nonce Monotonic or unique counter.
    /// @param actor Primary entity or operator address.
    /// @return opId Deterministic 32-byte unique operation identifier.
    function computeOperationId(
        string memory domain,
        uint256 nonce,
        address actor
    ) internal pure returns (bytes32 opId) {
        return keccak256(abi.encode(OPERATION_ID_SCHEME_V2, domain, nonce, actor));
    }
}

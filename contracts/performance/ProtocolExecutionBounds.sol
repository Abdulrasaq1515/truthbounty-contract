// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ProtocolExecutionBounds
 * @notice Canonical V2 participant, page, and loop bounds (V2-SC-038).
 * @dev Single source of truth for maximum configuration used in gas benchmarking
 *      and denial-of-service analysis. Module-local constants should match these
 *      values or document intentional divergence.
 */
library ProtocolExecutionBounds {
    /// @notice Maximum verifications aggregated per claim (VerificationAggregation).
    uint256 internal constant MAX_VERIFIERS_PER_CLAIM = 200;

    /// @notice Maximum evidence attachments per claim (EvidenceManager).
    uint256 internal constant MAX_EVIDENCE_PER_CLAIM = 100;

    /// @notice Maximum assets allowed in one published parameter version.
    uint256 internal constant MAX_SUPPORTED_ASSETS = 16;

    /// @notice Maximum treasury batch payout rows (TruthBountyClaims).
    uint256 internal constant MAX_SETTLEMENT_BATCH_SIZE = 200;

    /// @notice Maximum reward distribution batch size (RewardEngine).
    uint256 internal constant MAX_REWARD_BATCH_SIZE = 100;

    /// @notice Maximum tokenomics distribution batch size.
    uint256 internal constant MAX_TOKENOMICS_BATCH_SIZE = 50;

    /// @notice Maximum insurance payout page size.
    uint256 internal constant MAX_INSURANCE_PAGE_SIZE = 200;

    /// @notice Maximum claim statement length in bytes (ClaimRegistry).
    uint256 internal constant MAX_CLAIM_STATEMENT_BYTES = 2000;

    /// @notice Maximum evidence CID length in bytes (ClaimRegistry / EvidenceManager).
    uint256 internal constant MAX_EVIDENCE_CID_BYTES = 512;

    /// @notice Block gas limit reference used for budget sanity checks (30M post-merge mainnet).
    uint256 internal constant REFERENCE_BLOCK_GAS_LIMIT = 30_000_000;

    /// @notice Recommended maximum gas for a single critical-path transaction at max config.
    uint256 internal constant RECOMMENDED_TX_GAS_CEILING = 12_000_000;

    /// @notice Maximum claim creations per account inside one spam window (V2-SC-105).
    uint256 internal constant MAX_CLAIMS_PER_ACCOUNT_WINDOW = 10;

    /// @notice Sliding window length for claim-creation rate limiting (V2-SC-105).
    uint256 internal constant CLAIM_SPAM_WINDOW_SECONDS = 1 hours;

    /// @notice Maximum concurrently open (non-terminal) claims per creator (V2-SC-105).
    uint256 internal constant MAX_OPEN_CLAIMS_PER_CREATOR = 25;

    /// @notice Default minimum verifier stake to reject dust griefing (V2-SC-105).
    uint256 internal constant DEFAULT_MIN_STAKE_AMOUNT = 1 ether;

    /// @notice Default minimum claim bounty / reward (V2-SC-105).
    uint256 internal constant DEFAULT_MIN_BOUNTY_AMOUNT = 1 ether;
}

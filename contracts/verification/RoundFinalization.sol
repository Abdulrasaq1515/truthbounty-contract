// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// =============================================================================
//  PREWAVE-SC-046 — Quorum, Tie, and Insufficient-Evidence Finalization
//  Issue #722
//
//  Defines the canonical, machine-readable finalization state machine for a
//  V2 verification round.  Every terminal outcome is mapped to:
//    1. A named TerminalState enum value  (machine-readable)
//    2. An economic consequence enum       (what happens to staked principal)
//    3. A frozen quorum denominator        (BPS_DENOMINATOR = 10_000, immutable)
//
//  Design invariants
//  -----------------
//  - Quorum denominator is a module-level constant: can never be changed by
//    governance, an admin, or an upgrade.
//  - Aggregation is order-independent: weight totals are accumulated by
//    simple addition; outcome depends only on the final totals, not on the
//    iteration order.
//  - No provisional result is ever emitted as FINAL before the challenge
//    window has elapsed (enforced by the PROVISIONAL_NOT_FINAL guard).
//  - Tie always produces INCONCLUSIVE_TIE regardless of total weight size.
//  - Zero participation and insufficient evidence produce their own named
//    states so downstream consumers can distinguish them.
// =============================================================================

import {ParticipationThresholdTypes} from "./ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "./ParticipationConfidenceRules.sol";

/**
 * @title RoundFinalization
 * @notice Pure library that converts aggregated weight totals and a frozen
 *         round config into a canonical, machine-readable finalization record.
 *
 * @dev All arithmetic uses the frozen BPS_DENOMINATOR = 10_000.  No external
 *      calls, no state mutations.  Designed to be called from the
 *      ParticipationThresholdEngine after aggregation completes.
 */
library RoundFinalization {
    // =========================================================================
    // Frozen quorum denominator
    // =========================================================================

    /// @notice Basis-point denominator used for every confidence and quorum
    ///         calculation in this module.  This value is FROZEN — it is a
    ///         compile-time constant and cannot be altered by governance.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // =========================================================================
    // Terminal state enum  (machine-readable finalization output)
    // =========================================================================

    /**
     * @notice Every possible terminal outcome of a verification round.
     *
     * VERIFIED_TRUE            Quorum met, confidence >= threshold, TRUE wins.
     * VERIFIED_FALSE           Quorum met, confidence >= threshold, FALSE wins.
     * INCONCLUSIVE_TIE         Both sides have exactly equal weight.
     * INCONCLUSIVE_ZERO        No verifier participated (zero weight, zero count).
     * INCONCLUSIVE_INSUFFICIENT Quorum not met (count < min or weight < min).
     * INCONCLUSIVE_LOW_CONFIDENCE Quorum met but confidence < threshold.
     */
    enum TerminalState {
        VERIFIED_TRUE,
        VERIFIED_FALSE,
        INCONCLUSIVE_TIE,
        INCONCLUSIVE_ZERO,
        INCONCLUSIVE_INSUFFICIENT,
        INCONCLUSIVE_LOW_CONFIDENCE
    }

    // =========================================================================
    // Economic consequence enum
    // =========================================================================

    /**
     * @notice Maps each terminal state to a stake-custody consequence.
     *
     * REWARD_WINNERS_SLASH_LOSERS  Winning verifiers receive rewards;
     *                               losers are slashed.
     * FULL_REFUND                  All verifiers receive their principal back
     *                               unchanged (tie / inconclusive).
     * PARTIAL_SLASH_NO_REWARD      Losers slashed but no winners share
     *                               (reserved for future governance use;
     *                               not currently triggered by any terminal state).
     */
    enum EconomicOutcome {
        REWARD_WINNERS_SLASH_LOSERS,
        FULL_REFUND,
        PARTIAL_SLASH_NO_REWARD
    }

    // =========================================================================
    // Finalization record
    // =========================================================================

    /**
     * @notice The canonical, machine-readable finalization record produced at
     *         the end of a verification round.
     *
     * @param state              Terminal state (see TerminalState).
     * @param economic           Economic consequence (see EconomicOutcome).
     * @param trueWeight         Total weight of TRUE verifications.
     * @param falseWeight        Total weight of FALSE verifications.
     * @param totalWeight        trueWeight + falseWeight.
     * @param verifierCount      Number of distinct verifiers that participated.
     * @param confidenceBps      Winning confidence in basis points (0 if inconclusive).
     * @param quorumDenominator  Always BPS_DENOMINATOR (10 000); frozen snapshot
     *                           embedded in every record for off-chain verifiability.
     * @param effectiveMinCount  Minimum verifier count that was required.
     * @param effectiveMinWeight Minimum total weight that was required.
     * @param effectiveMinConf   Minimum confidence (bps) that was required.
     * @param isProvisional      True when the challenge window has NOT yet elapsed.
     *                           A provisional record MUST NOT be treated as final
     *                           by settlement or reward modules.
     */
    struct FinalizationRecord {
        TerminalState state;
        EconomicOutcome economic;
        uint256 trueWeight;
        uint256 falseWeight;
        uint256 totalWeight;
        uint256 verifierCount;
        uint256 confidenceBps;
        uint256 quorumDenominator;
        uint256 effectiveMinCount;
        uint256 effectiveMinWeight;
        uint256 effectiveMinConf;
        bool isProvisional;
    }

    // =========================================================================
    // Custom errors
    // =========================================================================

    /// @notice Reverts when a caller attempts to treat a provisional record
    ///         as final before the challenge window has elapsed.
    error ProvisionalNotFinal();

    /// @notice Reverts when confidence basis points exceed BPS_DENOMINATOR.
    error InvalidConfidenceBps(uint256 value);

    /// @notice Reverts when appealMultiplierBps is zero (would collapse thresholds).
    error InvalidAppealMultiplierBps(uint256 value);

    // =========================================================================
    // Core function
    // =========================================================================

    /**
     * @notice Evaluate a set of weight totals against a frozen round config and
     *         return a fully populated FinalizationRecord.
     *
     * @dev This function is the single source of truth for all finalization
     *      decisions.  It is pure (no state reads or writes) so it can be
     *      called in view or pure contexts, or from within a state-changing
     *      function without side-effects.
     *
     *      Order independence guarantee: `weights` must be produced by a
     *      simple accumulation loop (trueWeight += w_i for supporters,
     *      falseWeight += w_i for opponents).  Since addition is commutative
     *      and associative, the result is identical for any permutation of
     *      verifier submission order.
     *
     * @param weights    Aggregated weight totals (from VerificationAggregator).
     * @param config     Frozen threshold config for this round.
     * @param roundKind  FIRST or APPEAL (affects effective minimums).
     * @param challengeWindowElapsed  True when block.timestamp >= challengeDeadline.
     *                                Callers must pass the correct value; the library
     *                                does not read block.timestamp.
     * @return record    The canonical finalization record.
     */
    function finalize(
        ParticipationThresholdTypes.WeightTotals memory weights,
        ParticipationThresholdTypes.FrozenRoundConfig memory config,
        ParticipationThresholdTypes.RoundKind roundKind,
        bool challengeWindowElapsed
    ) internal pure returns (FinalizationRecord memory record) {
        // 1. Delegate threshold evaluation to the canonical confidence rules
        ParticipationThresholdTypes.ThresholdEvaluation memory eval =
            ParticipationConfidenceRules.evaluate(weights, config, roundKind);

        // 2. Populate weight fields
        record.trueWeight    = eval.trueWeight;
        record.falseWeight   = eval.falseWeight;
        record.totalWeight   = eval.totalWeight;
        record.verifierCount = weights.verifierCount;
        record.confidenceBps = eval.confidenceBps;

        // 3. Frozen denominator snapshot — always 10 000
        record.quorumDenominator = BPS_DENOMINATOR;

        // 4. Effective threshold snapshot (from frozen config)
        record.effectiveMinCount  = eval.effectiveMinVerifierCount;
        record.effectiveMinWeight = eval.effectiveMinTotalWeight;
        record.effectiveMinConf   = eval.effectiveMinConfidenceBps;

        // 5. Map ParticipationThresholdTypes outcome to TerminalState
        if (eval.outcome == ParticipationThresholdTypes.ClaimOutcome.VERIFIED_TRUE) {
            record.state    = TerminalState.VERIFIED_TRUE;
            record.economic = EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS;

        } else if (eval.outcome == ParticipationThresholdTypes.ClaimOutcome.VERIFIED_FALSE) {
            record.state    = TerminalState.VERIFIED_FALSE;
            record.economic = EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS;

        } else {
            // INCONCLUSIVE — distinguish the specific reason
            record.economic = EconomicOutcome.FULL_REFUND;

            if (eval.reason == ParticipationThresholdTypes.InconclusiveReason.ZERO_PARTICIPATION) {
                record.state = TerminalState.INCONCLUSIVE_ZERO;

            } else if (eval.reason == ParticipationThresholdTypes.InconclusiveReason.TIE) {
                record.state = TerminalState.INCONCLUSIVE_TIE;

            } else if (eval.reason == ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_CONFIDENCE) {
                record.state = TerminalState.INCONCLUSIVE_LOW_CONFIDENCE;

            } else {
                // INSUFFICIENT_VERIFIER_COUNT or INSUFFICIENT_TOTAL_WEIGHT
                record.state = TerminalState.INCONCLUSIVE_INSUFFICIENT;
            }
        }

        // 6. Provisional guard
        record.isProvisional = !challengeWindowElapsed;
    }

    // =========================================================================
    // Guard helper
    // =========================================================================

    /**
     * @notice Revert if the record is still provisional (challenge window open).
     * @dev Call this before allowing settlement or reward disbursement.
     */
    function assertFinal(FinalizationRecord memory record) internal pure {
        if (record.isProvisional) revert ProvisionalNotFinal();
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    /// @notice Returns true iff the terminal state results in conclusive verification.
    function isConclusive(TerminalState state) internal pure returns (bool) {
        return state == TerminalState.VERIFIED_TRUE || state == TerminalState.VERIFIED_FALSE;
    }

    /// @notice Returns true iff the economic outcome is a full principal refund.
    function isFullRefund(EconomicOutcome economic) internal pure returns (bool) {
        return economic == EconomicOutcome.FULL_REFUND;
    }

    /**
     * @notice Compute confidence for a winner/total weight pair using the
     *         frozen BPS_DENOMINATOR.  Returns 0 when totalWeight is zero.
     * @param winningWeight Weight of the winning side.
     * @param totalWeight   Sum of both sides.
     * @return bps Confidence in basis points (floor division).
     */
    function computeConfidenceBps(uint256 winningWeight, uint256 totalWeight)
        internal
        pure
        returns (uint256 bps)
    {
        if (totalWeight == 0) return 0;
        return (winningWeight * BPS_DENOMINATOR) / totalWeight;
    }
}

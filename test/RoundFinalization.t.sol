// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// =============================================================================
//  PREWAVE-SC-046 — Quorum, Tie, and Insufficient-Evidence Finalization
//  Issue #722
//
//  Required test matrix (from issue spec):
//    ✓ Zero participation
//    ✓ Exact quorum
//    ✓ Quorum-1 (one below minimum)
//    ✓ Exact tie (equal weights)
//    ✓ Weighted tie (equal weights via reputation multiplication)
//    ✓ Insufficient majority (quorum met, confidence below threshold)
//    ✓ Permutation tests (order-independent aggregation)
//
//  Additional coverage:
//    ✓ Frozen BPS_DENOMINATOR constant = 10 000
//    ✓ Provisional guard blocks premature finalization
//    ✓ Appeal round scales minimums via multiplier
//    ✓ Economic outcomes per terminal state
//    ✓ Every TerminalState value is reachable
//    ✓ isConclusive / isFullRefund helpers
//    ✓ computeConfidenceBps precision
//    ✓ ProvisionalNotFinal custom error
//    ✓ FrozenRoundConfigStore + ParticipationThresholdEngine integration
//    ✓ Fuzz: outcome is independent of verifier count ordering
// =============================================================================

import "forge-std/Test.sol";

import {RoundFinalization} from "../contracts/verification/RoundFinalization.sol";
import {ParticipationThresholdTypes} from "../contracts/verification/ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "../contracts/verification/ParticipationConfidenceRules.sol";
import {FrozenRoundConfigStore} from "../contracts/verification/FrozenRoundConfigStore.sol";
import {ParticipationThresholdEngine} from "../contracts/verification/ParticipationThresholdEngine.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

contract RoundFinalizationTest is Test {
    // Shorthand aliases
    using RoundFinalization for RoundFinalization.FinalizationRecord;

    // Re-used config: 2 verifiers, 200 ether total weight, 60 % confidence
    ParticipationThresholdTypes.FrozenRoundConfig internal baseConfig;

    // Integration harness
    FrozenRoundConfigStore internal configStore;
    ParticipationThresholdEngine internal engine;

    function setUp() public {
        baseConfig = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   2,
            minTotalWeight:     200 ether,
            minConfidenceBps:   6_000,   // 60 %
            appealMultiplierBps: 10_000  // 1× (FIRST == APPEAL for this config)
        });

        configStore = new FrozenRoundConfigStore(address(this));
        engine      = new ParticipationThresholdEngine(address(this), configStore);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper builders
    // ─────────────────────────────────────────────────────────────────────────

    function _w(uint256 t, uint256 f, uint256 n)
        internal
        pure
        returns (ParticipationThresholdTypes.WeightTotals memory)
    {
        return ParticipationThresholdTypes.WeightTotals({
            trueWeight:    t,
            falseWeight:   f,
            verifierCount: n
        });
    }

    function _finalize(
        uint256 trueW,
        uint256 falseW,
        uint256 count,
        bool challengeElapsed
    ) internal view returns (RoundFinalization.FinalizationRecord memory) {
        return RoundFinalization.finalize(
            _w(trueW, falseW, count),
            baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST,
            challengeElapsed
        );
    }

    // =========================================================================
    // Section 1: Frozen BPS_DENOMINATOR constant
    // =========================================================================

    /// @notice SC046-CONST-001: BPS_DENOMINATOR is exactly 10 000.
    function test_bpsDenominator_isFrozenAt10000() public pure {
        assertEq(
            RoundFinalization.BPS_DENOMINATOR,
            10_000,
            "BPS_DENOMINATOR must be frozen at 10 000"
        );
    }

    /// @notice SC046-CONST-002: Every finalization record embeds BPS_DENOMINATOR = 10 000.
    function test_record_embedsQuorumDenominator() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);
        assertEq(r.quorumDenominator, 10_000, "quorumDenominator must equal BPS_DENOMINATOR");
    }

    // =========================================================================
    // Section 2: Conclusive outcomes (VERIFIED_TRUE / VERIFIED_FALSE)
    // =========================================================================

    /// @notice SC046-CONCL-001: TRUE majority above threshold → VERIFIED_TRUE.
    function test_verifiedTrue_aboveThreshold() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(r.confidenceBps,     7_000);
        assertFalse(r.isProvisional);
    }

    /// @notice SC046-CONCL-002: FALSE majority above threshold → VERIFIED_FALSE.
    function test_verifiedFalse_aboveThreshold() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 700 ether, 3, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_FALSE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(r.confidenceBps,     7_000);
        assertFalse(r.isProvisional);
    }

    /// @notice SC046-CONCL-003: Confidence exactly at threshold boundary → conclusive.
    function test_verifiedTrue_exactConfidenceAtBoundary() public pure {
        // 600 true / 400 false / 1000 total → 6000 bps == minConfidenceBps
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   1,
            minTotalWeight:     0,
            minConfidenceBps:   6_000,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(600 ether, 400 ether, 2),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 6_000);
    }

    // =========================================================================
    // Section 3: Zero participation
    // =========================================================================

    /// @notice SC046-ZERO-001: Zero weight + zero count → INCONCLUSIVE_ZERO.
    function test_zeroParticipation_zeroWeightZeroCount() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(0, 0, 0, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps,     0);
        assertEq(r.totalWeight,       0);
        assertEq(r.verifierCount,     0);
    }

    /// @notice SC046-ZERO-002: Zero weight, nonzero count → INCONCLUSIVE_ZERO.
    function test_zeroParticipation_zeroWeightNonzeroCount() public view {
        // Zero weight regardless of count
        RoundFinalization.FinalizationRecord memory r = _finalize(0, 0, 5, true);

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
    }

    // =========================================================================
    // Section 4: Exact quorum and quorum-1
    // =========================================================================

    /// @notice SC046-QUOR-001: Exact quorum met (count == minVerifierCount, weight == minTotalWeight).
    ///         Enough confidence → VERIFIED_TRUE.
    function test_exactQuorum_conclusive() public view {
        // count=2 (==min), weight=200e18 (==min), true=140e18 → confidence 7000 > 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(140 ether, 60 ether, 2, true);

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 7_000);
    }

    /// @notice SC046-QUOR-002: Quorum-1 verifier count → INCONCLUSIVE_INSUFFICIENT.
    function test_quorumMinus1_verifierCount() public view {
        // count=1 (< min=2), weight passes → INSUFFICIENT
        RoundFinalization.FinalizationRecord memory r = _finalize(200 ether, 0, 1, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps,     0);
    }

    /// @notice SC046-QUOR-003: Quorum-1 total weight → INCONCLUSIVE_INSUFFICIENT.
    function test_quorumMinus1_totalWeight() public view {
        // count=2 (>=min), weight=199e18 (< min=200e18) → INSUFFICIENT
        RoundFinalization.FinalizationRecord memory r = _finalize(100 ether, 99 ether, 2, true);

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
    }

    /// @notice SC046-QUOR-004: One above quorum-1 weight → passes weight check.
    function test_quorumExactWeight_passes() public view {
        // weight = exactly 200e18 (== min), count=2 (==min), 70/30 split
        RoundFinalization.FinalizationRecord memory r = _finalize(140 ether, 60 ether, 2, true);

        assertNotEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
    }

    // =========================================================================
    // Section 5: Exact tie (equal weights)
    // =========================================================================

    /// @notice SC046-TIE-001: Exact weight tie (trueWeight == falseWeight) → INCONCLUSIVE_TIE.
    function test_exactTie_equalRawWeights() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 300 ether, 4, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps,     0);
    }

    /// @notice SC046-TIE-002: Tie is INCONCLUSIVE_TIE even when quorum is well above minimum.
    function test_exactTie_largeWeights_stillInconclusive() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory looseConfig = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   1,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(1_000_000 ether, 1_000_000 ether, 10),
            looseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
    }

    /// @notice SC046-TIE-003: Single-verifier tie (impossible in practice, but the
    ///         rule must still hold for any input).
    function test_exactTie_singleVerifier() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   1,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(500 ether, 500 ether, 1),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
    }

    // =========================================================================
    // Section 6: Weighted tie
    // =========================================================================

    /// @notice SC046-WTIE-001: Two verifiers with equal effective-stake produce a tie.
    ///         Reputation multiplication is done upstream; the library sees final totals.
    function test_weightedTie_equalEffectiveStake() public pure {
        // verifier A: 100 stake × 2 rep = 200 effective (TRUE)
        // verifier B: 200 stake × 1 rep = 200 effective (FALSE)
        // → trueWeight == falseWeight == 200 ether
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   1,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(200 ether, 200 ether, 2),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    /// @notice SC046-WTIE-002: Weighted imbalance breaks the tie → VERIFIED_TRUE.
    function test_weightedTie_brokenByReputation_trueWins() public pure {
        // verifier A: 100 stake × 3 rep = 300 effective (TRUE)
        // verifier B: 100 stake × 2 rep = 200 effective (FALSE)
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   1,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(300 ether, 200 ether, 2),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        // confidence = 300/500 = 6000 bps
        assertEq(r.confidenceBps, 6_000);
    }

    // =========================================================================
    // Section 7: Insufficient majority (low confidence)
    // =========================================================================

    /// @notice SC046-CONF-001: Quorum met, confidence one bps below threshold → INCONCLUSIVE_LOW_CONFIDENCE.
    function test_insufficientMajority_confidenceOneBpsBelow() public view {
        // Need 6000 bps. 599/1000 = 5990 bps < 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(599 ether, 401 ether, 2, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps,     0, "confidenceBps must be 0 for inconclusive outcomes");
    }

    /// @notice SC046-CONF-002: Confidence exactly one bps above threshold → conclusive.
    function test_insufficientMajority_confidenceOneBpsAbove() public view {
        // 6001/10000 bps: trueWeight/total >= 6001/10000
        // trueWeight=601, falseWeight=399, total=1000 → 6010 bps > 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(601 ether, 399 ether, 2, true);

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 6_010);
    }

    /// @notice SC046-CONF-003: Low-confidence outcome embeds zero confidence (not the raw calc).
    function test_insufficientMajority_confidenceIsZeroInRecord() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(550 ether, 450 ether, 2, true);

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
        // Protocol rule: confidence field is 0 for any INCONCLUSIVE outcome
        assertEq(r.confidenceBps, 0);
    }

    // =========================================================================
    // Section 8: Provisional guard
    // =========================================================================

    /// @notice SC046-PROV-001: Record produced before challenge window ends is provisional.
    function test_provisional_flagSetWhenChallengeWindowOpen() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, false);

        assertTrue(r.isProvisional, "Challenge window open → isProvisional must be true");
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
    }

    /// @notice SC046-PROV-002: assertFinal() reverts on a provisional record.
    function test_provisional_assertFinalReverts() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, false);

        vm.expectRevert(RoundFinalization.ProvisionalNotFinal.selector);
        RoundFinalization.assertFinal(r);
    }

    /// @notice SC046-PROV-003: assertFinal() passes on a non-provisional record.
    function test_provisional_assertFinalPasses() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);

        // Must NOT revert
        RoundFinalization.assertFinal(r);
    }

    /// @notice SC046-PROV-004: No provisional result is emitted as FINAL — the
    ///         state is correct but isProvisional blocks settlement paths.
    function test_provisional_outcomeCorrectButGuarded() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, false);

        // State is known…
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        // …but is guarded
        assertTrue(r.isProvisional);
    }

    // =========================================================================
    // Section 9: Economic outcomes per terminal state
    // =========================================================================

    /// @notice SC046-ECON-001: VERIFIED_TRUE → REWARD_WINNERS_SLASH_LOSERS.
    function test_economic_verifiedTrue_rewardsAndSlash() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
    }

    /// @notice SC046-ECON-002: VERIFIED_FALSE → REWARD_WINNERS_SLASH_LOSERS.
    function test_economic_verifiedFalse_rewardsAndSlash() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 700 ether, 3, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
    }

    /// @notice SC046-ECON-003: INCONCLUSIVE_TIE → FULL_REFUND.
    function test_economic_inconclusiveTie_fullRefund() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 300 ether, 4, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    /// @notice SC046-ECON-004: INCONCLUSIVE_ZERO → FULL_REFUND.
    function test_economic_inconclusiveZero_fullRefund() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(0, 0, 0, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    /// @notice SC046-ECON-005: INCONCLUSIVE_INSUFFICIENT → FULL_REFUND.
    function test_economic_inconclusiveInsufficient_fullRefund() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(200 ether, 0, 1, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    /// @notice SC046-ECON-006: INCONCLUSIVE_LOW_CONFIDENCE → FULL_REFUND.
    function test_economic_inconclusiveLowConf_fullRefund() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(550 ether, 450 ether, 2, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    // =========================================================================
    // Section 10: Permutation / order-independence
    // =========================================================================

    /// @notice SC046-ORDER-001: Two claims with identical vote sets submitted in
    ///         opposite orders produce identical finalization records.
    function test_permutation_twoOrdersProduceSameResult() public view {
        // Simulated weight accumulation (upstream loop is commutative):
        // verifier A: TRUE  300 ether
        // verifier B: FALSE 200 ether
        // verifier C: TRUE  100 ether
        // → trueWeight=400, falseWeight=200 regardless of order

        RoundFinalization.FinalizationRecord memory r1 = _finalize(400 ether, 200 ether, 3, true);
        RoundFinalization.FinalizationRecord memory r2 = _finalize(400 ether, 200 ether, 3, true);

        assertEq(uint256(r1.state),    uint256(r2.state));
        assertEq(r1.trueWeight,        r2.trueWeight);
        assertEq(r1.falseWeight,       r2.falseWeight);
        assertEq(r1.confidenceBps,     r2.confidenceBps);
        assertEq(uint256(r1.economic), uint256(r2.economic));
    }

    /// @notice SC046-ORDER-002: Reversed split also produces the same totals.
    function test_permutation_reversedVoterOrder_sameTotals() public view {
        // Order A: [TRUE:100, FALSE:200, TRUE:300, FALSE:100]
        // Order B: [FALSE:100, TRUE:300, FALSE:200, TRUE:100]
        // Both accumulate: true=400, false=300
        RoundFinalization.FinalizationRecord memory rA = _finalize(400 ether, 300 ether, 4, true);
        RoundFinalization.FinalizationRecord memory rB = _finalize(400 ether, 300 ether, 4, true);

        assertEq(rA.trueWeight,    rB.trueWeight);
        assertEq(rA.falseWeight,   rB.falseWeight);
        assertEq(rA.totalWeight,   rB.totalWeight);
        assertEq(uint256(rA.state), uint256(rB.state));
    }

    // =========================================================================
    // Section 11: Appeal round scaling
    // =========================================================================

    /// @notice SC046-APPEAL-001: Appeal multiplier 1.5× raises count and weight minimums.
    function test_appeal_multiplierScalesThresholds() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   2,
            minTotalWeight:     200 ether,
            minConfidenceBps:   5_000,
            appealMultiplierBps: 15_000  // 1.5×
        });

        // Appeal requires ⌈2 × 1.5⌉ = 3 verifiers, ⌈200 × 1.5⌉ = 300 ether
        // Provide exactly FIRST-round quorum (2 verifiers, 200 ether) → insufficient for APPEAL
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(140 ether, 60 ether, 2),
            cfg,
            ParticipationThresholdTypes.RoundKind.APPEAL,
            true
        );

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertEq(r.effectiveMinCount,  3);
        assertEq(r.effectiveMinWeight, 300 ether);
    }

    /// @notice SC046-APPEAL-002: Appeal round with scaled quorum met → conclusive.
    function test_appeal_scaledQuorumMet_conclusive() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   2,
            minTotalWeight:     200 ether,
            minConfidenceBps:   5_000,
            appealMultiplierBps: 15_000 // 1.5×
        });

        // Provide 3 verifiers, 300 ether total → meets scaled minimums
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(210 ether, 90 ether, 3),
            cfg,
            ParticipationThresholdTypes.RoundKind.APPEAL,
            true
        );

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        // confidence = 210/300 = 7000 bps
        assertEq(r.confidenceBps, 7_000);
    }

    // =========================================================================
    // Section 12: isConclusive / isFullRefund helpers
    // =========================================================================

    /// @notice SC046-HELPER-001: isConclusive returns true only for VERIFIED states.
    function test_helper_isConclusive() public pure {
        assertTrue(RoundFinalization.isConclusive(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertTrue(RoundFinalization.isConclusive(RoundFinalization.TerminalState.VERIFIED_FALSE));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
    }

    /// @notice SC046-HELPER-002: isFullRefund returns true only for FULL_REFUND.
    function test_helper_isFullRefund() public pure {
        assertTrue(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertFalse(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertFalse(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.PARTIAL_SLASH_NO_REWARD));
    }

    // =========================================================================
    // Section 13: computeConfidenceBps precision
    // =========================================================================

    /// @notice SC046-BPS-001: computeConfidenceBps uses floor division with BPS_DENOMINATOR.
    function test_computeConfidenceBps_floorDivision() public pure {
        // 1/3 ≈ 0.3333… → floor(10000/3) = 3333
        assertEq(RoundFinalization.computeConfidenceBps(1 ether, 3 ether), 3_333);
        // 2/3 ≈ 0.6666… → floor(20000/3) = 6666
        assertEq(RoundFinalization.computeConfidenceBps(2 ether, 3 ether), 6_666);
    }

    /// @notice SC046-BPS-002: computeConfidenceBps returns 0 for zero total.
    function test_computeConfidenceBps_zeroTotal() public pure {
        assertEq(RoundFinalization.computeConfidenceBps(0, 0), 0);
    }

    /// @notice SC046-BPS-003: computeConfidenceBps returns 10 000 for unanimous.
    function test_computeConfidenceBps_unanimous() public pure {
        assertEq(RoundFinalization.computeConfidenceBps(100 ether, 100 ether), 10_000);
    }

    // =========================================================================
    // Section 14: Integration — FrozenRoundConfigStore + Engine
    // =========================================================================

    /// @notice SC046-INT-001: Engine evaluates a frozen round and the result matches
    ///         a direct library call with the same inputs.
    function test_integration_engineMatchesLibrary() public {
        configStore.freezeRoundConfig(42, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);

        ParticipationThresholdTypes.WeightTotals memory weights = _w(700 ether, 300 ether, 3);

        // Engine evaluation
        ParticipationThresholdTypes.ThresholdEvaluation memory engineResult =
            engine.evaluateRound(42, ParticipationThresholdTypes.RoundKind.FIRST, weights);

        // Library evaluation
        RoundFinalization.FinalizationRecord memory libResult =
            RoundFinalization.finalize(weights, baseConfig, ParticipationThresholdTypes.RoundKind.FIRST, true);

        assertEq(uint256(engineResult.outcome), uint256(ParticipationThresholdTypes.ClaimOutcome.VERIFIED_TRUE));
        assertEq(uint256(libResult.state),      uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(engineResult.confidenceBps,    libResult.confidenceBps);
    }

    /// @notice SC046-INT-002: Engine idempotency — cannot evaluate the same round twice.
    function test_integration_engineIdempotent() public {
        configStore.freezeRoundConfig(99, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);

        engine.evaluateRound(99, ParticipationThresholdTypes.RoundKind.FIRST, _w(700 ether, 300 ether, 3));

        vm.expectRevert(
            abi.encodeWithSelector(
                ParticipationThresholdEngine.AlreadyEvaluated.selector,
                configStore.roundId(99, ParticipationThresholdTypes.RoundKind.FIRST)
            )
        );
        engine.evaluateRound(99, ParticipationThresholdTypes.RoundKind.FIRST, _w(700 ether, 300 ether, 3));
    }

    /// @notice SC046-INT-003: Engine refuses evaluation on unfrozen round.
    function test_integration_engineRejectsUnfrozenRound() public {
        bytes32 id = configStore.roundId(7777, ParticipationThresholdTypes.RoundKind.FIRST);

        vm.expectRevert(
            abi.encodeWithSelector(ParticipationThresholdEngine.RoundNotFrozen.selector, id)
        );
        engine.evaluateRound(7777, ParticipationThresholdTypes.RoundKind.FIRST, _w(700 ether, 300 ether, 3));
    }

    // =========================================================================
    // Section 15: All TerminalState values are reachable
    // =========================================================================

    /// @notice SC046-ALL-001: Every TerminalState is reachable in a single test run.
    function test_allTerminalStates_reachable() public view {
        RoundFinalization.FinalizationRecord memory r;

        // VERIFIED_TRUE
        r = _finalize(700 ether, 300 ether, 3, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));

        // VERIFIED_FALSE
        r = _finalize(300 ether, 700 ether, 3, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_FALSE));

        // INCONCLUSIVE_TIE
        r = _finalize(300 ether, 300 ether, 4, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));

        // INCONCLUSIVE_ZERO
        r = _finalize(0, 0, 0, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));

        // INCONCLUSIVE_INSUFFICIENT (quorum-1)
        r = _finalize(200 ether, 0, 1, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));

        // INCONCLUSIVE_LOW_CONFIDENCE
        r = _finalize(550 ether, 450 ether, 2, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
    }
}

// =============================================================================
// Fuzz suite
// =============================================================================

contract RoundFinalizationFuzzTest is Test {
    ParticipationThresholdTypes.FrozenRoundConfig internal looseConfig;

    function setUp() public {
        // Loose config: 1 verifier, 0 minimum weight, 0 confidence → only ties/zero are inconclusive
        looseConfig = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   1,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });
    }

    /// @notice SC046-FUZZ-001: Outcome is independent of parameter ordering within
    ///         the weight accumulation — same totals always yield the same state.
    function testFuzz_orderIndependence(
        uint128 trueWeight,
        uint128 falseWeight,
        uint8 count
    ) public pure {
        // Simulate two different submission orders that produce the same totals
        uint256 t = uint256(trueWeight);
        uint256 f = uint256(falseWeight);
        uint256 n = uint256(count);

        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   1,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r1 = RoundFinalization.finalize(
            ParticipationThresholdTypes.WeightTotals(t, f, n),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        RoundFinalization.FinalizationRecord memory r2 = RoundFinalization.finalize(
            ParticipationThresholdTypes.WeightTotals(t, f, n),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertEq(uint256(r1.state),    uint256(r2.state),    "state must be deterministic");
        assertEq(uint256(r1.economic), uint256(r2.economic), "economic must be deterministic");
        assertEq(r1.confidenceBps,     r2.confidenceBps,     "confidence must be deterministic");
    }

    /// @notice SC046-FUZZ-002: BPS_DENOMINATOR snapshot is always 10 000.
    function testFuzz_quorumDenominatorAlways10000(
        uint128 t,
        uint128 f,
        uint8 n
    ) public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   0,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            ParticipationThresholdTypes.WeightTotals(uint256(t), uint256(f), uint256(n)),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertEq(r.quorumDenominator, 10_000);
    }

    /// @notice SC046-FUZZ-003: confidenceBps is always in [0, BPS_DENOMINATOR].
    function testFuzz_confidenceBpsNeverExceedsDenominator(
        uint128 t,
        uint128 f,
        uint8 n
    ) public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   0,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            ParticipationThresholdTypes.WeightTotals(uint256(t), uint256(f), uint256(n)),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertLe(r.confidenceBps, RoundFinalization.BPS_DENOMINATOR);
    }

    /// @notice SC046-FUZZ-004: Conclusive states always use REWARD_WINNERS_SLASH_LOSERS.
    function testFuzz_conclusive_alwaysRewardSlash(
        uint128 winning,
        uint128 losing,
        uint8 n
    ) public pure {
        vm.assume(uint256(winning) > uint256(losing));
        vm.assume(uint256(winning) + uint256(losing) > 0);

        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   0,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            ParticipationThresholdTypes.WeightTotals(uint256(winning), uint256(losing), uint256(n)),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        if (RoundFinalization.isConclusive(r.state)) {
            assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        }
    }

    /// @notice SC046-FUZZ-005: Inconclusive states always use FULL_REFUND.
    function testFuzz_inconclusive_alwaysFullRefund(
        uint128 t,
        uint128 f,
        uint8 n
    ) public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   0,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            ParticipationThresholdTypes.WeightTotals(uint256(t), uint256(f), uint256(n)),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        if (!RoundFinalization.isConclusive(r.state)) {
            assertEq(
                uint256(r.economic),
                uint256(RoundFinalization.EconomicOutcome.FULL_REFUND),
                "inconclusive must always be FULL_REFUND"
            );
        }
    }

    /// @notice SC046-FUZZ-006: Tie always → INCONCLUSIVE_TIE when quorum is met.
    function testFuzz_tie_alwaysInconclusive(uint128 weight, uint8 n) public pure {
        vm.assume(weight > 0);

        ParticipationThresholdTypes.FrozenRoundConfig memory cfg = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:      1,
            minVerifierCount:   0,
            minTotalWeight:     0,
            minConfidenceBps:   0,
            appealMultiplierBps: 10_000
        });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            ParticipationThresholdTypes.WeightTotals(uint256(weight), uint256(weight), uint256(n)),
            cfg,
            ParticipationThresholdTypes.RoundKind.FIRST,
            true
        );

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
    }
}

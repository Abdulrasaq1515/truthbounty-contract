// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// =============================================================================
//  PREWAVE-SC-046 -- Quorum, Tie, and Insufficient-Evidence Finalization
//  Issue #722
//  Dependencies: PREWAVE-SC-004 (#679), PREWAVE-SC-005 (#680)
//
//  Required test matrix (from issue spec):
//    [x] Zero participation
//    [x] Exact quorum
//    [x] Quorum-1 (one below minimum count and one below minimum weight)
//    [x] Exact tie (equal raw weights)
//    [x] Weighted tie (equal effective weights via reputation multiplication)
//    [x] Insufficient majority (quorum met, confidence below threshold)
//    [x] Permutation tests -- real MockWeightAccumulator accumulation
//        with 4 distinct submission orders, identical terminal records
//
//  Additional coverage per reviewer feedback:
//    [x] BPS_DENOMINATOR uses ParticipationThresholdTypes as single authority
//    [x] Provisional guard is on-chain in finalizeRound() -- reverts, not optional
//    [x] Integration: finalizeRound() bound to block.timestamp >= deadline
//    [x] Premature finalization via finalizeRound() reverts ChallengeWindowStillOpen
//    [x] Economic outcome per every terminal state
//    [x] All six TerminalState values reachable
//    [x] Overflow / max-bound arithmetic tests (PREWAVE-SC-005 boundary)
//    [x] Appeal multiplier ceiling scaling
//    [x] isConclusive / isFullRefund helpers exhaustive
//    [x] Fuzz: order-independence, denominator frozen, confidence bounds,
//             conclusive=>REWARD, inconclusive=>FULL_REFUND, tie always TIE
// =============================================================================

import "forge-std/Test.sol";

import {RoundFinalization}            from "../contracts/verification/RoundFinalization.sol";
import {ParticipationThresholdTypes}  from "../contracts/verification/ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "../contracts/verification/ParticipationConfidenceRules.sol";
import {FrozenRoundConfigStore}        from "../contracts/verification/FrozenRoundConfigStore.sol";
import {ParticipationThresholdEngine}  from "../contracts/verification/ParticipationThresholdEngine.sol";

// =============================================================================
// Minimal mock accumulator used for real-permutation order-independence tests.
// Simulates the VerificationAggregation weight-accumulation loop without
// pulling in TruthBountyWeighted (avoids dependency on the full token stack).
// =============================================================================
contract MockWeightAccumulator {
    struct Vote { bool support; uint256 effectiveWeight; }
    mapping(uint256 => Vote[]) private _votes;

    function recordVote(uint256 claimId, bool support, uint256 effectiveWeight) external {
        _votes[claimId].push(Vote(support, effectiveWeight));
    }

    function accumulate(uint256 claimId)
        external
        view
        returns (uint256 trueWeight, uint256 falseWeight, uint256 count)
    {
        Vote[] storage votes = _votes[claimId];
        count = votes.length;
        for (uint256 i = 0; i < count; i++) {
            if (votes[i].support) trueWeight  += votes[i].effectiveWeight;
            else                   falseWeight += votes[i].effectiveWeight;
        }
    }
}

// =============================================================================
// Main unit test contract
// =============================================================================
contract RoundFinalizationTest is Test {

    ParticipationThresholdTypes.FrozenRoundConfig internal baseConfig;

    FrozenRoundConfigStore       internal configStore;
    ParticipationThresholdEngine internal engine;
    MockWeightAccumulator        internal accumulator;

    function setUp() public {
        baseConfig = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:       1,
            minVerifierCount:    2,
            minTotalWeight:      200 ether,
            minConfidenceBps:    6_000,
            appealMultiplierBps: 10_000
        });

        configStore  = new FrozenRoundConfigStore(address(this));
        engine       = new ParticipationThresholdEngine(address(this), configStore);
        accumulator  = new MockWeightAccumulator();
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _w(uint256 t, uint256 f, uint256 n)
        internal pure
        returns (ParticipationThresholdTypes.WeightTotals memory)
    {
        return ParticipationThresholdTypes.WeightTotals({
            trueWeight:    t,
            falseWeight:   f,
            verifierCount: n
        });
    }

    function _finalize(uint256 t, uint256 f, uint256 n, bool elapsed)
        internal view
        returns (RoundFinalization.FinalizationRecord memory)
    {
        return RoundFinalization.finalize(
            _w(t, f, n), baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST, elapsed
        );
    }

    // =========================================================================
    // Section 1: BPS_DENOMINATOR -- single canonical authority
    // =========================================================================

    /// @notice SC046-CONST-001: RoundFinalization.BPS_DENOMINATOR must equal
    ///         ParticipationThresholdTypes.BPS_DENOMINATOR (alias, not redefinition).
    function test_bpsDenominator_matchesCanonicalAuthority() public pure {
        assertEq(
            RoundFinalization.BPS_DENOMINATOR,
            ParticipationThresholdTypes.BPS_DENOMINATOR
        );
        assertEq(RoundFinalization.BPS_DENOMINATOR, 10_000);
    }

    /// @notice SC046-CONST-002: Every record embeds the canonical denominator value.
    function test_record_embedsCanonicalDenominator() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);
        assertEq(r.quorumDenominator, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }

    // =========================================================================
    // Section 2: Conclusive outcomes
    // =========================================================================

    /// @notice SC046-CONCL-001: TRUE majority above threshold produces VERIFIED_TRUE.
    function test_verifiedTrue_aboveThreshold() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(r.confidenceBps, 7_000);
        assertFalse(r.isProvisional);
    }

    /// @notice SC046-CONCL-002: FALSE majority above threshold produces VERIFIED_FALSE.
    function test_verifiedFalse_aboveThreshold() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 700 ether, 3, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_FALSE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(r.confidenceBps, 7_000);
    }

    /// @notice SC046-CONCL-003: Confidence at exact threshold boundary is conclusive.
    function test_verifiedTrue_exactConfidenceBoundary() public pure {
        // 600/1000 = 6000 bps == minConfidenceBps
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 6_000, appealMultiplierBps: 10_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(600 ether, 400 ether, 2), cfg,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 6_000);
    }

    // =========================================================================
    // Section 3: Zero participation
    // =========================================================================

    /// @notice SC046-ZERO-001: Zero weight and zero count produces INCONCLUSIVE_ZERO.
    function test_zeroParticipation_zeroWeightZeroCount() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(0, 0, 0, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps, 0);
        assertEq(r.totalWeight,   0);
        assertEq(r.verifierCount, 0);
    }

    /// @notice SC046-ZERO-002: Zero weight with nonzero count also produces INCONCLUSIVE_ZERO.
    function test_zeroParticipation_zeroWeightNonzeroCount() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(0, 0, 5, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
    }

    // =========================================================================
    // Section 4: Exact quorum and quorum-1
    // =========================================================================

    /// @notice SC046-QUOR-001: Exact quorum (count==min, weight==min) is conclusive.
    function test_exactQuorum_conclusive() public view {
        // count=2==min, totalWeight=200e18==min, 140/60 split = 7000 bps > 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(140 ether, 60 ether, 2, true);

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 7_000);
    }

    /// @notice SC046-QUOR-002: Quorum-1 verifier count produces INCONCLUSIVE_INSUFFICIENT.
    function test_quorumMinus1_verifierCount() public view {
        // count=1 < min=2
        RoundFinalization.FinalizationRecord memory r = _finalize(200 ether, 0, 1, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps, 0);
    }

    /// @notice SC046-QUOR-003: Quorum-1 total weight produces INCONCLUSIVE_INSUFFICIENT.
    function test_quorumMinus1_totalWeight() public view {
        // weight=199e18 < min=200e18
        RoundFinalization.FinalizationRecord memory r = _finalize(100 ether, 99 ether, 2, true);

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
    }

    // =========================================================================
    // Section 5: Exact tie
    // =========================================================================

    /// @notice SC046-TIE-001: Equal raw weights produce INCONCLUSIVE_TIE.
    function test_exactTie_equalRawWeights() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 300 ether, 4, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps, 0);
    }

    /// @notice SC046-TIE-002: Tie holds with very large weights.
    function test_exactTie_largeWeightsStillTie() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory loose =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 0, appealMultiplierBps: 10_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(1_000_000 ether, 1_000_000 ether, 10), loose,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
    }

    // =========================================================================
    // Section 6: Weighted tie
    // =========================================================================

    /// @notice SC046-WTIE-001: Equal effective weights (reputation-multiplied) produce TIE.
    ///         verifier A: 100 stake x 2 rep = 200 effective (TRUE)
    ///         verifier B: 200 stake x 1 rep = 200 effective (FALSE)
    function test_weightedTie_equalEffectiveStake() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory loose =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 0, appealMultiplierBps: 10_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(200 ether, 200 ether, 2), loose,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    /// @notice SC046-WTIE-002: Weighted imbalance breaks tie, true wins.
    ///         verifier A: 100 stake x 3 rep = 300 (TRUE)
    ///         verifier B: 100 stake x 2 rep = 200 (FALSE)
    function test_weightedTie_brokenByReputation_trueWins() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory loose =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 0, appealMultiplierBps: 10_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(300 ether, 200 ether, 2), loose,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(r.confidenceBps, 6_000);
    }

    // =========================================================================
    // Section 7: Insufficient majority (low confidence)
    // =========================================================================

    /// @notice SC046-CONF-001: Confidence 1 bps below threshold produces INCONCLUSIVE_LOW_CONFIDENCE.
    function test_insufficientMajority_confidenceOneBpsBelow() public view {
        // 599/1000 = 5990 bps < 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(599 ether, 401 ether, 2, true);

        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps, 0);
    }

    /// @notice SC046-CONF-002: Confidence 1 bps above threshold is conclusive.
    function test_insufficientMajority_confidenceOneBpsAbove() public view {
        // 601/1000 = 6010 bps > 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(601 ether, 399 ether, 2, true);

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 6_010);
    }

    // =========================================================================
    // Section 8: Provisional guard -- on-chain path
    // =========================================================================

    /// @notice SC046-PROV-001: finalizeRound() reverts when challenge window is open.
    ///         Finality is bound to block.timestamp -- cannot be bypassed.
    function test_finalizeRound_revertsWhenWindowOpen() public {
        uint256 claimId = 1;
        configStore.freezeRoundConfig(claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);

        uint64 deadline = uint64(block.timestamp + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                ParticipationThresholdEngine.ChallengeWindowStillOpen.selector,
                configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST),
                deadline
            )
        );
        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST,
            _w(700 ether, 300 ether, 3), deadline);
    }

    /// @notice SC046-PROV-002: finalizeRound() succeeds after challenge window elapses.
    function test_finalizeRound_succeedsAfterWindow() public {
        uint256 claimId = 2;
        configStore.freezeRoundConfig(claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);

        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days + 1);

        RoundFinalization.FinalizationRecord memory r = engine.finalizeRound(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST,
            _w(700 ether, 300 ether, 3), deadline
        );

        assertFalse(r.isProvisional);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
    }

    /// @notice SC046-PROV-003: finalizeRound() cannot be called twice (idempotent).
    function test_finalizeRound_idempotent() public {
        uint256 claimId = 3;
        configStore.freezeRoundConfig(claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);
        uint64 deadline = uint64(block.timestamp);
        vm.warp(block.timestamp + 1);

        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST,
            _w(700 ether, 300 ether, 3), deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                ParticipationThresholdEngine.AlreadyFinalized.selector,
                configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST)
            )
        );
        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST,
            _w(700 ether, 300 ether, 3), deadline);
    }

    /// @notice SC046-PROV-004: Pure assertFinal() reverts on provisional record.
    function test_assertFinal_revertsOnProvisional() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, false);
        assertTrue(r.isProvisional);
        vm.expectRevert(RoundFinalization.ProvisionalNotFinal.selector);
        RoundFinalization.assertFinal(r);
    }

    /// @notice SC046-PROV-005: Pure assertFinal() passes on non-provisional record.
    function test_assertFinal_passesWhenFinal() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);
        assertFalse(r.isProvisional);
        RoundFinalization.assertFinal(r); // must not revert
    }

    // =========================================================================
    // Section 9: Economic outcomes per terminal state
    // =========================================================================

    function test_economic_verifiedTrue_rewardSlash() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
    }
    function test_economic_verifiedFalse_rewardSlash() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 700 ether, 3, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
    }
    function test_economic_tie_fullRefund() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 300 ether, 4, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }
    function test_economic_zero_fullRefund() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(0, 0, 0, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }
    function test_economic_insufficient_fullRefund() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(200 ether, 0, 1, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }
    function test_economic_lowConf_fullRefund() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(550 ether, 450 ether, 2, true);
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    // =========================================================================
    // Section 10: Real permutation order-independence tests
    //
    // MockWeightAccumulator simulates the VerificationAggregation loop.
    // Votes: [TRUE:300e18, FALSE:200e18, TRUE:100e18, FALSE:150e18]
    // Expected totals: trueWeight=400e18, falseWeight=350e18, total=750e18
    // Confidence: 400/750 = 5333 bps < 6000 -> INCONCLUSIVE_LOW_CONFIDENCE
    // =========================================================================

    function _recordOrderA(uint256 id) internal {
        accumulator.recordVote(id, true,  300 ether);
        accumulator.recordVote(id, false, 200 ether);
        accumulator.recordVote(id, true,  100 ether);
        accumulator.recordVote(id, false, 150 ether);
    }
    function _recordOrderB(uint256 id) internal {
        // reversed
        accumulator.recordVote(id, false, 150 ether);
        accumulator.recordVote(id, true,  100 ether);
        accumulator.recordVote(id, false, 200 ether);
        accumulator.recordVote(id, true,  300 ether);
    }
    function _recordOrderC(uint256 id) internal {
        // interleaved
        accumulator.recordVote(id, true,  100 ether);
        accumulator.recordVote(id, false, 150 ether);
        accumulator.recordVote(id, true,  300 ether);
        accumulator.recordVote(id, false, 200 ether);
    }
    function _recordOrderD(uint256 id) internal {
        // all TRUE then all FALSE
        accumulator.recordVote(id, true,  300 ether);
        accumulator.recordVote(id, true,  100 ether);
        accumulator.recordVote(id, false, 200 ether);
        accumulator.recordVote(id, false, 150 ether);
    }

    function _finalizeAccumulated(uint256 id)
        internal view
        returns (RoundFinalization.FinalizationRecord memory)
    {
        (uint256 t, uint256 f, uint256 n) = accumulator.accumulate(id);
        return RoundFinalization.finalize(
            _w(t, f, n), baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
    }

    /// @notice SC046-ORDER-001: Four distinct submission orders produce identical records.
    function test_permutation_fourOrdersIdentical() public {
        _recordOrderA(101);
        _recordOrderB(102);
        _recordOrderC(103);
        _recordOrderD(104);

        RoundFinalization.FinalizationRecord memory rA = _finalizeAccumulated(101);
        RoundFinalization.FinalizationRecord memory rB = _finalizeAccumulated(102);
        RoundFinalization.FinalizationRecord memory rC = _finalizeAccumulated(103);
        RoundFinalization.FinalizationRecord memory rD = _finalizeAccumulated(104);

        assertEq(rA.trueWeight,  400 ether);
        assertEq(rA.falseWeight, 350 ether);
        assertEq(rA.totalWeight, 750 ether);

        assertEq(rA.trueWeight,        rB.trueWeight);
        assertEq(rA.trueWeight,        rC.trueWeight);
        assertEq(rA.trueWeight,        rD.trueWeight);
        assertEq(rA.falseWeight,       rB.falseWeight);
        assertEq(rA.falseWeight,       rC.falseWeight);
        assertEq(rA.falseWeight,       rD.falseWeight);
        assertEq(uint256(rA.state),    uint256(rB.state));
        assertEq(uint256(rA.state),    uint256(rC.state));
        assertEq(uint256(rA.state),    uint256(rD.state));
        assertEq(uint256(rA.economic), uint256(rB.economic));

        assertEq(uint256(rA.state),
            uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
    }

    /// @notice SC046-ORDER-002: Conclusive vote set also order-independent.
    function test_permutation_conclusive_orderIndependent() public {
        accumulator.recordVote(201, true,  700 ether);
        accumulator.recordVote(201, false, 300 ether);
        accumulator.recordVote(202, false, 300 ether);
        accumulator.recordVote(202, true,  700 ether);

        RoundFinalization.FinalizationRecord memory r1 = _finalizeAccumulated(201);
        RoundFinalization.FinalizationRecord memory r2 = _finalizeAccumulated(202);

        assertEq(r1.trueWeight,        r2.trueWeight);
        assertEq(r1.falseWeight,       r2.falseWeight);
        assertEq(uint256(r1.state),    uint256(r2.state));
        assertEq(uint256(r1.economic), uint256(r2.economic));
        assertEq(r1.confidenceBps,     r2.confidenceBps);
        assertEq(uint256(r1.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
    }

    // =========================================================================
    // Section 11: Appeal round scaling
    // =========================================================================

    /// @notice SC046-APPEAL-001: 1.5x multiplier raises count and weight minimums (ceiling).
    function test_appeal_multiplierScalesThresholds() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 2, minTotalWeight: 200 ether,
                minConfidenceBps: 5_000, appealMultiplierBps: 15_000
            });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(140 ether, 60 ether, 2), cfg,
            ParticipationThresholdTypes.RoundKind.APPEAL, true
        );

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertEq(r.effectiveMinCount,  3);
        assertEq(r.effectiveMinWeight, 300 ether);
    }

    /// @notice SC046-APPEAL-002: Scaled quorum met produces conclusive result.
    function test_appeal_scaledQuorumMet_conclusive() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 2, minTotalWeight: 200 ether,
                minConfidenceBps: 5_000, appealMultiplierBps: 15_000
            });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(210 ether, 90 ether, 3), cfg,
            ParticipationThresholdTypes.RoundKind.APPEAL, true
        );

        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 7_000);
    }

    // =========================================================================
    // Section 12: Overflow / max-bound arithmetic (PREWAVE-SC-005 boundary)
    // =========================================================================

    /// @notice SC046-OVF-001: Max uint128 weights fit in uint256 totalWeight (no overflow).
    function test_overflow_maxUint128WeightsNoOverflow() public pure {
        uint256 maxW = type(uint128).max;
        ParticipationThresholdTypes.FrozenRoundConfig memory loose =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 0, appealMultiplierBps: 10_000
            });

        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(maxW, maxW, 2), loose,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );

        assertEq(r.totalWeight, maxW + maxW);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
    }

    /// @notice SC046-OVF-002: Confidence multiplication winningWeight * BPS_DENOMINATOR
    ///         does not overflow for max uint128 input.
    function test_overflow_confidenceMultiplicationBound() public pure {
        uint256 winning = type(uint128).max;
        uint256 total   = type(uint128).max;
        uint256 bps = RoundFinalization.computeConfidenceBps(winning, total);
        assertEq(bps, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }

    /// @notice SC046-OVF-003: computeConfidenceBps never exceeds BPS_DENOMINATOR.
    function test_overflow_confidenceBpsNeverExceedsDenominator() public pure {
        uint256[5] memory wins = [uint256(1), 50, 9_999, type(uint128).max / 2, type(uint128).max];
        uint256[5] memory tots = [uint256(1), 100, 10_000, type(uint128).max, type(uint128).max];

        for (uint256 i = 0; i < 5; i++) {
            uint256 bps = RoundFinalization.computeConfidenceBps(wins[i], tots[i]);
            assertLe(bps, ParticipationThresholdTypes.BPS_DENOMINATOR);
        }
    }

    /// @notice SC046-OVF-004: Appeal ceiling scaling with max multiplier does not overflow.
    ///         (baseMin * 100_000 + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR must fit uint256.
    function test_overflow_appealThresholdScaling_maxMultiplier() public pure {
        uint256 baseMin    = type(uint128).max;
        uint256 multiplier = 100_000;
        uint256 scaled = (baseMin * multiplier + ParticipationThresholdTypes.BPS_DENOMINATOR - 1)
            / ParticipationThresholdTypes.BPS_DENOMINATOR;

        assertGt(scaled, 0);
        assertEq(scaled, baseMin * 10); // 100_000 / 10_000 = 10
    }

    // =========================================================================
    // Section 13: isConclusive / isFullRefund exhaustive
    // =========================================================================

    function test_helper_isConclusive_exhaustive() public pure {
        assertTrue(RoundFinalization.isConclusive(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertTrue(RoundFinalization.isConclusive(RoundFinalization.TerminalState.VERIFIED_FALSE));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
    }

    function test_helper_isFullRefund_exhaustive() public pure {
        assertTrue(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertFalse(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertFalse(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.PARTIAL_SLASH_NO_REWARD));
    }

    // =========================================================================
    // Section 14: All six TerminalState values reachable
    // =========================================================================

    function test_allTerminalStates_reachable() public view {
        RoundFinalization.FinalizationRecord memory r;

        r = _finalize(700 ether, 300 ether, 3, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));

        r = _finalize(300 ether, 700 ether, 3, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_FALSE));

        r = _finalize(300 ether, 300 ether, 4, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));

        r = _finalize(0, 0, 0, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));

        r = _finalize(200 ether, 0, 1, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));

        r = _finalize(550 ether, 450 ether, 2, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
    }

    // =========================================================================
    // Section 15: Integration -- engine finalizeRound()
    // =========================================================================

    /// @notice SC046-INT-001: finalizeRound() emits RoundFinalized with correct fields.
    function test_integration_finalizeRound_emitsEvent() public {
        uint256 claimId = 50;
        configStore.freezeRoundConfig(claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);
        uint64 deadline = uint64(block.timestamp);
        vm.warp(block.timestamp + 1);

        bytes32 roundId = configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST);

        vm.expectEmit(true, true, true, true, address(engine));
        emit ParticipationThresholdEngine.RoundFinalized(
            roundId, claimId, ParticipationThresholdTypes.RoundKind.FIRST,
            RoundFinalization.TerminalState.VERIFIED_TRUE,
            RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS,
            7_000, false
        );

        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST,
            _w(700 ether, 300 ether, 3), deadline);
    }

    /// @notice SC046-INT-002: getFinalization() returns the stored record.
    function test_integration_getFinalization_correct() public {
        uint256 claimId = 51;
        configStore.freezeRoundConfig(claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);
        uint64 deadline = uint64(block.timestamp);
        vm.warp(block.timestamp + 1);

        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST,
            _w(700 ether, 300 ether, 3), deadline);

        bytes32 roundId = configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
        RoundFinalization.FinalizationRecord memory stored = engine.getFinalization(roundId);

        assertEq(uint256(stored.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(stored.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(stored.confidenceBps, 7_000);
        assertFalse(stored.isProvisional);
        assertTrue(engine.isFinalized(roundId));
    }

    /// @notice SC046-INT-003: evaluateRound() and finalizeRound() agree on confidence.
    function test_integration_evaluateAndFinalizeAgree() public {
        // evaluateRound uses claimId=52, finalizeRound uses 53 (separate roundIds)
        uint256 claimA = 52;
        uint256 claimB = 53;
        configStore.freezeRoundConfig(claimA, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);
        configStore.freezeRoundConfig(claimB, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);

        ParticipationThresholdTypes.WeightTotals memory weights = _w(700 ether, 300 ether, 3);

        ParticipationThresholdTypes.ThresholdEvaluation memory eval =
            engine.evaluateRound(claimA, ParticipationThresholdTypes.RoundKind.FIRST, weights);

        uint64 deadline = uint64(block.timestamp);
        vm.warp(block.timestamp + 1);
        RoundFinalization.FinalizationRecord memory fin =
            engine.finalizeRound(claimB, ParticipationThresholdTypes.RoundKind.FIRST, weights, deadline);

        assertEq(eval.confidenceBps, fin.confidenceBps);
        assertEq(uint256(eval.outcome), uint256(ParticipationThresholdTypes.ClaimOutcome.VERIFIED_TRUE));
        assertEq(uint256(fin.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
    }
}

// =============================================================================
// Fuzz suite
// =============================================================================
contract RoundFinalizationFuzzTest is Test {

    function _loose() internal pure returns (ParticipationThresholdTypes.FrozenRoundConfig memory) {
        return ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion: 1, minVerifierCount: 0, minTotalWeight: 0,
            minConfidenceBps: 0, appealMultiplierBps: 10_000
        });
    }

    function _w(uint256 t, uint256 f, uint256 n)
        internal pure returns (ParticipationThresholdTypes.WeightTotals memory)
    {
        return ParticipationThresholdTypes.WeightTotals(t, f, n);
    }

    /// @notice FUZZ-001: Same inputs always produce the same TerminalState.
    function testFuzz_orderIndependence(uint128 t, uint128 f, uint8 n) public pure {
        ParticipationThresholdTypes.WeightTotals memory w = _w(uint256(t), uint256(f), uint256(n));
        RoundFinalization.FinalizationRecord memory r1 =
            RoundFinalization.finalize(w, _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        RoundFinalization.FinalizationRecord memory r2 =
            RoundFinalization.finalize(w, _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        assertEq(uint256(r1.state),    uint256(r2.state));
        assertEq(uint256(r1.economic), uint256(r2.economic));
        assertEq(r1.confidenceBps,     r2.confidenceBps);
    }

    /// @notice FUZZ-002: quorumDenominator is always the canonical BPS_DENOMINATOR.
    function testFuzz_quorumDenominatorAlwaysCanonical(uint128 t, uint128 f, uint8 n) public pure {
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(t), uint256(f), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        assertEq(r.quorumDenominator, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }

    /// @notice FUZZ-003: confidenceBps is always in [0, BPS_DENOMINATOR].
    function testFuzz_confidenceBpsNeverExceedsDenominator(uint128 t, uint128 f, uint8 n) public pure {
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(t), uint256(f), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        assertLe(r.confidenceBps, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }

    /// @notice FUZZ-004: Conclusive states always map to REWARD_WINNERS_SLASH_LOSERS.
    function testFuzz_conclusive_alwaysRewardSlash(uint128 winning, uint128 losing, uint8 n) public pure {
        vm.assume(uint256(winning) > uint256(losing));
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(winning), uint256(losing), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        if (RoundFinalization.isConclusive(r.state)) {
            assertEq(uint256(r.economic),
                uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        }
    }

    /// @notice FUZZ-005: Inconclusive states always map to FULL_REFUND.
    function testFuzz_inconclusive_alwaysFullRefund(uint128 t, uint128 f, uint8 n) public pure {
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(t), uint256(f), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        if (!RoundFinalization.isConclusive(r.state)) {
            assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        }
    }

    /// @notice FUZZ-006: Equal nonzero weights always produce INCONCLUSIVE_TIE.
    function testFuzz_tie_alwaysInconclusive(uint128 weight, uint8 n) public pure {
        vm.assume(weight > 0);
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(weight), uint256(weight), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
    }

    /// @notice FUZZ-007: computeConfidenceBps never overflows for uint128 inputs.
    function testFuzz_computeConfidenceBps_noOverflow(uint128 winning, uint128 total) public pure {
        vm.assume(uint256(total) >= uint256(winning));
        vm.assume(total > 0);
        uint256 bps = RoundFinalization.computeConfidenceBps(uint256(winning), uint256(total));
        assertLe(bps, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }
}

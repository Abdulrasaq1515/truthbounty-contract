// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ParticipationThresholdTypes} from "./ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "./ParticipationConfidenceRules.sol";
import {FrozenRoundConfigStore} from "./FrozenRoundConfigStore.sol";
import {RoundFinalization} from "./RoundFinalization.sol";

/**
 * @title ParticipationThresholdEngine
 * @notice V2-SC-014 engine applying frozen round thresholds to aggregated weights.
 *
 * @dev Extended by PREWAVE-SC-046 (#722) to expose finalizeRound() -- the
 *      authoritative on-chain path that binds finality to block.timestamp
 *      rather than a caller-supplied boolean. finalize() in RoundFinalization
 *      is a pure helper for off-chain preview; this function is the canonical
 *      machine-readable consumer handoff required by #722.
 */
contract ParticipationThresholdEngine is AccessControl {
    bytes32 public constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");

    FrozenRoundConfigStore public immutable configStore;

    mapping(bytes32 => ParticipationThresholdTypes.ThresholdEvaluation) private _evaluations;
    mapping(bytes32 => bool) private _evaluated;

    // PREWAVE-SC-046: store finalization records keyed by roundId
    mapping(bytes32 => RoundFinalization.FinalizationRecord) private _finalizations;
    mapping(bytes32 => bool) private _finalized;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ThresholdEvaluated(
        bytes32 indexed roundId,
        uint256 indexed claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        ParticipationThresholdTypes.ClaimOutcome outcome,
        ParticipationThresholdTypes.InconclusiveReason reason,
        uint256 confidenceBps
    );

    /// @notice Canonical machine-readable event required by PREWAVE-SC-046.
    /// @dev Settlement and reward modules must consume this event as the
    ///      authoritative finalization signal. isProvisional is always false
    ///      here because finalizeRound() enforces the challenge window.
    event RoundFinalized(
        bytes32 indexed roundId,
        uint256 indexed claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        RoundFinalization.TerminalState terminalState,
        RoundFinalization.EconomicOutcome economicOutcome,
        uint256 confidenceBps,
        bool isProvisional
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AlreadyEvaluated(bytes32 roundId);
    error RoundNotFrozen(bytes32 roundId);
    error AlreadyFinalized(bytes32 roundId);

    /// @notice Reverts when block.timestamp < challengeDeadline on the
    ///         authoritative finalizeRound() path. Premature finalization
    ///         is impossible -- not merely caller-disciplined.
    error ChallengeWindowStillOpen(bytes32 roundId, uint64 challengeDeadline);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address admin, FrozenRoundConfigStore store) {
        configStore = store;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EVALUATOR_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Existing evaluation path (unchanged -- preserves SC-014 consumers)
    // -------------------------------------------------------------------------

    function evaluateRound(
        uint256 claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        ParticipationThresholdTypes.WeightTotals calldata weights
    ) external onlyRole(EVALUATOR_ROLE) returns (ParticipationThresholdTypes.ThresholdEvaluation memory evaluation) {
        bytes32 id = configStore.roundId(claimId, roundKind);
        if (!configStore.isRoundFrozen(id)) revert RoundNotFrozen(id);
        if (_evaluated[id]) revert AlreadyEvaluated(id);

        ParticipationThresholdTypes.FrozenRoundConfig memory config = configStore.getFrozenConfig(id);
        evaluation = ParticipationConfidenceRules.evaluate(weights, config, roundKind);

        _evaluations[id] = evaluation;
        _evaluated[id] = true;

        emit ThresholdEvaluated(id, claimId, roundKind, evaluation.outcome, evaluation.reason, evaluation.confidenceBps);
    }

    // -------------------------------------------------------------------------
    // PREWAVE-SC-046: authoritative finalization path
    // -------------------------------------------------------------------------

    /**
     * @notice Produce and store the canonical FinalizationRecord for a round.
     *
     * @dev This is the authoritative on-chain path required by PREWAVE-SC-046.
     *      Finality is bound to block.timestamp >= challengeDeadline. The
     *      caller supplies challengeDeadline (frozen at round open); this
     *      contract verifies it against block.timestamp and reverts with
     *      ChallengeWindowStillOpen if the window has not elapsed.
     *      Premature finalization is impossible, not merely discouraged.
     *
     *      The resulting RoundFinalized event is the canonical machine-readable
     *      consumer handoff for settlement and reward modules.
     *
     * @param claimId           The claim being finalized.
     * @param roundKind         FIRST or APPEAL.
     * @param weights           Aggregated weight totals from the aggregator.
     * @param challengeDeadline Unix timestamp after which the challenge window
     *                          is elapsed. Frozen at round open.
     */
    function finalizeRound(
        uint256 claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        ParticipationThresholdTypes.WeightTotals calldata weights,
        uint64 challengeDeadline
    ) external onlyRole(EVALUATOR_ROLE) returns (RoundFinalization.FinalizationRecord memory record) {
        bytes32 id = configStore.roundId(claimId, roundKind);
        if (!configStore.isRoundFrozen(id)) revert RoundNotFrozen(id);
        if (_finalized[id]) revert AlreadyFinalized(id);

        // Bind finality to block.timestamp -- caller cannot override
        if (block.timestamp < uint256(challengeDeadline)) {
            revert ChallengeWindowStillOpen(id, challengeDeadline);
        }

        ParticipationThresholdTypes.FrozenRoundConfig memory config = configStore.getFrozenConfig(id);

        // challengeWindowElapsed = true because we verified above
        record = RoundFinalization.finalize(weights, config, roundKind, true);

        _finalizations[id] = record;
        _finalized[id] = true;

        emit RoundFinalized(
            id,
            claimId,
            roundKind,
            record.state,
            record.economic,
            record.confidenceBps,
            record.isProvisional
        );
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function previewEvaluation(
        ParticipationThresholdTypes.WeightTotals calldata weights,
        ParticipationThresholdTypes.FrozenRoundConfig calldata config,
        ParticipationThresholdTypes.RoundKind roundKind
    ) external pure returns (ParticipationThresholdTypes.ThresholdEvaluation memory) {
        return ParticipationConfidenceRules.evaluate(weights, config, roundKind);
    }

    function getEvaluation(bytes32 roundId)
        external
        view
        returns (ParticipationThresholdTypes.ThresholdEvaluation memory)
    {
        return _evaluations[roundId];
    }

    function isEvaluated(bytes32 roundId) external view returns (bool) {
        return _evaluated[roundId];
    }

    /// @notice Return the stored FinalizationRecord for a round.
    function getFinalization(bytes32 roundId)
        external
        view
        returns (RoundFinalization.FinalizationRecord memory)
    {
        return _finalizations[roundId];
    }

    /// @notice Whether finalizeRound() has been called for a round.
    function isFinalized(bytes32 roundId) external view returns (bool) {
        return _finalized[roundId];
    }
}

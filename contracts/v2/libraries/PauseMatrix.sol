// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PauseMatrix
/// @notice Versioned, explicit pause matrix for the canonical TruthBounty V2 modules (V2-SC-162).
/// @dev Every external state-mutating operation on a canonical V2 module is classified exactly once:
///
///      | Class             | Meaning                                                               | Gate                              |
///      |-------------------|-----------------------------------------------------------------------|-----------------------------------|
///      | `RISK_INCREASING` | Creates new exposure or mutates a not-yet-final outcome (claims,      | Fail closed on every listed scope |
///      |                   | staking, verification, evidence, disputes, settlement, governance).   |                                   |
///      | `NEUTRAL`         | Authority wiring or module-local toggles that neither create exposure | Never scope-gated                 |
///      |                   | nor move value.                                                       |                                   |
///      | `RISK_REDUCING`   | Permissionless exits of value that is already final and owned by the  | Never scope-gated; value exits    |
///      |                   | caller, or protective actions (pausing, nonce cancellation).          | freeze only at protocol SHUTDOWN  |
///
///      Read paths are never gated.
///
///      A gate named `SCOPE_*` fails closed while `IEmergencyControls.paused(scope)` is true, when the
///      pause authority cannot be classified, or when it returns malformed data. The pseudo-gate
///      `EXIT_SHUTDOWN_ONLY` marks a value exit that stays live under every operation-scoped pause and
///      under protocol levels HIGH_RISK / FINANCIAL, and freezes only on an affirmative, healthy
///      `EmergencyController` SHUTDOWN reading (`pull_settled_claim` denied, V2-SC-117). It fails open
///      so that exit liveness never depends on pause-authority or registry health.
///
///      This library is the Solidity mirror of `config/pause-matrix.json`. `scripts/check-pause-matrix.mjs`
///      fails CI if the two disagree, if a module source adds, removes, or re-gates an operation without
///      updating both, or if the version constants differ. Any classification change MUST bump
///      `PAUSE_MATRIX_VERSION` and append a new `history` entry to the JSON matrix.
///
///      Signatures are *source-level* signatures: parameter types exactly as declared in the module
///      source with data locations removed (e.g. `IV2Types.LockCategory`, not `uint8`). They identify
///      operations for review and tests; they are not ABI selectors.
library PauseMatrix {
    /// @notice Version of the pause matrix enforced by this build.
    uint16 internal constant PAUSE_MATRIX_VERSION = 1;

    /// @notice Registry key under which registry-resolved modules find their pause authority.
    /// @dev Byte-identical to `ModuleRegistryLib.MODULE_EMERGENCY_CONTROLS`.
    bytes32 internal constant MODULE_EMERGENCY_CONTROLS = keccak256("EMERGENCY_CONTROLS");

    // ─── Operation scopes (byte-identical to EmergencyControls scope constants) ─────────────

    /// @notice New claim creation and registration.
    bytes32 internal constant SCOPE_CLAIMS = keccak256("CLAIMS");
    /// @notice Evidence submission and adjudication.
    bytes32 internal constant SCOPE_EVIDENCE = keccak256("EVIDENCE");
    /// @notice Verifier staking, deposits, and new locks.
    bytes32 internal constant SCOPE_STAKING = keccak256("STAKING");
    /// @notice Verification attestations and aggregation of verification results.
    bytes32 internal constant SCOPE_VERIFICATION = keccak256("VERIFICATION");
    /// @notice Settlement, slashing, lock release, reward finalization, and pull-credit issuance.
    bytes32 internal constant SCOPE_SETTLEMENT = keccak256("SETTLEMENT");
    /// @notice Treasury movements.
    bytes32 internal constant SCOPE_TREASURY = keccak256("TREASURY");
    /// @notice Dispute initiation and resolution.
    bytes32 internal constant SCOPE_DISPUTES = keccak256("DISPUTES");
    /// @notice Module-level governance parameter and authority mutations (V2-SC-162).
    bytes32 internal constant SCOPE_GOVERNANCE = keccak256("GOVERNANCE");

    // ─── Pseudo-gates used by the mirror ────────────────────────────────────────────────────

    /// @notice Marks a value exit that freezes only at protocol SHUTDOWN.
    bytes32 internal constant EXIT_SHUTDOWN_ONLY = keccak256("EXIT_SHUTDOWN_ONLY");
    /// @notice Placeholder for an unused gate slot.
    bytes32 internal constant NO_GATE = bytes32(0);

    /// @notice Risk classification of an external operation.
    enum RiskClass {
        NEUTRAL,
        RISK_INCREASING,
        RISK_REDUCING
    }

    /// @notice The (module, signature) pair is not part of the matrix.
    error UnclassifiedOperation(string moduleName, string signature);

    /// @notice Returns the classification and gates of a canonical V2 operation.
    /// @dev Reverts with `UnclassifiedOperation` for anything not in the matrix, so tests that walk
    ///      the matrix fail loudly when an operation is missing. `gateB` is `NO_GATE` for single-gate
    ///      operations; the gate set of an operation is `{gateA, gateB} \ {NO_GATE}`.
    /// @param moduleName Contract name of the module (e.g. "StakeVault").
    /// @param signature Source-level signature (e.g. "withdraw(address,uint256)").
    /// @return risk Risk class.
    /// @return gateA First gate (`SCOPE_*`, `EXIT_SHUTDOWN_ONLY`, or `NO_GATE`).
    /// @return gateB Second gate (`SCOPE_*` or `NO_GATE`).
    function classify(string memory moduleName, string memory signature)
        internal
        pure
        returns (RiskClass risk, bytes32 gateA, bytes32 gateB)
    {
        bytes32 k = _key(moduleName, signature);

        // ─── StakeVault ───────────────────────────────────────────────────────────────────
        if (k == _key("StakeVault", "depositStake(uint256,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_STAKING, NO_GATE);
        if (k == _key("StakeVault", "deposit(address,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_STAKING, NO_GATE);
        if (k == _key("StakeVault", "lock(address,address,uint256,uint256,IV2Types.LockCategory,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_STAKING, NO_GATE);
        if (k == _key("StakeVault", "releaseStake(uint256,address,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "slashStake(uint256,address,uint256,bytes32)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "unlock(address,address,uint256,uint256,IV2Types.LockCategory,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "allocateLocked(address,address,uint256,uint256,IV2Types.LockCategory,uint256,bytes32)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "settleConclusive(address,address,uint256,uint256,uint256,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "refundInconclusive(address,address,uint256,uint256,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "carryForwardAppeal(address,address,uint256,uint256,uint256,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "rolloverRound(address,address,uint256,uint256,uint256,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "finalUnlock(address,address,uint256,uint256,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("StakeVault", "setMinStakeAmount(uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_GOVERNANCE, NO_GATE);
        if (k == _key("StakeVault", "setSupportedAsset(address,bool)")) return (RiskClass.RISK_INCREASING, SCOPE_GOVERNANCE, NO_GATE);
        if (k == _key("StakeVault", "setLockMutator(address,bool)")) return (RiskClass.RISK_INCREASING, SCOPE_GOVERNANCE, NO_GATE);
        if (k == _key("StakeVault", "withdraw(address,uint256)")) return (RiskClass.RISK_REDUCING, EXIT_SHUTDOWN_ONLY, NO_GATE);

        // ─── Claims ───────────────────────────────────────────────────────────────────────
        if (k == _key("Claims", "createClaim(bytes32,uint256,bytes)")) return (RiskClass.RISK_INCREASING, SCOPE_CLAIMS, NO_GATE);
        if (k == _key("Claims", "finalizeClaim(uint256,IV2Types.ClaimStatus)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("Claims", "setAntiGriefParams(uint256,uint256,uint256,uint64,uint256,address)")) return (RiskClass.RISK_INCREASING, SCOPE_GOVERNANCE, NO_GATE);
        if (k == _key("Claims", "cancelClaim(uint256)")) return (RiskClass.RISK_REDUCING, EXIT_SHUTDOWN_ONLY, SCOPE_SETTLEMENT);
        if (k == _key("Claims", "setPauseAuthority(address)")) return (RiskClass.NEUTRAL, NO_GATE, NO_GATE);

        // ─── EvidenceRegistry ─────────────────────────────────────────────────────────────
        if (k == _key("EvidenceRegistry", "submitEvidence(uint256,bytes32,bytes)")) return (RiskClass.RISK_INCREASING, SCOPE_EVIDENCE, NO_GATE);
        if (k == _key("EvidenceRegistry", "commitEvidence(uint256,bytes32,bytes32,uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_EVIDENCE, NO_GATE);
        if (k == _key("EvidenceRegistry", "setEvidenceStatus(uint256,IV2Types.EvidenceStatus)")) return (RiskClass.RISK_INCREASING, SCOPE_EVIDENCE, NO_GATE);
        if (k == _key("EvidenceRegistry", "pause()")) return (RiskClass.RISK_REDUCING, NO_GATE, NO_GATE);
        if (k == _key("EvidenceRegistry", "unpause()")) return (RiskClass.NEUTRAL, NO_GATE, NO_GATE);
        if (k == _key("EvidenceRegistry", "setPauseAuthority(address)")) return (RiskClass.NEUTRAL, NO_GATE, NO_GATE);

        // ─── FinalRewardAllocator ─────────────────────────────────────────────────────────
        if (k == _key("FinalRewardAllocator", "fund(address,uint256,bytes32)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("FinalRewardAllocator", "finalizeRewards(bytes32,address,FinalOutcome,Allocation[])")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("FinalRewardAllocator", "claim(address,uint256)")) return (RiskClass.RISK_REDUCING, EXIT_SHUTDOWN_ONLY, NO_GATE);

        // ─── Aggregation ──────────────────────────────────────────────────────────────────
        if (k == _key("Aggregation", "finalizeAggregation(uint256)")) return (RiskClass.RISK_INCREASING, SCOPE_VERIFICATION, SCOPE_SETTLEMENT);

        // ─── PullSettlementLedger ─────────────────────────────────────────────────────────
        if (k == _key("PullSettlementLedger", "credit(address,uint256,bytes32)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("PullSettlementLedger", "creditBatch(address[],uint256[],bytes32)")) return (RiskClass.RISK_INCREASING, SCOPE_SETTLEMENT, NO_GATE);
        if (k == _key("PullSettlementLedger", "withdraw(uint256)")) return (RiskClass.RISK_REDUCING, EXIT_SHUTDOWN_ONLY, NO_GATE);
        if (k == _key("PullSettlementLedger", "withdrawFromRef(bytes32,uint256)")) return (RiskClass.RISK_REDUCING, EXIT_SHUTDOWN_ONLY, NO_GATE);
        if (k == _key("PullSettlementLedger", "setPauseAuthority(address)")) return (RiskClass.NEUTRAL, NO_GATE, NO_GATE);

        // ─── SignatureNonces ──────────────────────────────────────────────────────────────
        if (k == _key("SignatureNonces", "cancelNonce(uint256)")) return (RiskClass.RISK_REDUCING, NO_GATE, NO_GATE);

        revert UnclassifiedOperation(moduleName, signature);
    }

    /// @notice True when `gate` is an operation scope (as opposed to a pseudo-gate or `NO_GATE`).
    /// @param gate Gate identifier returned by `classify`.
    /// @return isScope Whether the gate is one of the `SCOPE_*` constants.
    function isScopeGate(bytes32 gate) internal pure returns (bool isScope) {
        return gate == SCOPE_CLAIMS || gate == SCOPE_EVIDENCE || gate == SCOPE_STAKING || gate == SCOPE_VERIFICATION
            || gate == SCOPE_SETTLEMENT || gate == SCOPE_TREASURY || gate == SCOPE_DISPUTES || gate == SCOPE_GOVERNANCE;
    }

    function _key(string memory moduleName, string memory signature) private pure returns (bytes32) {
        return keccak256(abi.encode(moduleName, signature));
    }
}

# TruthBounty Event Schema V1 (Specification §20)

The canonical event declarations are defined in `contracts/interfaces/ITruthBountyEvents.sol`. Every event carries a `uint16 version` value of `1` and a block-context `uint64 timestamp`.

## Overview of Canonical Event Families

1. **Claims**:
   - `ClaimCreatedV1`: claim ID, actor, metadata hash, timestamp, version.
   - `ClaimUpdatedV1`: claim ID, actor, metadata hash, timestamp, version.
   - `ClaimStatusTransitionedV1`: claim ID, actor, old status, new status, timestamp, version.
   - `ClaimResolvedV1`: claim ID, actor, outcome verdict, timestamp, version.
   - `ClaimFinalizedV1`: claim ID, actor, timestamp, version.

2. **Evidence**:
   - `EvidenceSubmittedV1`: claim ID, evidence ID, submitter, evidence hash, timestamp, version.
   - `EvidenceRevokedV1`: claim ID, evidence ID, actor, reason hash, timestamp, version.
   - `ClaimClosedForEvidenceV1`: claim ID, actor, timestamp, version.

3. **Staking and Collateral**:
   - `StakeDepositedV1`: verifier, amount, resulting balance, timestamp, version.
   - `StakeLockedV1`: claim ID, verifier, round, amount, resulting active stake, timestamp, version.
   - `StakeUnlockedV1`: claim ID, verifier, round, amount, resulting active stake, timestamp, version.
   - `StakeWithdrawnV1`: verifier, amount, resulting balance, timestamp, version.

4. **Verification and Voting**:
   - `VerificationSubmittedV1`: claim ID, verifier, support flag, stake amount, timestamp, version.
   - `VerificationChallengedV1`: claim ID, challenger, reason hash, timestamp, version.

5. **Rounds**:
   - `RoundStartedV1`: claim ID, round, window start, window end, min stake, timestamp, version.
   - `RoundEndedV1`: claim ID, round, total weighted for, total weighted against, participant count, timestamp, version.

6. **Outcomes and Aggregation**:
   - `OutcomeAggregatedV1`: claim ID, round, outcome, true weight, false weight, confidence BPS, timestamp, version.

7. **Disputes**:
   - `DisputeRaisedV1`: claim ID, dispute ID, challenger, bond amount, reason hash, timestamp, version.
   - `DisputeResolvedV1`: claim ID, dispute ID, resolver, ruling, resulting outcome, timestamp, version.

8. **Rewards**:
   - `RewardCalculatedV1`: calculation ID, recipient, amount, timestamp, version.
   - `RewardEscrowedV1`: claim ID, recipient, amount, timestamp, version.
   - `RewardClaimedV1`: claim ID, recipient, amount, timestamp, version.
   - `BatchRewardClaimedV1`: recipient, count, total amount, timestamp, version.

9. **Slashing**:
   - `SlashExecutedV1`: claim ID, verifier, reason, amount, timestamp, version.
   - `BatchSlashExecutedV1`: claim ID, round, count, total amount, timestamp, version.

10. **Withdrawals**:
    - `WithdrawalQueuedV1`: withdrawal ID, actor, asset, amount, unlock timestamp, timestamp, version.
    - `WithdrawalExecutedV1`: withdrawal ID, actor, asset, amount, timestamp, version.
    - `WithdrawalCancelledV1`: withdrawal ID, actor, reason hash, timestamp, version.

11. **Treasury and Solvency**:
    - `TreasuryDepositV1`: operation ID, account, asset, amount, sender, timestamp, version.
    - `TreasuryTransferV1`: operation ID, token, recipient, amount, timestamp, version.
    - `TreasuryWithdrawalV1`: operation ID, account, asset, recipient, amount, operator, timestamp, version.
    - `TreasurySnapshotRecordedV1`: snapshot ID, total assets, timestamp, version.

12. **Parameters and Configuration**:
    - `ParameterUpdatedV1`: parameter name, parameter version, old value, new value, effective at, timestamp, version.
    - `AddressParameterUpdatedV1`: parameter name, parameter version, old address, new address, timestamp, version.
    - `FeeScheduleUpdatedV1`: fee type, parameter version, fixed amount, basis points, timestamp, version.

13. **Reputation Roots and Snapshots**:
    - `ReputationRootPublishedV1`: snapshot ID, root, user count, expires at, timestamp, version.
    - `ReputationScoreUpdatedV1`: verifier, old score, new score, reason hash, timestamp, version.
    - `ReputationDecayedV1`: verifier, previous score, new score, timestamp, version.

14. **Access Control and Roles**:
    - `RoleGrantedV1`: role, account, sender, timestamp, version.
    - `RoleRevokedV1`: role, account, sender, timestamp, version.
    - `RoleAdminChangedV1`: role, previous admin role, new admin role, timestamp, version.

15. **Emergency Controls**:
    - `EmergencyPauseActivatedV1`: actor, reason, timestamp, version.
    - `EmergencyPauseRecoveredV1`: actor, timestamp, version.

16. **Upgrades and Governance**:
    - `GovernanceProposalCreatedV1`: proposal ID, proposer, metadata hash, timestamp, version.
    - `GovernanceProposalExecutedV1`: proposal ID, executor, timestamp, version.
    - `ModuleRegisteredV1`: module ID, implementation, major, minor, patch, storage layout hash, timestamp, version.
    - `UpgradeProposedV1`: proposal ID, module ID, new implementation, to major, to minor, to patch, migration hash, proposer, timestamp, version.
    - `UpgradeApprovedV1`: proposal ID, module ID, execute after, approver, timestamp, version.
    - `UpgradeExecutedV1`: proposal ID, module ID, old implementation, new implementation, executor, timestamp, version.
    - `UpgradeRolledBackV1`: module ID, old implementation, restored implementation, reason hash, guardian, timestamp, version.

## Appeal Domain (SC-017) Event Schemas

Emitted by `AppealVerificationRound`; these are modular events (separate from the `V1` canonical families above). Schemas reflect V2-SC-059 (bounded ladder, bond-gated opening, terminality).

- `AppealRoundOpened`: claim ID, deadline, min stake, multiplier BPS, opened by, round index, max rounds, required bond, bond lock ID.
- `AppealVoteSubmitted`: claim ID, verifier, support flag, stake amount, effective weight.
- `AppealRoundClosed`: claim ID, total true weight, total false weight, verifier count, closed by, round index.
- `AppealPathFinalized`: claim ID, round index, total true weight, total false weight, verifier count. *(new in V2-SC-059)*
- `DefaultAppealConfigUpdated`: duration, min stake, multiplier BPS, max weight cap, max appeal rounds, appeal bond, appeal bond escalation BPS, max appeal bond, max voters per round.
- `VaultUpdated`: old vault, new vault.
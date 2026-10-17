# TruthBounty V2 Governance (V2-SC-027)

## Overview

V2 governance introduces an OpenZeppelin `Governor` integrated with `TimelockController` for
protocol configuration changes. Governance **cannot** invoke claim-specific settlement or
outcome override calls.

## Architecture

| Contract | Role |
|----------|------|
| `TruthBountyGovernanceToken` | ERC20Votes token; delegation required before voting |
| `TruthBountyGovernor` | Proposal, voting, queue, cancel, execute lifecycle |
| `TimelockController` | Minimum execution delay after successful votes |
| `GovernedModuleRegistry` | Allowlist of proposal targets |
| `GovernanceGuardian` | Separate veto/cancel authority; no execution power |
| `GovernanceRoleTopology` | Canonical timelock role wiring (V2-SC-026 dependency) |

## Proposal Lifecycle

1. **Propose** — proposer meets threshold; targets must be registered modules; forbidden selectors rejected
2. **Pending → Active** — after `votingDelay`
3. **Vote** — simple for/against/abstain counting with quorum fraction
4. **Succeeded → Queued** — operations scheduled on timelock
5. **Execute** — only after timelock `minDelay`; duplicate execution reverts
6. **Cancel** — proposer, governance, or guardian (via `_validateCancel`)

## Forbidden Calls

`GovernanceForbiddenCalls` blocks:

- `settleClaim(uint256)` — TruthBountyWeighted / legacy paths
- `settleClaim(address,uint256)` — TruthBountyClaims
- `settleClaimsBatch(address[],uint256[])` — batch treasury payouts
- `settleClaim(uint256,bytes32)` — legacy settlement variants

## Guardian Separation

- Guardian receives `CANCELLER_ROLE` on timelock and may veto via `GovernanceGuardian`
- `GovernanceGuardian` calls `TruthBountyGovernor.cancel(proposalId)`; the governor must be wired once via `setGovernanceGuardianModule`
- Guardian cannot propose, execute, or bypass timelock delays
- Governance cannot invoke guardian emergency pause paths

## Token & Delegation Assumptions

- Voting uses timestamp clock (`mode=timestamp`)
- Holders must call `delegate()` before voting power is counted
- Proposal threshold and quorum are configurable at deploy; launch values are a separate decision

## Deployment

```bash
forge script script/deploy/DeployGovernanceV2.s.sol --rpc-url $RPC_URL --broadcast
```

Required env vars: `ADMIN_ADDRESS`, `GUARDIAN_ADDRESS`. Optional: `TIMELOCK_MIN_DELAY`,
`GOV_VOTING_DELAY`, `GOV_VOTING_PERIOD`, `GOV_PROPOSAL_THRESHOLD`, `GOV_QUORUM_NUMERATOR`,
`GOV_TOKEN_SUPPLY`.

Manifest entries are emitted via `TruthBountyGovernor.publishManifest()` and written by
`DeployBase.generateManifestWithGovernance()`.

## Reuse / Replace / Deprecate Map

| Path | Status | Notes |
|------|--------|-------|
| `contracts/governance/GovernanceController.sol` | **Retained (legacy)** | Parameter store for V1 modules; not used by V2 governor execution path |
| `contracts/governance/GovernorAccess.sol` | **Retained (legacy)** | Role helpers for legacy controller |
| `contracts/governance/v2/*` | **New (canonical V2)** | Governor proposal and execution controls |
| `contracts/utils/ResolverRoleTimelock.sol` | **Reused** | Operational resolver changes remain timelocked outside governance |

## Security Properties

- Duplicate execution prevented by OpenZeppelin governor + timelock state machine
- Stale/defeated/expired proposals cannot execute
- Proposal spam mitigated by `proposalThreshold`
- Timelock bypass prevented: governor is sole proposer; guardian cannot execute
- Target allowlist enforced at proposal creation

## Authority Boundaries (V2-SC-111)

`GovernanceAuthorityBoundaries` publishes the canonical `(role, capability)` matrix encoded by
`GovernanceAuthorityMatrix`. Each authority role is bound to at most one accountable account and an
account may hold at most one role, so overlapping authority is rejected on-chain.

| Authority | Exclusive capabilities |
|-----------|------------------------|
| Governor | `PROPOSE_PROPOSAL`, `QUEUE_PROPOSAL` |
| Timelock | `EXECUTE_PROPOSAL`, `SET_TIMELOCK_ROLES`, `UPGRADE_IMPLEMENTATION` |
| Guardian | `PAUSE_PROTOCOL` |
| Registry | `REGISTER_GOVERNED_MODULE` |
| Configuration | `SET_PROTOCOL_PARAMETER` |
| Treasury | `RELEASE_TREASURY_FUNDS` |
| Operations | `ROTATE_OPERATIONAL_ROLE` |

`CANCEL_PROPOSAL` is the only intentionally shared capability (Governor and Guardian). Claim-outcome
selectors (`settleClaim*`) belong to no authority and remain rejected by `GovernanceForbiddenCalls`.

`AUTHORITY_ADMIN_ROLE` is granted to the bootstrap admin at deployment and must be handed to the
timelock once the topology is bound, mirroring `GovernanceRoleTopology.finalizeTimelockAdmin`.

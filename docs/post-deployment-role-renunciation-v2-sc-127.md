# Post-Deployment Role Renunciation Checks (V2-SC-127)

## Overview

V2-SC-127 closes the assurance gap between deployment and operational handoff. After
every V2 deployment, the deployer EOA and any bootstrap script must hold **zero**
protocol roles. This module provides:

1. **On-chain library** — `PostDeploymentRoleCheck.sol` — deterministic role sweep
2. **Forge verification script** — `VerifyRoleRenunciation.s.sol` — live/dry-run audit
3. **Foundry unit tests** — positive, negative, boundary, authorization, replay, failure-path
4. **Foundry fuzz tests** — arbitrary addresses and target arrays
5. **Foundry invariant tests** — stateful verification that roles cannot be re-acquired
6. **Hardhat tests** — canonical V2 suite integration with `deployCanonicalV2`

## Trust Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                    POST-HANDOFF STATE                        │
│                                                             │
│  Deployer EOA ──── holds ZERO roles on ALL contracts        │
│                                                             │
│  TimelockController ─┬── TIMELOCK_ADMIN_ROLE (self)         │
│                      ├── PROPOSER_ROLE → Governor           │
│                      ├── CANCELLER_ROLE → Governor, Guardian│
│                      └── EXECUTOR_ROLE → address(0) [open]  │
│                                                             │
│  GovernedModuleRegistry ── REGISTRY_ADMIN_ROLE → Timelock   │
│                                                             │
│  GovernanceGuardian ── GUARDIAN_ROLE → Guardian EOA          │
│                        DEFAULT_ADMIN_ROLE → renounced       │
│                                                             │
│  Governor ── no AccessControl roles (uses onlyGovernance)   │
│                                                             │
│  All other modules ── DEFAULT_ADMIN_ROLE → Timelock/Gov     │
└─────────────────────────────────────────────────────────────┘
```

## Role Catalog

The library checks **27 distinct roles** covering every known V2 role hash:

| Role | Hash | Contracts |
|------|------|-----------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | All AccessControl contracts |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | WeightedStaking, VerifierSlashing, VerificationAggregator, StakeVault, TruthBountyClaims, MigrationManager, ProtocolUpgradeManager |
| `PROPOSER_ROLE` | `keccak256("PROPOSER_ROLE")` | TimelockController, ProtocolUpgradeManager |
| `EXECUTOR_ROLE` | `keccak256("EXECUTOR_ROLE")` | TimelockController, ProtocolUpgradeManager |
| `CANCELLER_ROLE` | `keccak256("CANCELLER_ROLE")` | TimelockController |
| `TIMELOCK_ADMIN_ROLE` | `keccak256("TIMELOCK_ADMIN_ROLE")` | TimelockController |
| `GUARDIAN_ROLE` | `keccak256("GUARDIAN_ROLE")` | GovernanceGuardian, ProtocolUpgradeManager |
| `GOVERNANCE_ROLE` | `keccak256("GOVERNANCE_ROLE")` | UpgradeController, TreasuryManagement |
| `REGISTRY_ADMIN_ROLE` | `keccak256("REGISTRY_ADMIN_ROLE")` | GovernedModuleRegistry |
| `REGISTRY_UPDATER_ROLE` | `keccak256("REGISTRY_UPDATER_ROLE")` | ClaimRegistry |
| `UPGRADE_ROLE` | `keccak256("UPGRADE_ROLE")` | UpgradeController |
| `EMERGENCY_UPGRADE_ROLE` | `keccak256("EMERGENCY_UPGRADE_ROLE")` | UpgradeController |
| `UPGRADER_ROLE` | `keccak256("UPGRADER_ROLE")` | MigrationManager |
| `UPGRADE_CONTROLLER_ROLE` | `keccak256("UPGRADE_CONTROLLER_ROLE")` | ProtocolUpgradeable |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | VerifierSlashing, EvidenceRegistry, MigrationManager, ProtocolUpgradeManager |
| `RESOLVER_ROLE` | `keccak256("RESOLVER_ROLE")` | VerifierSlashing |
| `ROUND_MANAGER_ROLE` | `keccak256("ROUND_MANAGER_ROLE")` | VerificationRoundManager |
| `CRITICAL_SLASHER_ROLE` | `keccak256("CRITICAL_SLASHER_ROLE")` | VerifierSlashing |
| `TREASURY_ROLE` | `keccak256("TREASURY_ROLE")` | TruthBountyClaims, TruthBountyWeighted |
| `TREASURY_MANAGER_ROLE` | `keccak256("TREASURY_MANAGER_ROLE")` | TreasuryManagement |
| `EVIDENCE_ADMIN_ROLE` | `keccak256("EVIDENCE_ADMIN_ROLE")` | EvidenceRegistry |
| `EVALUATOR_ROLE` | `keccak256("EVALUATOR_ROLE")` | ParticipationThresholdEngine |
| `CONFIG_ADMIN_ROLE` | `keccak256("CONFIG_ADMIN_ROLE")` | FrozenRoundConfigStore |
| `VALIDATOR_ROLE` | `keccak256("VALIDATOR_ROLE")` | ProtocolUpgradeManager |
| `MIGRATOR_ROLE` | `keccak256("MIGRATOR_ROLE")` | MigrationManager |
| `MINTER_ROLE` | `keccak256("MINTER_ROLE")` | Token extensions |
| `REGISTRY_ROLE` | `keccak256("REGISTRY_ROLE")` | VersionRegistry |

## Handoff Sequence

The correct post-deployment handoff must execute these steps in order:

```solidity
// 1. Wire governance topology
GovernanceRoleTopology.configure(timelock, governor, guardian, minDelay);

// 2. Transfer timelock self-administration
GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);

// 3. Transfer module registry admin to timelock
timelock.grantRole(REGISTRY_ADMIN_ROLE, address(timelock));

// 4. Renounce all deployer roles
registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
guardianContract.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
// ... repeat for every contract where deployer holds roles
```

> [!WARNING]
> Skipping any step leaves the deployer with unauthorized power. The
> `PostDeploymentRoleCheck.assertNoRolesRetained()` function will revert
> and emit `RoleRenunciationViolation` events for every retained role.

## Running Verification

### Forge (local/CI)

```bash
# Unit tests
forge test --match-contract PostDeploymentRoleRenunciationTest -vvv

# Fuzz tests
forge test --match-contract RoleRenunciationFuzz -vvv

# Invariant tests
forge test --match-contract DeployerRoleRenunciationInvariantTest -vvv

# Live deployment verification
forge script script/deploy/VerifyRoleRenunciation.s.sol \
  --rpc-url $RPC_URL \
  --sig "runFromManifest(string)" \
  "deployments/mainnet/manifest.json"
```

### Hardhat

```bash
npx hardhat test test/deployment/PostDeploymentRoleRenunciation.test.ts
```

## Test Coverage Matrix

| Category | Foundry | Hardhat | Count |
|----------|---------|---------|-------|
| Positive (handoff passes) | ✅ | ✅ | 7 |
| Negative (pre-handoff detected) | ✅ | ✅ | 6 |
| Boundary (partial, zero-addr, EOA) | ✅ | ✅ | 6 |
| Authorization (re-acquisition blocked) | ✅ | ✅ | 7 |
| Replay (idempotent checks) | ✅ | ✅ | 4 |
| Failure-path (missing steps detected) | ✅ | — | 3 |
| Fuzz (arbitrary inputs) | ✅ | — | 6 |
| Invariant (stateful) | ✅ | — | 3 |
| Catalog integrity | ✅ | — | 4 |
| **Total** | | | **46** |

## Migration Impact

- **No storage changes** — library is stateless, uses only `staticcall`.
- **No ABI changes** — no new public functions on existing contracts.
- **No active-claim impact** — read-only verification, no state mutation.
- **Backward compatible** — existing deployment scripts are unmodified; the check
  library is additive.

## Residual Risk

| Risk | Mitigation |
|------|------------|
| New role added to a contract but not in catalog | Role catalog must be updated when new roles are defined. CI should flag new `bytes32 public constant` role declarations. |
| Contract does not implement `IAccessControl` | `_safeHasRole` uses `staticcall` with error handling — returns `false` for non-conforming targets. |
| Deployer is a multisig that retains signing power | This check verifies on-chain role state only. Off-chain key custody is out of scope. |
| Timelock self-admin could be exploited | Invariant test verifies timelock retains `TIMELOCK_ADMIN_ROLE` after handoff. Governance proposals are the only path to role changes. |

## File Map

| File | Purpose |
|------|---------|
| [`PostDeploymentRoleCheck.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/contracts/deployment/PostDeploymentRoleCheck.sol) | Core library — role catalog + check logic |
| [`VerifyRoleRenunciation.s.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/script/deploy/VerifyRoleRenunciation.s.sol) | Forge script for live verification |
| [`PostDeploymentRoleRenunciation.t.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/deployment/PostDeploymentRoleRenunciation.t.sol) | Foundry unit tests (30+ cases) |
| [`RoleRenunciationFuzz.t.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/fuzz/RoleRenunciationFuzz.t.sol) | Foundry fuzz tests |
| [`DeployerRoleRenunciationInvariant.t.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/invariant/DeployerRoleRenunciationInvariant.t.sol) | Foundry invariant tests |
| [`PostDeploymentRoleRenunciation.test.ts`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/deployment/PostDeploymentRoleRenunciation.test.ts) | Hardhat integration tests |
| [`post-deployment-role-renunciation-v2-sc-127.md`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/docs/post-deployment-role-renunciation-v2-sc-127.md) | This document |

## Dependencies

- **V2-SC-111** — prerequisite (role topology definitions)
- **V2-SC-121** — prerequisite (deployment script finalization hooks)
- **V2-SC-026** — `GovernanceRoleTopology` library (consumed, not modified)
- **V2-SC-027** — V2 governance contracts (consumed, not modified)

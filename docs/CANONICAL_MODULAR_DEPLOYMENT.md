# Canonical Modular Deployment Composition (`SC-031`)

## 1. Overview

The **Canonical Modular Deployment Composition** provides the definitive dependency graph and automated deployment module for the TruthBounty V2 protocol. It replaces legacy ad-hoc deployments (`FullDeploy.ts` with legacy `TruthBountyClaims`) with a strictly ordered, role-configured, and parameterized architecture.

```
┌──────────────────────────────────────────────────────────────────┐
│             Canonical V2 Deployment Topology                     │
│                                                                  │
│  [1. GovernanceController] ◄─── Timelock & Policy Controller     │
│            ▲                                                     │
│            │                                                     │
│  [2. RewardToken]          [3. MockReputationOracle]             │
│            │                          │                          │
│            ▼                          ▼                          │
│  [4. ClaimRegistry]        [5. TruthBountyWeighted]              │
│            │                          │                          │
│            │                          ▼                          │
│            │               [6. VerificationAggregator]           │
│            │                          │                          │
│            ▼                          ▼                          │
│  [7. ProvisionalSettlementEngine] ◄───┘                          │
│            │                                                     │
│            ▼                          [8. StakeVault] ◄─────────┐
│  [9. AppealVerificationRound] (Dispute Escalation) ─────────────┘
│            │  (vault = StakeVault, OPERATOR_ROLE granted)        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. Dependency Order

1. **Governance & Ownership**:
   - `GovernanceController`: Central coordinator for DAO proposals and parameter changes.
2. **Economic & Reputation Foundation**:
   - `RewardToken`: Canonical ERC20 protocol token.
   - `MockReputationOracle`: Verifier weight multiplier source.
3. **Core Registries & Verification**:
   - `ClaimRegistry`: Immutable single source of truth for claim metadata and status.
   - `TruthBountyWeighted`: Staking vault and reputation-weighted vote collector.
4. **Consensus & Settlement Layer**:
   - `VerificationAggregator`: Deterministic consensus engine consuming verification sources.
   - `ProvisionalSettlementEngine`: Automated post-deadline round 1 settlement and dispute window activator.
   - `StakeVault`: Minimal `ISTakeVault` bond-custody vault and lock ledger (V2-SC-009 stand-in) holding appeal/challenge bonds.
   - `AppealVerificationRound`: Isolated second-round appeal manager with heightened economic security; bond-gated, bounded `maxAppealRounds` ladder (V2-SC-059).

---

## 3. Role Wiring & Access Control

- **`REGISTRY_UPDATER_ROLE`**:
  - Granted on `ClaimRegistry` exclusively to authorized settlement contracts (`ProvisionalSettlementEngine`).
  - Deployer authority is revoked during finalization to guarantee decentralization.
- **`GOVERNANCE_ROLE`**:
  - Bound to `GovernanceController` across all governance-controlled modules.
- **Vault `OPERATOR_ROLE`**:
  - Granted on `StakeVault` to `AppealVerificationRound` (`AppealVerificationRoundRoleGranted`) so the appeal module can `lockBond` appeal bonds; the vault is passed into the appeal constructor as `_vault` and exposed as `appealVerificationRound.vault()`.
- **Legacy Exclusion**:
  - Deprecated legacy contracts (such as `TruthBountyClaims` and unweighted settlement targets) are completely excluded from the canonical composition.

---

## 4. Usage

### Hardhat Ignition

```bash
npx hardhat ignition deploy ignition/modules/CanonicalV2.ts --network <network>
```

### TypeScript Composition Helper

```typescript
import { deployCanonicalV2 } from "./scripts/deployCanonicalV2";

const suite = await deployCanonicalV2(deployer);
```

## 5. Deterministic Deployment Manifest (`V2-SC-125`)

The canonical manifest is generated from versioned inputs and compiled artifacts:

```bash
DEPLOYER_ADDRESS=0x... \
DEPLOYMENT_STARTING_NONCE=0 \
RELEASE_VERSION=2.0.0 \
npm run manifest:canonical-v2
```

The generator writes `deployments/<DEPLOY_ENV>/canonical-v2-manifest.json` and
prints its Keccak-256 digest. The manifest records:

- compiler version, EVM target, optimizer, and IR settings;
- canonical contract order, constructor references, explicit library addresses,
   bytecode hashes, and deployed-bytecode hashes;
- versioned step salts, transaction indexes/nonces, dependency edges, and
   CREATE addresses derived from the deployer and starting nonce; and
- the post-deployment `REGISTRY_UPDATER_ROLE` wiring call.

The manifest contains no timestamp, private key, RPC URL, or launch address. A
fresh deployment account and the same starting nonce are required for address
reproduction. The recorded salts identify versioned deployment steps; the
current Ignition module uses ordinary CREATE transactions, not a CREATE2 factory.
Released legacy Foundry manifests remain compatible and are not rewritten by
this generator.

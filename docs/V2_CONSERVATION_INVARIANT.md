# V2 Protocol-Wide Asset Conservation Invariant

The canonical V2 custody invariant is:

`actualBalance(asset) = custody(asset) = claimable(asset) + locked(asset) + protocolAllocation(asset)`

This equation is enforced by the canonical vault in `contracts/v2/StakeVault.sol` and is exposed through the `reconcile()` and `conservation()` views.

## Canonical accounting buckets

- `claimable(asset)`: user-claimable withdrawals, unlocked and not escrowed.
- `locked(asset)`: all categorized lock cells for principal, challenge bonds, settlement allocations, etc.
- `protocolAllocation(asset)`: slashed or protocol-owned value moved out of a lock but still held in custody.
- `custody(asset)`: the full tracked amount that the vault is responsible for, matching the accounting sum above.
- `actualBalance(asset)`: the live ERC20 balance of the vault for that asset.

## Security rule

Any positive token delta not reflected in the bucket totals is invalid. The vault rejects unexplained balance drift, fee-on-transfer mismatches, and unsupported-asset accounting drift by reverting on every accounting boundary.

## Rounding and dust policy

- Burns, fee-on-transfer hooks, rebasing tokens, and token-dependent rounding are rejected by design.
- Zero-value dust is treated as a stranded-but-zero state only when the tracked bucket totals are exactly zero.
- Any nonzero residual balance that is not represented in claimable, locked, or protocol allocation is treated as a protocol invariant violation.

## Source of truth

The canonical authority remains the vault’s ERC20 balance plus its typed lock and allocation accounting; no backend, indexer, guardian, or test harness is permitted to mutate protocol custody.

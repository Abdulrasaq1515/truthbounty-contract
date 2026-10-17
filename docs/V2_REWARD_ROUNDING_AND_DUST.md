# V2 Reward Allocation Rounding and Dust Ownership (V2-SC-096)

Reward allocation splits one funded amount across several accounts by effective weight. Integer division truncates, so the split is almost never exact. This document specifies which way every division rounds and who owns what truncation leaves behind.

Enforced by `contracts/v2/FinalRewardAllocator.sol`. Tested by `test/v2/RewardAllocationRounding.t.sol`.

## The two rules

**1. Every per-recipient share rounds down.**

```
share(i) = floor(amount * effectiveWeight(i) / totalWeight)
```

Down is the only safe direction for a payout. Each recipient is credited no more than their exact pro-rata entitlement, so the shares can only ever sum to at most `amount`. Rounding up would let the sum of shares exceed the pool that funded them.

**2. The shortfall is credited to an explicit remainder recipient.**

```
remainder = amount - sum(share(i))
credited(remainderRecipient) += remainder
```

Therefore, for every allocation category:

```
sum(credited) == allocation.amount     exactly
remainder      < allocation.accounts.length
```

Dust is never stranded in the allocator and never silently absorbed.

## Why the remainder recipient is a parameter

Deciding who receives dust is an allocation-policy question, not an arithmetic one. The settlement module supplies `remainderRecipient` per category, and a zero address is rejected (`InvalidRemainderRecipient`). There is no implicit fallback — no "dust goes to the treasury by default", because a silent default is how dust ownership stops being reviewable.

The remainder recipient may also be one of the weighted accounts. In that case the dust is credited *on top of* their share.

## Rounding direction by category

All five `RewardCategory` values use the same rule. Rounding direction is a property of the operation, not of the category:

| Category | Share rounding | Dust |
| --- | --- | --- |
| `SUBMITTER_REFUND` | down | to `remainderRecipient` |
| `SUCCESSFUL_CHALLENGE` | down | to `remainderRecipient` |
| `VERIFIER_REWARD` | down | to `remainderRecipient` |
| `PROTOCOL_FEE` | down | to `remainderRecipient` |
| `INCONCLUSIVE_REFUND` | down | to `remainderRecipient` |

Each category carries its own `remainderRecipient`, so a single settlement can route verifier dust and protocol-fee dust to different owners. A category may appear at most once per settlement (`DuplicateCategory`).

## Decimals

The allocator works exclusively in an asset's base units and never reads `decimals()`. Rounding is therefore identical at every supported decimals value, across the full `V2AmountUnits.MAX_ASSET_DECIMALS` range of 0 to 36. This is asserted directly rather than assumed: `test_roundingIsIndependentOfAssetDecimals` runs the same base-unit split at 0, 2, 6, 8, 18 and 36 decimals and requires identical output.

Normalization to 18-decimal units (`V2AmountUnits`) is a reporting and cross-asset-comparison concern. It is not used in allocation, so it cannot introduce a second rounding step into a payout.

## Arithmetic

Shares are computed with `V2Precision.mulDivDown` (V2-SC-100), which evaluates `a * b / d` over a 512-bit intermediate. The previous inline form multiplied before dividing:

```solidity
uint256 share = allocation.amount * allocation.effectiveWeights[i] / totalWeight;
```

With a large amount and large effective weights that product exceeds 2^256 and the settlement reverts even though the result is representable. `test_largeAmountTimesLargeWeightDoesNotOverflow` is the regression test for it.

`totalWeight` cannot be zero: every effective weight is rejected at zero (`ZeroEffectiveWeight`) and at least one account is required.

## Security rules

- Shares round down; no operation in an allocation path rounds up.
- `sum(credited) == allocation.amount` for every category, with no exception for empty or vanishing shares.
- A weight too small to earn one base unit is credited nothing. The value is not lost — it falls into the remainder and stays owned.
- Funding is tracked per settlement id, so one settlement can never allocate against another's pool (`PoolExceeded`).
- Only the registered `SETTLEMENT` module may fund or finalize. Re-pointing the registry revokes the previous module immediately.
- Finalization is single-shot per settlement id (`SettlementAlreadyFinalized`).
- Claiming is pull-based and bounded by the credited entitlement (`InsufficientClaimable`).

## Source of truth

The allocator's `claimable(asset, account)` ledger is authoritative for entitlements. Reward events are a projection of it and carry no authority; no indexer, backend, or harness may mutate an entitlement.

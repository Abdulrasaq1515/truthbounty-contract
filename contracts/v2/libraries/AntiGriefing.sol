// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProtocolExecutionBounds} from "../../performance/ProtocolExecutionBounds.sol";

/// @title AntiGriefing
/// @notice Pure helpers that reject dust stakes / bounties and claim-creation spam (V2-SC-105).
/// @dev Modules MUST apply these checks before mutating storage or emitting claim/stake events.
///      Thresholds are governance-configured; this library only evaluates them.
library AntiGriefing {
    /// @notice Stake or bounty is below the configured economic floor.
    error DustAmount(uint256 provided, uint256 minimum);

    /// @notice Account exceeded the per-window claim creation budget.
    error ClaimRateExceeded(address account, uint256 count, uint256 limit);

    /// @notice Account holds too many non-terminal claims (storage / indexer griefing).
    error TooManyOpenClaims(address account, uint256 count, uint256 limit);

    /// @notice Submission fee was not paid in full.
    error InsufficientClaimFee(uint256 paid, uint256 required);

    /// @dev Reverts when `amount` is zero or strictly below `minimum`.
    function requireMinAmount(uint256 amount, uint256 minimum) internal pure {
        if (amount < minimum) revert DustAmount(amount, minimum);
    }

    /// @dev Reverts when `paid` is below the required claim submission fee.
    function requireClaimFee(uint256 paid, uint256 required) internal pure {
        if (paid < required) revert InsufficientClaimFee(paid, required);
    }

    /// @dev Sliding-window claim spam check. Returns the next window counters to persist.
    /// @param account Claim creator.
    /// @param nowTs Current block timestamp.
    /// @param windowStart Start of the active rate window (0 if unset).
    /// @param claimsInWindow Claims already created in the active window.
    /// @param maxPerWindow Maximum allowed creations per window (0 => protocol default).
    /// @param windowLength Window length in seconds (0 => protocol default).
    /// @return newWindowStart Window start after this creation.
    /// @return newClaimsInWindow Claim count after this creation.
    function nextClaimWindow(
        address account,
        uint64 nowTs,
        uint64 windowStart,
        uint256 claimsInWindow,
        uint256 maxPerWindow,
        uint64 windowLength
    ) internal pure returns (uint64 newWindowStart, uint256 newClaimsInWindow) {
        uint256 limit = maxPerWindow == 0
            ? ProtocolExecutionBounds.MAX_CLAIMS_PER_ACCOUNT_WINDOW
            : maxPerWindow;
        uint64 window = windowLength == 0
            ? uint64(ProtocolExecutionBounds.CLAIM_SPAM_WINDOW_SECONDS)
            : windowLength;

        // V2-SC-161: compare in uint256 so a window start near type(uint64).max cannot overflow
        // (panic) the uint64 sum; the comparison is otherwise identical.
        if (windowStart == 0 || uint256(nowTs) >= uint256(windowStart) + uint256(window)) {
            return (nowTs, 1);
        }

        uint256 next = claimsInWindow + 1;
        if (next > limit) revert ClaimRateExceeded(account, next, limit);
        return (windowStart, next);
    }

    /// @dev Ensures open (non-terminal) claim inventory stays bounded per creator.
    function requireOpenClaimCapacity(address account, uint256 openCount, uint256 maxOpen) internal pure {
        uint256 limit = maxOpen == 0 ? ProtocolExecutionBounds.MAX_OPEN_CLAIMS_PER_CREATOR : maxOpen;
        if (openCount >= limit) revert TooManyOpenClaims(account, openCount, limit);
    }
}

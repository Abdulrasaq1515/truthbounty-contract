// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { BoundedStaticCall } from "../../libraries/BoundedStaticCall.sol";

/// @title V2AmountUnits
/// @notice Explicit conversion between an asset's native base units and 18-decimal normalized units.
/// @dev All custody accounting stays in native asset units; normalized units are only used for
///      cross-asset comparison and reporting. Conversions round down (toward the protocol) deterministically.
library V2AmountUnits {
    /// @notice Decimals used for normalized (WAD) amounts.
    uint8 internal constant NORMALIZED_DECIMALS = 18;

    /// @notice Largest supported asset decimals.
    uint8 internal constant MAX_ASSET_DECIMALS = 36;

    /// @notice Thrown when an asset reports unsupported or unreadable decimals.
    error UnsupportedDecimals(address asset);

    /// @notice Thrown when a decimals value exceeds `MAX_ASSET_DECIMALS`.
    error DecimalsOutOfRange(uint8 decimals);

    /// @notice Reads an asset's decimals, failing closed on missing, malformed, or out-of-range values.
    function decimalsOf(address asset) internal view returns (uint8) {
        if (asset.code.length == 0) revert UnsupportedDecimals(asset);
        (bool ok, uint256 raw, uint256 returnSize) = BoundedStaticCall.staticcallWord(
            asset,
            abi.encodeCall(IERC20Metadata.decimals, ())
        );
        if (!ok || returnSize != 32) revert UnsupportedDecimals(asset);
        if (raw > MAX_ASSET_DECIMALS) revert UnsupportedDecimals(asset);
        return uint8(raw);
    }

    /// @notice Converts a native-unit amount into 18-decimal normalized units (rounds down).
    function toNormalized(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_ASSET_DECIMALS) revert DecimalsOutOfRange(decimals);
        if (decimals == NORMALIZED_DECIMALS) return amount;
        if (decimals < NORMALIZED_DECIMALS) return amount * 10 ** (NORMALIZED_DECIMALS - decimals);
        return amount / 10 ** (decimals - NORMALIZED_DECIMALS);
    }

    /// @notice Converts an 18-decimal normalized amount into native units (rounds down).
    function fromNormalized(uint256 normalized, uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_ASSET_DECIMALS) revert DecimalsOutOfRange(decimals);
        if (decimals == NORMALIZED_DECIMALS) return normalized;
        if (decimals < NORMALIZED_DECIMALS) return normalized / 10 ** (NORMALIZED_DECIMALS - decimals);
        return normalized * 10 ** (decimals - NORMALIZED_DECIMALS);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Scoped emergency pause interface.
/// @dev Pause state is fail-closed for mutating protocol operations; only the configured emergency authority may change it and unpause must satisfy configured cooldowns.
interface IEmergencyControls is IV2Module {
    /// @notice Emitted when a scope is paused.
    /// @param scope Stable module or protocol scope identifier.
    /// @param actor Emergency authority that paused the scope.
    event EmergencyPaused(bytes32 indexed scope, address indexed actor);

    /// @notice Emitted when a scope is unpaused.
    /// @param scope Stable module or protocol scope identifier.
    /// @param actor Emergency authority that unpaused the scope.
    event EmergencyUnpaused(bytes32 indexed scope, address indexed actor);

    /// @notice Pauses all protected operations in a scope.
    /// @dev Must require emergency authority and preserve already finalized state while blocking new transitions.
    /// @param scope Stable scope identifier.
    function pause(bytes32 scope) external;

    /// @notice Unpauses a scope after the configured recovery rules are satisfied.
    /// @dev Must require the authorized recovery role and revert while cooldown or governance conditions remain unsatisfied.
    /// @param scope Stable scope identifier.
    function unpause(bytes32 scope) external;

    /// @notice Reports whether a scope is currently paused.
    /// @param scope Stable scope identifier.
    /// @return isPaused True while new operations must fail closed.
    function paused(bytes32 scope) external view returns (bool isPaused);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Scoped emergency pause interface.
/// @dev Pause state is fail-closed for mutating protocol operations; only the configured emergency authority may change it and unpause must satisfy configured cooldowns.
/// @dev Every pausable mutation is identified by a stable operation ID derived from function/interface authority. Operation IDs are canonical, collision-resistant, and scoped to a single scope so they cannot be aliased or escalated to global pause state.
interface IEmergencyControls is IV2Module {
    /// @notice Emitted when a scope is paused.
    /// @param scope Stable module or protocol scope identifier.
    /// @param actor Emergency authority that paused the scope.
    event EmergencyPaused(bytes32 indexed scope, address indexed actor);

    /// @notice Emitted when a scope is unpaused.
    /// @param scope Stable module or protocol scope identifier.
    /// @param actor Emergency authority that unpaused the scope.
    event EmergencyUnpaused(bytes32 indexed scope, address indexed actor);

    /// @notice Emitted when an operation within a scope is paused.
    /// @param scope Stable module or protocol scope identifier.
    /// @param operationId Canonical operation ID derived from function/interface authority.
    /// @param actor Emergency authority that paused the operation.
    event OperationPaused(bytes32 indexed scope, bytes32 indexed operationId, address indexed actor);

    /// @notice Emitted when an operation within a scope is unpaused.
    /// @param scope Stable module or protocol scope identifier.
    /// @param operationId Canonical operation ID derived from function/interface authority.
    /// @param actor Emergency authority that unpaused the operation.
    event OperationUnpaused(bytes32 indexed scope, bytes32 indexed operationId, address indexed actor);

    /// @notice Emitted when a canonical operation ID is registered for a scope.
    /// @param scope Stable module or protocol scope identifier.
    /// @param operationId Canonical operation ID derived from function/interface authority.
    /// @param selector Function selector that the operation ID binds to.
    event OperationRegistered(bytes32 indexed scope, bytes32 indexed operationId, bytes4 indexed selector);

    /// @notice Pauses all protected operations in a scope.
    /// @dev Must require emergency authority and preserve already finalized state while blocking new transitions.
    /// @param scope Stable scope identifier.
    function pause(bytes32 scope) external;

    /// @notice Unpauses a scope after the configured recovery rules are satisfied.
    /// @dev Must require the authorized recovery role and revert while cooldown or governance conditions remain unsatisfied.
    /// @param scope Stable scope identifier.
    function unpause(bytes32 scope) external;

    /// @notice Pauses a single canonical operation within a scope.
    /// @dev Must require emergency authority, reject unknown operation IDs, and never alias another operation or global scope.
    /// @param scope Stable scope identifier.
    /// @param operationId Canonical operation ID derived from function/interface authority.
    function pauseOperation(bytes32 scope, bytes32 operationId) external;

    /// @notice Unpauses a single canonical operation within a scope.
    /// @dev Must require the authorized recovery role and revert while cooldown or governance conditions remain unsatisfied.
    /// @param scope Stable scope identifier.
    /// @param operationId Canonical operation ID derived from function/interface authority.
    function unpauseOperation(bytes32 scope, bytes32 operationId) external;

    /// @notice Reports whether a scope is currently paused.
    /// @param scope Stable scope identifier.
    /// @return isPaused True while new operations must fail closed.
    function paused(bytes32 scope) external view returns (bool isPaused);

    /// @notice Reports whether a specific operation within a scope is currently paused.
    /// @dev Must fail closed for unknown operation IDs.
    /// @param scope Stable scope identifier.
    /// @param operationId Canonical operation ID derived from function/interface authority.
    /// @return isPaused True while the operation must fail closed.
    function operationPaused(bytes32 scope, bytes32 operationId) external view returns (bool isPaused);

    /// @notice Returns the canonical operation ID for a given scope and function selector.
    /// @dev Must return a stable ID derived from function/interface authority and must revert for unknown or aliased selectors.
    /// @param scope Stable scope identifier.
    /// @param selector Function selector to resolve.
    /// @return operationId Canonical operation ID bound to the scope and selector.
    function operationIdForSelector(bytes32 scope, bytes4 selector) external view returns (bytes32 operationId);

    /// @notice Returns the function selector bound to a canonical operation ID within a scope.
    /// @dev Must revert for unknown operation IDs and must not alias across scopes.
    /// @param scope Stable scope identifier.
    /// @param operationId Canonical operation ID derived from function/interface authority.
    /// @return selector Function selector bound to the operation ID.
    function selectorForOperationId(bytes32 scope, bytes32 operationId) external view returns (bytes4 selector);

    /// @notice Returns the canonical operation IDs registered for a scope.
    /// @dev The returned matrix must match runtime checks and must not include aliases.
    /// @param scope Stable scope identifier.
    /// @return operationIds Canonical operation IDs for the scope.
    function operationIdsForScope(bytes32 scope) external view returns (bytes32[] memory operationIds);

    /// @notice Returns the canonical operation ID for a scope and function signature.
    /// @dev Must be deterministic and must revert for unknown or aliased signatures.
    /// @param scope Stable scope identifier.
    /// @param signature Canonical function signature.
    /// @return operationId Canonical operation ID bound to the scope and signature.
    function operationIdForSignature(bytes32 scope, bytes memory signature) external view returns (bytes32 operationId);
}

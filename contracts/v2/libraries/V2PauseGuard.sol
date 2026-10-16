// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEmergencyControls} from "../interfaces/IEmergencyControls.sol";
import {V2Errors} from "./V2Errors.sol";
import {PauseMatrix} from "./PauseMatrix.sol";
import {EmergencyPauseOrdering} from "../../governance/libraries/EmergencyPauseOrdering.sol";

/// @title V2PauseGuard
/// @notice Shared enforcement of the V2-SC-162 pause matrix for canonical V2 modules.
/// @dev Storage-free. Inheriting modules decide where their pause authority comes from by
///      implementing `_pauseAuthority()` (registry-resolved or write-once wired, see
///      `V2WiredPauseGuard`), and apply exactly one of two gates per operation, as recorded in
///      `PauseMatrix` / `config/pause-matrix.json`:
///
///      - `_requireScopeNotPaused(scope)` for RISK_INCREASING operations. Fails closed: it reverts
///        with `V2Errors.ProtocolPaused` while the scope is paused, when the authority cannot be
///        resolved, or when the authority call reverts or returns malformed data.
///      - `_requireExitsNotShutdown()` for RISK_REDUCING value exits. Fails open: only an affirmative,
///        healthy protocol SHUTDOWN reading freezes exits, so exit liveness never depends on the
///        health of the pause authority, its protocol-level dependency, or the module registry.
///
///      An unwired module (authority resolves to `address(0)`) enforces no scoped pause; that is the
///      pre-V2-SC-162 behaviour and deployments MUST wire an authority before accepting value.
abstract contract V2PauseGuard {
    /// @notice Gas forwarded to each authority / registry probe on the exit path.
    /// @dev Bounds the gas a hostile or broken dependency can burn, so it cannot starve an exit;
    ///      an exhausted probe reads as "not frozen" (exit path) or "unresolved" (risk path).
    uint256 internal constant PROBE_GAS_LIMIT = 100_000;

    /// @notice A value exit was attempted while the protocol is at emergency SHUTDOWN.
    error ExitsFrozenByShutdown();

    /// @notice Returns the pause matrix version this module enforces.
    /// @return version `PauseMatrix.PAUSE_MATRIX_VERSION`.
    function pauseMatrixVersion() external pure returns (uint16 version) {
        return PauseMatrix.PAUSE_MATRIX_VERSION;
    }

    /// @notice Returns the currently resolved pause authority.
    /// @return resolved False when the authority source (e.g. the registry) could not be read.
    /// @return authority The resolved `IEmergencyControls` authority, or `address(0)` when unwired.
    function pauseAuthority() external view returns (bool resolved, address authority) {
        return _pauseAuthority();
    }

    /// @notice Read-only classification of a scope as seen by this module's risk-increasing gates.
    /// @dev Never reverts. Returns true whenever `_requireScopeNotPaused(scope)` would revert.
    /// @param scope Operation scope to classify.
    /// @return isPaused True while risk-increasing operations on `scope` must fail closed.
    function isScopePaused(bytes32 scope) public view returns (bool isPaused) {
        (bool resolved, address authority) = _pauseAuthority();
        if (!resolved) return true;
        if (authority == address(0)) return false;
        return _queryScopePaused(authority, scope);
    }

    /// @notice Whether value exits are currently frozen by a protocol-level SHUTDOWN.
    /// @dev Never reverts. True only when the authority exposes `emergencyController()`, that
    ///      controller answers `isOperationAllowed(pull_settled_claim)` successfully, and the answer
    ///      is `false` (EmergencyPauseOrdering: SHUTDOWN only). Every failure mode reads as "not frozen".
    /// @return frozen True while value exits must wait for governance to lift the shutdown.
    function exitsFrozen() public view returns (bool frozen) {
        (bool resolved, address authority) = _pauseAuthority();
        if (!resolved || authority == address(0)) return false;

        (bool ok, bytes memory data) =
            authority.staticcall{gas: PROBE_GAS_LIMIT}(abi.encodeWithSignature("emergencyController()"));
        if (!ok || data.length < 32) return false;
        uint256 rawController = abi.decode(data, (uint256));
        if (rawController == 0 || rawController > type(uint160).max) return false;
        address controller = address(uint160(rawController));

        (ok, data) = controller.staticcall{gas: PROBE_GAS_LIMIT}(
            abi.encodeWithSignature("isOperationAllowed(bytes32)", EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM)
        );
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (uint256)) == 0;
    }

    /// @notice Fail-closed gate for RISK_INCREASING operations.
    /// @param scope Operation scope that must not be paused.
    function _requireScopeNotPaused(bytes32 scope) internal view {
        if (isScopePaused(scope)) revert V2Errors.ProtocolPaused();
    }

    /// @notice Fail-open gate for RISK_REDUCING value exits (freezes only at protocol SHUTDOWN).
    function _requireExitsNotShutdown() internal view {
        if (exitsFrozen()) revert ExitsFrozenByShutdown();
    }

    /// @notice Resolves the pause authority for this module.
    /// @return resolved False when the authority source could not be read (risk-increasing gates fail closed).
    /// @return authority The `IEmergencyControls` authority, or `address(0)` when none is wired.
    function _pauseAuthority() internal view virtual returns (bool resolved, address authority);

    /// @notice Resolves the pause authority from a module registry under `EMERGENCY_CONTROLS`.
    /// @dev A reverting registry, short returndata, or a non-address word reads as unresolved.
    ///      Changing the resolved authority therefore follows the registry's own (timelocked)
    ///      module-replacement path; a module cannot swap its pause authority locally.
    /// @param registry Module registry exposing `module(bytes32) returns (address,uint16,uint16)`.
    /// @return resolved Whether the registry answered well-formed data.
    /// @return authority The registered authority (zero when the key is not registered).
    function _registryPauseAuthority(address registry) internal view returns (bool resolved, address authority) {
        (bool ok, bytes memory data) = registry.staticcall{gas: PROBE_GAS_LIMIT}(
            abi.encodeWithSignature("module(bytes32)", PauseMatrix.MODULE_EMERGENCY_CONTROLS)
        );
        if (!ok || data.length < 96) return (false, address(0));
        uint256 raw = abi.decode(data, (uint256));
        if (raw > type(uint160).max) return (false, address(0));
        return (true, address(uint160(raw)));
    }

    function _queryScopePaused(address authority, bytes32 scope) private view returns (bool) {
        (bool ok, bytes memory data) = authority.staticcall(abi.encodeCall(IEmergencyControls.paused, (scope)));
        if (!ok || data.length < 32) return true;
        return abi.decode(data, (uint256)) != 0;
    }
}

/// @title V2WiredPauseGuard
/// @notice `V2PauseGuard` variant for modules without a module registry: the pause authority is
///         wired exactly once by the module's administrator and can never be replaced or removed.
/// @dev Write-once wiring is deliberate. Wiring only ever tightens control (fail-closed direction);
///      forbidding replacement means a module administrator can never lift an active pause by
///      pointing the module at a different or empty authority, so lifting a pause always goes
///      through the authority's own resolver / governance path. Rotating the authority itself is
///      done inside the authority (e.g. `EmergencyGatekeeper.setEmergencyController`, timelocked).
abstract contract V2WiredPauseGuard is V2PauseGuard {
    address private _wiredPauseAuthority;

    /// @notice Emitted once when the module's pause authority is wired.
    /// @param authority The wired `IEmergencyControls` authority.
    /// @param matrixVersion Pause matrix version enforced by the module.
    event PauseAuthorityWired(address indexed authority, uint16 matrixVersion);

    /// @notice The pause authority has already been wired and cannot be replaced.
    error PauseAuthorityAlreadyWired(address authority);
    /// @notice The proposed authority is zero or does not answer `paused(bytes32)`.
    error InvalidPauseAuthority(address authority);

    /// @notice Wires the pause authority exactly once.
    /// @param authority `IEmergencyControls` implementation (e.g. `EmergencyGatekeeper`).
    function _wirePauseAuthority(address authority) internal {
        if (authority == address(0)) revert InvalidPauseAuthority(authority);
        address current = _wiredPauseAuthority;
        if (current != address(0)) revert PauseAuthorityAlreadyWired(current);

        (bool ok, bytes memory data) =
            authority.staticcall(abi.encodeCall(IEmergencyControls.paused, (PauseMatrix.SCOPE_CLAIMS)));
        if (!ok || data.length < 32) revert InvalidPauseAuthority(authority);

        _wiredPauseAuthority = authority;
        emit PauseAuthorityWired(authority, PauseMatrix.PAUSE_MATRIX_VERSION);
    }

    /// @dev Returns the write-once wired authority (`address(0)` until wired).
    function _pauseAuthority() internal view virtual override returns (bool resolved, address authority) {
        return (true, _wiredPauseAuthority);
    }
}

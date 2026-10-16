// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IEmergencyControls} from "./interfaces/IEmergencyControls.sol";
import {IV2Module} from "./interfaces/IV2Module.sol";
import {V2Errors} from "./libraries/V2Errors.sol";
import {V2SafeCast} from "./libraries/V2SafeCast.sol";

/**
 * @title EmergencyControls
 * @notice Canonical TruthBounty V2 emergency pause and circuit-breaker module.
 * @dev Implements scoped protocol pausing with strict separation of powers:
 *      - EMERGENCY_ROLE can pause scopes rapidly in response to detected incidents.
 *      - GOVERNANCE_ROLE is strictly required to unpause (emergency role cannot lift pauses).
 *      - Global pause (SCOPE_ALL = bytes32(0)) halts all scopes.
 *      - All administrative roles are subordinated to GOVERNANCE_ROLE to prevent admin privilege escalation.
 *      - Conforms to IEmergencyControls, IV2Module, and ERC-165 standards.
 */
contract EmergencyControls is ERC165, AccessControl, IEmergencyControls {
    // ─── Constants ────────────────────────────────────────────────────

    /// @notice Canonical event schema version for V2 event logging
    uint16 public constant EVENT_SCHEMA_VERSION = 1;

    // ─── Roles ────────────────────────────────────────────────────────

    /// @notice Rapid emergency responder role (can pause, cannot unpause)
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice DAO / Timelocked governance role (can pause and unpause)
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // ─── Well-Known Scopes ────────────────────────────────────────────

    /// @notice Global scope affecting all operations
    bytes32 public constant SCOPE_ALL = bytes32(0);

    /// @notice Scope for new claim creation and registration
    bytes32 public constant SCOPE_CLAIMS = keccak256("CLAIMS");

    /// @notice Scope for evidence submission
    bytes32 public constant SCOPE_EVIDENCE = keccak256("EVIDENCE");

    /// @notice Scope for verifier staking and deposits
    bytes32 public constant SCOPE_STAKING = keccak256("STAKING");

    /// @notice Scope for verification attestations
    bytes32 public constant SCOPE_VERIFICATION = keccak256("VERIFICATION");

    /// @notice Scope for claim settlement and reward distribution
    bytes32 public constant SCOPE_SETTLEMENT = keccak256("SETTLEMENT");

    /// @notice Scope for treasury movements and withdrawals
    bytes32 public constant SCOPE_TREASURY = keccak256("TREASURY");

    /// @notice Scope for dispute initiation and resolution
    bytes32 public constant SCOPE_DISPUTES = keccak256("DISPUTES");

    // ─── Operation IDs ────────────────────────────────────────────────

    /// @notice Canonical operation ID for pausing a scope
    bytes32 public constant OP_PAUSE = keccak256("EmergencyControls.pause(bytes32)");

    /// @notice Canonical operation ID for unpausing a scope
    bytes32 public constant OP_UNPAUSE = keccak256("EmergencyControls.unpause(bytes32)");

    /// @notice Canonical operation ID for checking paused status
    bytes32 public constant OP_PAUSED = keccak256("EmergencyControls.paused(bytes32)");

    /// @notice Canonical operation ID for checking specific scope pause status
    bytes32 public constant OP_IS_SCOPE_SPECIFICALLY_PAUSED =
        keccak256("EmergencyControls.isScopeSpecificallyPaused(bytes32)");

    /// @notice Canonical operation ID for pausing all operations globally
    bytes32 public constant OP_PAUSE_ALL = keccak256("EmergencyControls.pauseAll()");

    /// @notice Canonical operation ID for unpausing all operations globally
    bytes32 public constant OP_UNPAUSE_ALL = keccak256("EmergencyControls.unpauseAll()");

    /// @notice Canonical operation ID for checking global pause status
    bytes32 public constant OP_IS_GLOBALLY_PAUSED = keccak256("EmergencyControls.isGloballyPaused()");

    // ─── Custom Errors ────────────────────────────────────────────────

    error AlreadyPaused(bytes32 scope);
    error NotPaused(bytes32 scope);
    error UnauthorizedToPause(address account);
    error UnauthorizedToUnpause(address account);
    error UnknownOperation(bytes32 operationId);
    error OperationIdCollision(bytes32 operationId);
    error InvalidScope(bytes32 scope);

    // ─── State ────────────────────────────────────────────────────────

    /// @notice Mapping from scope hash to paused status
    mapping(bytes32 => bool) private _pausedScopes;

    /// @notice Mapping from scope to timestamp when it was paused (0 if not paused)
    mapping(bytes32 => uint256) public pausedAt;

    /// @notice Mapping from scope to total number of times it has been paused
    mapping(bytes32 => uint256) public pauseCount;

    /// @notice Mapping from operation ID to canonical operation name
    mapping(bytes32 => string) private _operationNames;

    /// @notice Mapping from operation ID to whether it is registered
    mapping(bytes32 => bool) private _operationRegistered;

    // ─── Constructor ──────────────────────────────────────────────────

    /**
     * @param admin Initial administrator account
     * @param emergencyCouncil Address granted rapid emergency pause powers
     * @param governance Address representing DAO governance / timelock
     */
    constructor(address admin, address emergencyCouncil, address governance) {
        if (admin == address(0) || emergencyCouncil == address(0) || governance == address(0)) {
            revert V2Errors.ZeroAddress();
        }

        // Subordinate all role administration under GOVERNANCE_ROLE
        // to prevent DEFAULT_ADMIN_ROLE from escalating privileges or granting unpause powers
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(GOVERNANCE_ROLE, governance);
        _grantRole(EMERGENCY_ROLE, emergencyCouncil);

        if (admin != governance) {
            _grantRole(DEFAULT_ADMIN_ROLE, admin);
        }

        _setRoleAdmin(DEFAULT_ADMIN_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(GOVERNANCE_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(EMERGENCY_ROLE, GOVERNANCE_ROLE);

        // Register canonical operation IDs
        _registerOperation(OP_PAUSE, "pause(bytes32)");
        _registerOperation(OP_UNPAUSE, "unpause(bytes32)");
        _registerOperation(OP_PAUSED, "paused(bytes32)");
        _registerOperation(OP_IS_SCOPE_SPECIFICALLY_PAUSED, "isScopeSpecificallyPaused(bytes32)");
        _registerOperation(OP_PAUSE_ALL, "pauseAll()");
        _registerOperation(OP_UNPAUSE_ALL, "unpauseAll()");
        _registerOperation(OP_IS_GLOBALLY_PAUSED, "isGloballyPaused()");
    }

    // ─── IV2Module ────────────────────────────────────────────────────

    /// @inheritdoc IV2Module
    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    // ─── ERC-165 ──────────────────────────────────────────────────────

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, AccessControl, IERC165)
        returns (bool)
    {
        return interfaceId == type(IEmergencyControls).interfaceId
            || interfaceId == type(IV2Module).interfaceId
            || interfaceId == type(IAccessControl).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ─── IEmergencyControls ───────────────────────────────────────────

    /**
     * @notice Pause operations for a given scope.
     * @dev Callable by either EMERGENCY_ROLE (rapid response) or GOVERNANCE_ROLE.
     * @param scope Identifier of the scope to pause (bytes32(0) for global).
     */
    function pause(bytes32 scope) external override {
        if (!hasRole(EMERGENCY_ROLE, msg.sender) && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert UnauthorizedToPause(msg.sender);
        }
        if (!_operationRegistered[OP_PAUSE]) revert UnknownOperation(OP_PAUSE);
        if (_pausedScopes[scope]) revert AlreadyPaused(scope);

        _pausedScopes[scope] = true;
        pausedAt[scope] = block.timestamp;
        pauseCount[scope]++;

        emit EmergencyPaused(scope, msg.sender);
    }

    /**
     * @notice Unpause operations for a given scope.
     * @dev Separation of powers: strictly callable by GOVERNANCE_ROLE only.
     *      EMERGENCY_ROLE CANNOT unpause.
     * @param scope Identifier of the scope to unpause.
     */
    function unpause(bytes32 scope) external override {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert UnauthorizedToUnpause(msg.sender);
        }
        if (!_operationRegistered[OP_UNPAUSE]) revert UnknownOperation(OP_UNPAUSE);
        if (!_pausedScopes[scope]) revert NotPaused(scope);

        _pausedScopes[scope] = false;
        pausedAt[scope] = 0;

        emit EmergencyUnpaused(scope, msg.sender);
    }

    /**
     * @notice Check whether operations for a given scope are currently paused.
     * @dev If the global scope (SCOPE_ALL) is paused, any sub-scope is considered paused.
     * @param scope Identifier of the scope to check.
     * @return True if either the specific scope or the global scope is paused.
     */
    function paused(bytes32 scope) external view override returns (bool) {
        if (!_operationRegistered[OP_PAUSED]) revert UnknownOperation(OP_PAUSED);
        return _pausedScopes[SCOPE_ALL] || _pausedScopes[scope];
    }

    /**
     * @notice Check whether a scope is specifically paused (ignoring global state).
     * @param scope Identifier of the scope.
     * @return True if the specific scope itself is marked paused.
     */
    function isScopeSpecificallyPaused(bytes32 scope) external view returns (bool) {
        if (!_operationRegistered[OP_IS_SCOPE_SPECIFICALLY_PAUSED]) {
            revert UnknownOperation(OP_IS_SCOPE_SPECIFICALLY_PAUSED);
        }
        return _pausedScopes[scope];
    }

    /**
     * @notice Pause all operations globally.
     * @dev Convenience wrapper around pause(SCOPE_ALL).
     */
    function pauseAll() external {
        if (!hasRole(EMERGENCY_ROLE, msg.sender) && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert UnauthorizedToPause(msg.sender);
        }
        if (!_operationRegistered[OP_PAUSE_ALL]) revert UnknownOperation(OP_PAUSE_ALL);
        if (_pausedScopes[SCOPE_ALL]) revert AlreadyPaused(SCOPE_ALL);

        _pausedScopes[SCOPE_ALL] = true;
        pausedAt[SCOPE_ALL] = block.timestamp;
        pauseCount[SCOPE_ALL]++;

        emit EmergencyPaused(SCOPE_ALL, msg.sender);
    }

    /**
     * @notice Unpause all operations globally.
     * @dev Convenience wrapper around unpause(SCOPE_ALL). GOVERNANCE_ROLE only.
     */
    function unpauseAll() external {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert UnauthorizedToUnpause(msg.sender);
        }
        if (!_operationRegistered[OP_UNPAUSE_ALL]) revert UnknownOperation(OP_UNPAUSE_ALL);
        if (!_pausedScopes[SCOPE_ALL]) revert NotPaused(SCOPE_ALL);

        _pausedScopes[SCOPE_ALL] = false;
        pausedAt[SCOPE_ALL] = 0;

        emit EmergencyUnpaused(SCOPE_ALL, msg.sender);
    }

    /**
     * @notice Check whether the global scope is paused.
     * @return True if the global scope is paused.
     */
    function isGloballyPaused() external view returns (bool) {
        if (!_operationRegistered[OP_IS_GLOBALLY_PAUSED]) {
            revert UnknownOperation(OP_IS_GLOBALLY_PAUSED);
        }
        return _pausedScopes[SCOPE_ALL];
    }

    /**
     * @notice Get the canonical operation name for a given operation ID.
     * @param operationId The operation ID to look up.
     * @return The canonical operation name.
     */
    function operationName(bytes32 operationId) external view returns (string memory) {
        if (!_operationRegistered[operationId]) revert UnknownOperation(operationId);
        return _operationNames[operationId];
    }

    /**
     * @notice Check whether an operation ID is registered.
     * @param operationId The operation ID to check.
     * @return True if the operation ID is registered.
     */
    function isOperationRegistered(bytes32 operationId) external view returns (bool) {
        return _operationRegistered[operationId];
    }

    /**
     * @notice Get the full operation matrix for frontend/API consumers.
     * @return ids Array of operation IDs.
     * @return names Array of canonical operation names.
     */
    function operationMatrix() external view returns (bytes32[] memory ids, string[] memory names) {
        ids = new bytes32[](7);
        names = new string[](7);

        ids[0] = OP_PAUSE;
        names[0] = _operationNames[OP_PAUSE];
        ids[1] = OP_UNPAUSE;
        names[1] = _operationNames[OP_UNPAUSE];
        ids[2] = OP_PAUSED;
        names[2] = _operationNames[OP_PAUSED];
        ids[3] = OP_IS_SCOPE_SPECIFICALLY_PAUSED;
        names[3] = _operationNames[OP_IS_SCOPE_SPECIFICALLY_PAUSED];
        ids[4] = OP_PAUSE_ALL;
        names[4] = _operationNames[OP_PAUSE_ALL];
        ids[5] = OP_UNPAUSE_ALL;
        names[5] = _operationNames[OP_UNPAUSE_ALL];
        ids[6] = OP_IS_GLOBALLY_PAUSED;
        names[6] = _operationNames[OP_IS_GLOBALLY_PAUSED];
    }

    // ─── Internal Helpers ─────────────────────────────────────────────

    /**
     * @dev Register a canonical operation ID. Reverts on collision.
     * @param operationId The operation ID to register.
     * @param name The canonical operation name.
     */
    function _registerOperation(bytes32 operationId, string memory name) internal {
        if (_operationRegistered[operationId]) revert OperationIdCollision(operationId);
        _operationRegistered[operationId] = true;
        _operationNames[operationId] = name;
    }
}

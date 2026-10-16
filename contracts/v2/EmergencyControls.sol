// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

    // ─── Custom Errors ────────────────────────────────────────────────

    error AlreadyPaused(bytes32 scope);
    error NotPaused(bytes32 scope);
    error UnauthorizedToPause(address account);
    error UnauthorizedToUnpause(address account);

    // ─── State ────────────────────────────────────────────────────────

    /// @notice Mapping from scope hash to paused status
    mapping(bytes32 => bool) private _pausedScopes;

    /// @notice Mapping from scope to timestamp when it was paused (0 if not paused)
    mapping(bytes32 => uint256) public pausedAt;

    /// @notice Mapping from scope to total number of times it has been paused
    mapping(bytes32 => uint256) public pauseCount;

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
        return _pausedScopes[SCOPE_ALL] || _pausedScopes[scope];
    }

    /**
     * @notice Check whether a scope is specifically paused (ignoring global state).
     * @param scope Identifier of the scope.
     * @return True if the specific scope itself is marked paused.
     */
    function isScopeSpecificallyPaused(bytes32 scope) external view returns (bool) {
        return _pausedScopes[scope];
    }
}

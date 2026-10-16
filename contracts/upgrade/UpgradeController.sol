// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IUpgradeController.sol";
import "./IVersionRegistry.sol";
import "./StorageCompatibilityValidator.sol";

/**
 * @title UpgradeController
 * @notice Governance-controlled upgrade lifecycle manager
 * @dev Manages the full upgrade lifecycle: propose → schedule → execute
 *      Integrates with VersionRegistry for canonical version tracking
 *      and StorageCompatibilityValidator for layout safety checks
 */
contract UpgradeController is IUpgradeController, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");
    bytes32 public constant EMERGENCY_UPGRADE_ROLE = keccak256("EMERGENCY_UPGRADE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice Version tag of the upgrade-hash commitment scheme (V2-SC-160).
    /// @dev = 0x811553cc20c92c3707264c87d19f1ed9f2ca671214b9d6a3ecc419c6a7523b5c.
    ///      upgradeHash = keccak256(abi.encode(UPGRADE_HASH_SCHEME_V2, targetContract,
    ///      currentImplementation, newImplementation, version, upgradeType, block.timestamp)).
    bytes32 public constant UPGRADE_HASH_SCHEME_V2 = keccak256("TruthBounty.UpgradeController.upgradeHash.v2");

    /// @notice Version tag of the upgrade proposal-id scheme (V2-SC-160).
    /// @dev = 0x22015412ba7af32cf094b083b6dc19f23039090bf7813354d4d610afddfc54e4.
    ///      proposalId = keccak256(abi.encode(UPGRADE_PROPOSAL_ID_SCHEME_V2, targetContract,
    ///      newImplementation, version, proposer, block.timestamp)).
    ///      This contract is not upgradeable, so proposals created by an earlier deployment under
    ///      the retired V1 packed scheme keep their ids there. A V2 preimage (32-byte tag first)
    ///      can never equal a V1 preimage (ASCII "UPGRADE" first), so a V2 id never aliases a V1 id.
    bytes32 public constant UPGRADE_PROPOSAL_ID_SCHEME_V2 = keccak256("TruthBounty.UpgradeController.proposalId.v2");

    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant DEFAULT_STANDARD_DELAY = 1 days;
    uint256 public constant DEFAULT_EMERGENCY_DELAY = 24 hours;
    uint256 public constant DEFAULT_EXECUTION_WINDOW = 7 days;
    uint256 public constant MAX_EMERGENCY_DELAY = 3 days;

    IVersionRegistry public versionRegistry;
    StorageCompatibilityValidator public storageValidator;

    uint256 public emergencyDelay = DEFAULT_EMERGENCY_DELAY;
    uint256 public executionWindow = DEFAULT_EXECUTION_WINDOW;
    uint256 public standardDelay = DEFAULT_STANDARD_DELAY;

    mapping(bytes32 => UpgradeProposal) internal _proposals;
    mapping(address => bytes32[]) internal _upgradeHistory;
    mapping(address => bytes32[]) internal _pendingUpgrades;
    mapping(address => address) internal _currentImplementation;

    bytes32[] internal _allProposalIds;
    mapping(bytes32 => bool) internal _proposalExists;

    error ProposalNotFound(bytes32 proposalId);
    error ProposalNotScheduled(bytes32 proposalId);
    error ProposalNotProposed(bytes32 proposalId);
    error ExecutionWindowClosed(bytes32 proposalId);
    error TimelockNotElapsed(bytes32 proposalId);
    error AlreadyExecuted(bytes32 proposalId);
    error AlreadyCancelled(bytes32 proposalId);
    error InvalidImplementation(address impl);
    error InvalidTarget(address target);
    error InvalidVersion(string version);
    error ZeroAddress();
    error UpgradeHashMismatch();
    error RollbackUnsafe(bytes32 proposalId);
    error UnauthorizedEmergency();

    modifier onlyUpgradeRole() {
        if (!hasRole(UPGRADE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedEmergency();
        }
        _;
    }

    modifier onlyEmergencyUpgradeRole() {
        if (!hasRole(EMERGENCY_UPGRADE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedEmergency();
        }
        _;
    }

    constructor(
        address admin,
        address _versionRegistry,
        address _storageValidator
    ) {
        require(admin != address(0), "Zero address");
        require(_versionRegistry != address(0), "Zero address");
        require(_storageValidator != address(0), "Zero address");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADE_ROLE, admin);
        _grantRole(EMERGENCY_UPGRADE_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);

        versionRegistry = IVersionRegistry(_versionRegistry);
        storageValidator = StorageCompatibilityValidator(_storageValidator);
    }

    function proposeUpgrade(
        address targetContract,
        address newImplementation,
        string calldata version,
        UpgradeType upgradeType,
        bytes32 governanceProposalId
    ) external override nonReentrant whenNotPaused returns (bytes32 proposalId) {
        if (targetContract == address(0)) revert InvalidTarget(targetContract);
        if (newImplementation == address(0)) revert InvalidImplementation(newImplementation);
        if (bytes(version).length == 0) revert InvalidVersion(version);

        if (upgradeType == UpgradeType.EMERGENCY) {
            if (!hasRole(EMERGENCY_UPGRADE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedEmergency();
            }
        } else {
            if (!hasRole(UPGRADE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedEmergency();
            }
        }

        address currentImpl = _currentImplementation[targetContract];

        // V2-SC-160: typed, length-delimited, version-tagged commitments. The retired packed
        // forms spliced the caller-chosen `version` string between fixed-width fields, which let
        // other packed schemas (e.g. CanonicalEventLibrary's V1 operation id) reproduce the same
        // preimage. See docs/ENCODE_PACKED_POLICY.md.
        bytes32 upgradeHash = keccak256(abi.encode(
            UPGRADE_HASH_SCHEME_V2,
            targetContract,
            currentImpl,
            newImplementation,
            version,
            upgradeType,
            block.timestamp
        ));

        proposalId = keccak256(abi.encode(
            UPGRADE_PROPOSAL_ID_SCHEME_V2,
            targetContract,
            newImplementation,
            version,
            msg.sender,
            block.timestamp
        ));

        _proposals[proposalId] = UpgradeProposal({
            proposalId: proposalId,
            targetContract: targetContract,
            currentImplementation: currentImpl,
            newImplementation: newImplementation,
            version: version,
            upgradeType: upgradeType,
            status: UpgradeStatus.PROPOSED,
            scheduledAt: 0,
            executeAfter: 0,
            executedAt: 0,
            proposer: msg.sender,
            governanceProposalId: governanceProposalId,
            upgradeHash: upgradeHash
        });

        _proposalExists[proposalId] = true;
        _allProposalIds.push(proposalId);
        _pendingUpgrades[targetContract].push(proposalId);

        emit UpgradeProposed(proposalId, targetContract, newImplementation, version, upgradeType);
    }

    function scheduleUpgrade(bytes32 proposalId) external override nonReentrant whenNotPaused {
        UpgradeProposal storage proposal = _proposals[proposalId];
        if (!_proposalExists[proposalId]) revert ProposalNotFound(proposalId);
        if (proposal.status != UpgradeStatus.PROPOSED) revert ProposalNotProposed(proposalId);

        bool isEmergency = proposal.upgradeType == UpgradeType.EMERGENCY;
        if (isEmergency) {
            if (!hasRole(EMERGENCY_UPGRADE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedEmergency();
            }
        } else {
            if (!hasRole(UPGRADE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedEmergency();
            }
        }

        uint256 delay;
        if (proposal.upgradeType == UpgradeType.EMERGENCY) {
            delay = emergencyDelay;
        } else if (proposal.upgradeType == UpgradeType.ROLLBACK) {
            delay = standardDelay;
        } else {
            delay = standardDelay;
        }

        uint256 executeAfter = block.timestamp + delay;

        proposal.status = UpgradeStatus.SCHEDULED;
        proposal.scheduledAt = block.timestamp;
        proposal.executeAfter = executeAfter;

        emit UpgradeScheduled(proposalId, executeAfter);
    }

    function executeUpgrade(bytes32 proposalId) external override nonReentrant whenNotPaused {
        UpgradeProposal storage proposal = _proposals[proposalId];
        if (!_proposalExists[proposalId]) revert ProposalNotFound(proposalId);
        if (proposal.status == UpgradeStatus.EXECUTED) revert AlreadyExecuted(proposalId);
        if (proposal.status == UpgradeStatus.CANCELLED) revert AlreadyCancelled(proposalId);
        if (proposal.status != UpgradeStatus.SCHEDULED) revert ProposalNotScheduled(proposalId);
        if (block.timestamp < proposal.executeAfter) revert TimelockNotElapsed(proposalId);
        if (block.timestamp > proposal.executeAfter + executionWindow) {
            revert ExecutionWindowClosed(proposalId);
        }

        if (!hasRole(UPGRADE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedEmergency();
        }

        if (address(storageValidator) != address(0)) {
            storageValidator.validateUpgrade(
                proposal.targetContract,
                proposal.currentImplementation,
                proposal.newImplementation
            );
        }

        _currentImplementation[proposal.targetContract] = proposal.newImplementation;

        proposal.status = UpgradeStatus.EXECUTED;
        proposal.executedAt = block.timestamp;

        _upgradeHistory[proposal.targetContract].push(proposalId);

        emit UpgradeExecuted(
            proposalId,
            proposal.targetContract,
            proposal.newImplementation,
            proposal.version
        );
    }

    function cancelUpgrade(bytes32 proposalId) external override nonReentrant {
        UpgradeProposal storage proposal = _proposals[proposalId];
        if (!_proposalExists[proposalId]) revert ProposalNotFound(proposalId);
        if (proposal.status == UpgradeStatus.EXECUTED) revert AlreadyExecuted(proposalId);
        if (proposal.status == UpgradeStatus.CANCELLED) revert AlreadyCancelled(proposalId);

        bool isProposer = proposal.proposer == msg.sender;
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        bool isGovernance = hasRole(GOVERNANCE_ROLE, msg.sender);

        if (!isProposer && !isAdmin && !isGovernance) {
            revert UnauthorizedEmergency();
        }

        proposal.status = UpgradeStatus.CANCELLED;

        emit UpgradeCancelled(proposalId);
    }

    function rollbackUpgrade(bytes32 proposalId) external override nonReentrant whenNotPaused {
        UpgradeProposal storage proposal = _proposals[proposalId];
        if (!_proposalExists[proposalId]) revert ProposalNotFound(proposalId);
        if (proposal.status == UpgradeStatus.ROLLED_BACK) revert AlreadyExecuted(proposalId);
        if (proposal.status != UpgradeStatus.EXECUTED) revert ProposalNotScheduled(proposalId);

        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert UnauthorizedEmergency();
        }

        address previousImplementation = proposal.currentImplementation;
        if (previousImplementation == address(0)) {
            revert RollbackUnsafe(proposalId);
        }

        _currentImplementation[proposal.targetContract] = previousImplementation;

        proposal.status = UpgradeStatus.ROLLED_BACK;
        proposal.executedAt = block.timestamp;

        _upgradeHistory[proposal.targetContract].push(proposalId);

        emit UpgradeRolledBack(proposalId, proposal.targetContract, previousImplementation);
    }

    function setEmergencyDelay(uint256 newDelay) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newDelay >= MIN_DELAY && newDelay <= MAX_EMERGENCY_DELAY, "Invalid delay");
        uint256 oldDelay = emergencyDelay;
        emergencyDelay = newDelay;
        emit EmergencyDelayUpdated(oldDelay, newDelay);
    }

    function setExecutionWindow(uint256 newWindow) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newWindow >= 1 hours, "Window too short");
        require(newWindow <= 30 days, "Window too long");
        uint256 oldWindow = executionWindow;
        executionWindow = newWindow;
        emit ExecutionWindowUpdated(oldWindow, newWindow);
    }

    function setStandardDelay(uint256 newDelay) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newDelay >= MIN_DELAY && newDelay <= MAX_DELAY, "Invalid delay");
        uint256 oldDelay = standardDelay;
        standardDelay = newDelay;
        emit StandardDelayUpdated(oldDelay, newDelay);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============ View Functions ============

    function getProposal(bytes32 proposalId) external view override returns (UpgradeProposal memory) {
        if (!_proposalExists[proposalId]) revert ProposalNotFound(proposalId);
        return _proposals[proposalId];
    }

    function isUpgradeScheduled(bytes32 proposalId) external view override returns (bool) {
        return _proposalExists[proposalId] && _proposals[proposalId].status == UpgradeStatus.SCHEDULED;
    }

    function getUpgradeHistory(address targetContract) external view override returns (bytes32[] memory) {
        return _upgradeHistory[targetContract];
    }

    function getPendingUpgrades(address targetContract) external view override returns (bytes32[] memory) {
        bytes32[] storage pending = _pendingUpgrades[targetContract];
        uint256 count = 0;
        for (uint256 i = 0; i < pending.length; i++) {
            if (_proposals[pending[i]].status == UpgradeStatus.SCHEDULED) {
                count++;
            }
        }
        bytes32[] memory result = new bytes32[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < pending.length; i++) {
            if (_proposals[pending[i]].status == UpgradeStatus.SCHEDULED) {
                result[idx++] = pending[i];
            }
        }
        return result;
    }

    function currentImplementation(address targetContract) external view override returns (address) {
        return _currentImplementation[targetContract];
    }

    function setCurrentImplementation(address targetContract, address impl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _currentImplementation[targetContract] = impl;
    }

    function getAllProposalIds() external view returns (bytes32[] memory) {
        return _allProposalIds;
    }

    function getProposalCount() external view returns (uint256) {
        return _allProposalIds.length;
    }
}

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

    /// @notice Reinitializer version tag for the migration manifest scheme (V2-SC-077).
    /// @dev = keccak256("TruthBounty.UpgradeController.migrationManifest.v2").
    bytes32 public constant MIGRATION_MANIFEST_SCHEME_V2 = keccak256("TruthBounty.UpgradeController.migrationManifest.v2");

    /// @notice A single ordered migration step bound to a target contract.
    struct MigrationStep {
        bytes32 stepId;
        address targetContract;
        uint256 reinitializerVersion;
        bytes32 prerequisiteStepId;
        bytes32 codeHash;
        bool registered;
        bool completed;
        uint256 completedAt;
    }

    /// @notice Per-target migration manifest recording completed reinitializer versions.
    struct MigrationManifest {
        uint256 lastCompletedVersion;
        uint256 completedCount;
        bytes32 lastCompletedStepId;
        bool initialized;
    }

    mapping(bytes32 => MigrationStep) internal _migrationSteps;
    mapping(address => MigrationManifest) internal _migrationManifests;
    mapping(address => mapping(uint256 => bytes32)) internal _versionToStepId;
    mapping(address => bytes32[]) internal _migrationOrder;

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
    error MigrationStepAlreadyRegistered(bytes32 stepId);
    error MigrationStepNotFound(bytes32 stepId);
    error MigrationStepAlreadyCompleted(bytes32 stepId);
    error MigrationPrerequisiteNotMet(bytes32 stepId, bytes32 prerequisiteStepId);
    error MigrationVersionOutOfOrder(address targetContract, uint256 expected, uint256 provided);
    error MigrationVersionAlreadyCompleted(address targetContract, uint256 version);
    error MigrationCodeHashMismatch(bytes32 stepId, bytes32 expected, bytes32 actual);
    error MigrationTargetMismatch(bytes32 stepId, address expected, address provided);

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

    event MigrationStepRegistered(
        bytes32 indexed stepId,
        address indexed targetContract,
        uint256 reinitializerVersion,
        bytes32 prerequisiteStepId,
        bytes32 codeHash
    );
    event MigrationStepCompleted(bytes32 indexed stepId, address indexed targetContract, uint256 reinitializerVersion, uint256 completedAt);
    event MigrationManifestUpdated(address indexed targetContract, uint256 lastCompletedVersion, uint256 completedCount, bytes32 lastCompletedStepId);

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

    // ============ Reinitializer / Migration Ordering (V2-SC-077) ============

    /**
     * @notice Register an ordered migration step for a target contract.
     * @dev Prerequisites are machine-verifiable: the prerequisite step must be registered and
     *      completed before this step can execute. Versions must be strictly increasing per target.
     */
    function registerMigrationStep(
        address targetContract,
        uint256 reinitializerVersion,
        bytes32 prerequisiteStepId,
        bytes32 codeHash
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes32 stepId) {
        if (targetContract == address(0)) revert InvalidTarget(targetContract);
        if (reinitializerVersion == 0) revert InvalidVersion("reinitializerVersion");
        if (codeHash == bytes32(0)) revert InvalidImplementation(address(0));

        stepId = keccak256(abi.encode(MIGRATION_MANIFEST_SCHEME_V2, targetContract, reinitializerVersion, codeHash));
        if (_migrationSteps[stepId].registered) revert MigrationStepAlreadyRegistered(stepId);

        MigrationManifest storage manifest = _migrationManifests[targetContract];
        if (reinitializerVersion <= manifest.lastCompletedVersion) {
            revert MigrationVersionAlreadyCompleted(targetContract, reinitializerVersion);
        }
        if (_versionToStepId[targetContract][reinitializerVersion] != bytes32(0)) {
            revert MigrationVersionAlreadyCompleted(targetContract, reinitializerVersion);
        }

        if (prerequisiteStepId != bytes32(0)) {
            MigrationStep storage prereq = _migrationSteps[prerequisiteStepId];
            if (!prereq.registered) revert MigrationStepNotFound(prerequisiteStepId);
            if (prereq.targetContract != targetContract) {
                revert MigrationTargetMismatch(prerequisiteStepId, prereq.targetContract, targetContract);
            }
        }

        _migrationSteps[stepId] = MigrationStep({
            stepId: stepId,
            targetContract: targetContract,
            reinitializerVersion: reinitializerVersion,
            prerequisiteStepId: prerequisiteStepId,
            codeHash: codeHash,
            registered: true,
            completed: false,
            completedAt: 0
        });
        _versionToStepId[targetContract][reinitializerVersion] = stepId;
        _migrationOrder[targetContract].push(stepId);

        emit MigrationStepRegistered(stepId, targetContract, reinitializerVersion, prerequisiteStepId, codeHash);
    }

    /**
     * @notice Execute a registered migration step atomically.
     * @dev Enforces: step registered, not already completed, prerequisite completed, version
     *      strictly greater than last completed version, and code hash matches the live target.
     *      On any revert, no manifest state is mutated (atomicity).
     */
    function executeMigrationStep(bytes32 stepId) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        MigrationStep storage step = _migrationSteps[stepId];
        if (!step.registered) revert MigrationStepNotFound(stepId);
        if (step.completed) revert MigrationStepAlreadyCompleted(stepId);

        if (step.prerequisiteStepId != bytes32(0)) {
            MigrationStep storage prereq = _migrationSteps[step.prerequisiteStepId];
            if (!prereq.completed) {
                revert MigrationPrerequisiteNotMet(stepId, step.prerequisiteStepId);
            }
        }

        MigrationManifest storage manifest = _migrationManifests[step.targetContract];
        uint256 expectedVersion = manifest.lastCompletedVersion + 1;
        if (step.reinitializerVersion != expectedVersion) {
            revert MigrationVersionOutOfOrder(step.targetContract, expectedVersion, step.reinitializerVersion);
        }

        bytes32 actualCodeHash = step.targetContract.codehash;
        if (actualCodeHash != step.codeHash) {
            revert MigrationCodeHashMismatch(stepId, step.codeHash, actualCodeHash);
        }

        step.completed = true;
        step.completedAt = block.timestamp;

        manifest.lastCompletedVersion = step.reinitializerVersion;
        manifest.completedCount += 1;
        manifest.lastCompletedStepId = stepId;
        manifest.initialized = true;

        emit MigrationStepCompleted(stepId, step.targetContract, step.reinitializerVersion, block.timestamp);
        emit MigrationManifestUpdated(step.targetContract, manifest.lastCompletedVersion, manifest.completedCount, stepId);
    }

    /**
     * @notice Resume a partially-completed migration by executing the next pending step.
     * @dev Safe to call after a partial failure: only the next ordered step is eligible.
     */
    function resumeMigration(address targetContract) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused returns (bytes32 stepId) {
        bytes32[] storage order = _migrationOrder[targetContract];
        for (uint256 i = 0; i < order.length; i++) {
            MigrationStep storage step = _migrationSteps[order[i]];
            if (!step.completed) {
                stepId = order[i];
                break;
            }
        }
        if (stepId == bytes32(0)) revert MigrationStepNotFound(bytes32(0));

        MigrationStep storage step = _migrationSteps[stepId];
        if (step.prerequisiteStepId != bytes32(0) && !_migrationSteps[step.prerequisiteStepId].completed) {
            revert MigrationPrerequisiteNotMet(stepId, step.prerequisiteStepId);
        }

        MigrationManifest storage manifest = _migrationManifests[targetContract];
        uint256 expectedVersion = manifest.lastCompletedVersion + 1;
        if (step.reinitializerVersion != expectedVersion) {
            revert MigrationVersionOutOfOrder(targetContract, expectedVersion, step.reinitializerVersion);
        }

        bytes32 actualCodeHash = targetContract.codehash;
        if (actualCodeHash != step.codeHash) {
            revert MigrationCodeHashMismatch(stepId, step.codeHash, actualCodeHash);
        }

        step.completed = true;
        step.completedAt = block.timestamp;
        manifest.lastCompletedVersion = step.reinitializerVersion;
        manifest.completedCount += 1;
        manifest.lastCompletedStepId = stepId;
        manifest.initialized = true;

        emit MigrationStepCompleted(stepId, targetContract, step.reinitializerVersion, block.timestamp);
        emit MigrationManifestUpdated(targetContract, manifest.lastCompletedVersion, manifest.completedCount, stepId);
    }

    function getMigrationStep(bytes32 stepId) external view returns (MigrationStep memory) {
        if (!_migrationSteps[stepId].registered) revert MigrationStepNotFound(stepId);
        return _migrationSteps[stepId];
    }

    function getMigrationManifest(address targetContract) external view returns (MigrationManifest memory) {
        return _migrationManifests[targetContract];
    }

    function getMigrationOrder(address targetContract) external view returns (bytes32[] memory) {
        return _migrationOrder[targetContract];
    }
}

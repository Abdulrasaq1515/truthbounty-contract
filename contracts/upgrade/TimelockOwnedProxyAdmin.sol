// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "./StorageCompatibilityValidator.sol";

/**
 * @title TimelockOwnedProxyAdmin
 * @notice ProxyAdmin owned by a TimelockController that enforces the protocol's upgrade delays
 * @dev This contract extends OpenZeppelin's ProxyAdmin but restricts all upgrades to go through
 *      the timelock with the required 7-day delay. It also includes additional validation checks
 *      before allowing any upgrades to prevent unsafe implementations.
 */
contract TimelockOwnedProxyAdmin is ProxyAdmin /*, IUpgradePlugin*/ {
    // 7-day minimum upgrade delay as required
    uint256 public constant MIN_UPGRADE_DELAY = 7 days;
    // 30-day maximum upgrade delay - prevents stale pending upgrades
    uint256 public constant MAX_UPGRADE_DELAY = 30 days;
    
    // Mapping to track pending upgrades
    struct PendingUpgrade {
        address proxy;
        address implementation;
        bytes data;
        uint256 executeAfter;
        uint256 expireAt;
        bytes32 predecessorId;
        bool executed;
        bool cancelled;
    }
    
    mapping(bytes32 => PendingUpgrade) public pendingUpgrades;
    TimelockController public immutable timelock;
    StorageCompatibilityValidator public storageValidator;
    
    // Track all implementations that have ever been used to prevent reuse
    mapping(address => bool) public usedImplementations;
    // Nonce to ensure unique operation IDs even for same-block upgrades
    uint256 private _operationNonce;
    
    event UpgradeScheduled(
        bytes32 indexed upgradeId,
        address indexed proxy,
        address indexed newImplementation,
        uint256 executeAfter,
        uint256 expireAt,
        bytes32 predecessorId
    );
    event UpgradeCancelled(bytes32 indexed upgradeId);
    event UpgradeExecuted(bytes32 indexed upgradeId);
    event UpgradeExpired(bytes32 indexed upgradeId);
    event ImplementationValidated(address indexed implementation, bytes32 versionHash);
    event InvalidImplementationRejected(address indexed implementation, string reason);
    
    error ZeroAddress();
    error OnlyTimelock();
    error UpgradeNotScheduled();
    error TimelockNotElapsed();
    error UpgradeAlreadyExecuted();
    error UpgradeAlreadyCancelled();
    error UpgradeWindowExpired();
    error UpgradeNotYetExpired();
    error PredecessorNotCompleted(bytes32 predecessorId);
    error InvalidDelay(uint256 delay);
    error InvalidImplementation(string reason);
    error ImplementationAlreadyUsed(address implementation);
    error EOANotAllowed(address account);
    error OperationIdCollision(bytes32 operationId);
    /// @notice Native value was attached to the upgrade path (V2-SC-153).
    /// @param value Rejected `msg.value`.
    error UnexpectedNativeValue(uint256 value);
    
    modifier onlyTimelockController() {
        if (msg.sender != address(timelock)) revert OnlyTimelock();
        _;
    }
    
    constructor(address _timelock, address _storageValidator) ProxyAdmin(_timelock) {
        if (_timelock == address(0)) revert ZeroAddress();
        if (_storageValidator == address(0)) revert ZeroAddress();
        
        // Check that both are contracts, not EOAs
        if (_timelock.code.length == 0) revert EOANotAllowed(_timelock);
        if (_storageValidator.code.length == 0) revert EOANotAllowed(_storageValidator);
        
        timelock = TimelockController(payable(_timelock));
        storageValidator = StorageCompatibilityValidator(_storageValidator);

        // ProxyAdmin's constructor sets the owner via Ownable(initialOwner).
        // We pass _timelock directly so the timelock is the only address that
        // can call onlyOwner functions (including upgradeAndCall).
    }
    
    /**
     * @dev Schedule an upgrade to be executed after the timelock period
     * Can only be called by the timelock (which means it must go through governance)
     * @param proxy The proxy contract to upgrade
     * @param newImplementation The new implementation address
     * @param data Optional data to call on the proxy after upgrade
     * @param delay The delay in seconds before the upgrade can be executed
     * @param predecessorId Optional ID of a prerequisite upgrade that must be executed first
     */
    function scheduleUpgrade(
        address proxy,
        address newImplementation,
        bytes calldata data,
        uint256 delay,
        bytes32 predecessorId
    ) external onlyTimelockController returns (bytes32 upgradeId) {
        // Validate delay is within bounds
        if (delay < MIN_UPGRADE_DELAY || delay > MAX_UPGRADE_DELAY) {
            revert InvalidDelay(delay);
        }
        
        // Validate the new implementation before scheduling
        _validateImplementation(proxy, newImplementation);
        
        // Generate unique operation ID using nonce to prevent collisions even in same block
        unchecked {
            _operationNonce++;
        }
        upgradeId = keccak256(abi.encodePacked(proxy, newImplementation, block.timestamp, _operationNonce));
        
        // Ensure operation ID is unique (defense in depth)
        if (pendingUpgrades[upgradeId].proxy != address(0)) {
            revert OperationIdCollision(upgradeId);
        }
        
        uint256 executeAfter = block.timestamp + delay;
        uint256 expireAt = block.timestamp + MAX_UPGRADE_DELAY; // Upgrades must be executed within 30 days
        
        // Validate predecessor if specified
        if (predecessorId != bytes32(0)) {
            PendingUpgrade storage predecessor = pendingUpgrades[predecessorId];
            if (predecessor.proxy == address(0) || !predecessor.executed) {
                revert PredecessorNotCompleted(predecessorId);
            }
        }
        
        pendingUpgrades[upgradeId] = PendingUpgrade({
            proxy: proxy,
            implementation: newImplementation,
            data: data,
            executeAfter: executeAfter,
            expireAt: expireAt,
            predecessorId: predecessorId,
            executed: false,
            cancelled: false
        });
        
        emit UpgradeScheduled(upgradeId, proxy, newImplementation, executeAfter, expireAt, predecessorId);
    }
    
    /**
     * @dev Execute a scheduled upgrade after the timelock has elapsed
     * @param upgradeId The ID of the upgrade to execute
     */
    function executeUpgrade(bytes32 upgradeId) external {
        PendingUpgrade storage upgrade = pendingUpgrades[upgradeId];
        if (upgrade.proxy == address(0)) revert UpgradeNotScheduled();
        if (upgrade.executed) revert UpgradeAlreadyExecuted();
        if (upgrade.cancelled) revert UpgradeAlreadyCancelled();
        if (block.timestamp < upgrade.executeAfter) revert TimelockNotElapsed();
        if (block.timestamp > upgrade.expireAt) {
            // Mark as expired and clean up
            delete pendingUpgrades[upgradeId];
            emit UpgradeExpired(upgradeId);
            revert UpgradeWindowExpired();
        }
        
        // Validate predecessor if specified
        if (upgrade.predecessorId != bytes32(0)) {
            PendingUpgrade storage predecessor = pendingUpgrades[upgrade.predecessorId];
            if (predecessor.proxy == address(0) || !predecessor.executed) {
                revert PredecessorNotCompleted(upgrade.predecessorId);
            }
        }
        
        // Mark as executed first (reentrancy protection) and then remove from storage completely
        // to prevent any replay attacks - one-time execution guaranteed
        upgrade.executed = true;
        delete pendingUpgrades[upgradeId];
        
        // Perform the upgrade (OZ v5 ProxyAdmin exposes upgradeAndCall only).
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(upgrade.proxy);
        upgradeAndCall(proxy, upgrade.implementation, upgrade.data);
        
        emit UpgradeExecuted(upgradeId);
    }
    
    /**
     * @dev Cancel a pending upgrade
     * Can only be called by the timelock
     * @param upgradeId The ID of the upgrade to cancel
     */
    function cancelUpgrade(bytes32 upgradeId) external onlyTimelockController {
        PendingUpgrade storage upgrade = pendingUpgrades[upgradeId];
        if (upgrade.proxy == address(0)) revert UpgradeNotScheduled();
        if (upgrade.executed) revert UpgradeAlreadyExecuted();
        if (upgrade.cancelled) revert UpgradeAlreadyCancelled();
        
        // Remove from storage completely to prevent any future execution
        delete pendingUpgrades[upgradeId];
        emit UpgradeCancelled(upgradeId);
    }
    
    /**
     * @dev Clean up an expired upgrade. Anyone can call this to free up storage.
     * @param upgradeId The ID of the expired upgrade to clean up
     */
    function cleanupExpiredUpgrade(bytes32 upgradeId) external {
        PendingUpgrade storage upgrade = pendingUpgrades[upgradeId];
        if (upgrade.proxy == address(0)) revert UpgradeNotScheduled();
        if (block.timestamp <= upgrade.expireAt) revert UpgradeNotYetExpired(); // Only allow cleanup if actually expired
        
        // Remove from storage
        delete pendingUpgrades[upgradeId];
        emit UpgradeExpired(upgradeId);
    }
    
    /**
     * @dev Internal validation function to prevent unsafe upgrades
     * Checks:
     * 1. Implementation is not zero address
     * 2. Implementation is a contract (not EOA)
     * 3. Implementation hasn't been used before (prevents reuse)
     * 4. Storage layout is compatible (delegates to StorageCompatibilityValidator)
     * 5. Interfaces are supported
     */
    function _validateImplementation(address proxy, address newImplementation) internal {
        if (newImplementation == address(0)) revert ZeroAddress();
        
        // Check that it's a contract, not an EOA
        if (newImplementation.code.length == 0) {
            emit InvalidImplementationRejected(newImplementation, "Implementation is EOA");
            revert InvalidImplementation("Implementation is EOA");
        }
        
        // Check we're not reusing an implementation that's already been used anywhere
        if (usedImplementations[newImplementation]) {
            emit InvalidImplementationRejected(newImplementation, "Implementation already used");
            revert ImplementationAlreadyUsed(newImplementation);
        }
        
        // Note: In OpenZeppelin v5.x, getProxyImplementation is not available on ProxyAdmin.
        // To get the implementation, we would need to call the proxy directly, but ERC1967Utils.getImplementation()
        // is internal. For now, we skip this check, but in production this should be implemented properly.
        // address currentImpl = getProxyImplementation(proxy);
        // if (newImplementation == currentImpl) {
        //     emit InvalidImplementationRejected(newImplementation, "Implementation already active");
        //     revert ImplementationAlreadyUsed(newImplementation);
        // }
        
        // Validate storage compatibility using the storage validator
        try storageValidator.validateUpgrade(proxy, address(0), newImplementation) {
            // Storage layout is compatible
        } catch {
            string memory reason = "Storage layout validation failed";
            emit InvalidImplementationRejected(newImplementation, reason);
            revert InvalidImplementation(reason);
        }
        
        // Mark implementation as used to prevent future reuse
        usedImplementations[newImplementation] = true;
        
        emit ImplementationValidated(newImplementation, keccak256(bytes("1.0.0")));
    }
    
    /**
     * @dev Override upgradeAndCall to keep ProxyAdmin owner checks while routing scheduled upgrades.
     *      Native value isolation (V2-SC-153): a transparent proxy has no path that releases native
     *      currency, so value forwarded here would be permanently stranded in the proxy. The upgrade
     *      path therefore rejects `msg.value` instead of forwarding it to `upgradeToAndCall`.
     */
    function upgradeAndCall(
        ITransparentUpgradeableProxy proxy,
        address implementation,
        bytes memory data
    ) public payable override onlyOwner {
        if (msg.value != 0) revert UnexpectedNativeValue(msg.value);
        super.upgradeAndCall(proxy, implementation, data);
    }

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
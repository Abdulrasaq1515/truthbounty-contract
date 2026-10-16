// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ICreate2AddressPlanner
 * @notice Plans collision-safe deterministic CREATE2 addresses for V2 modules/implementations
 *         and gates registration on reviewed salts plus bytecode verification.
 */
interface ICreate2AddressPlanner {
    /// @notice Full plan record for a module key.
    struct Plan {
        bytes32 moduleId;
        bytes32 reviewedSalt;
        bytes32 derivedSalt;
        bytes32 initCodeHash;
        bytes32 runtimeCodeHash;
        address deployer;
        address predicted;
        bool reserved;
        bool bytecodeVerified;
        bool deploymentConfirmed;
    }

    /// @notice Emitted when a module address is reserved via CREATE2 planning.
    event AddressPlanned(
        bytes32 indexed moduleId,
        address indexed predicted,
        address indexed deployer,
        bytes32 derivedSalt,
        bytes32 initCodeHash
    );

    /// @notice Emitted when planned runtime bytecode is verified against the expected hash.
    event BytecodeVerified(bytes32 indexed moduleId, address indexed predicted, bytes32 runtimeCodeHash);

    /// @notice Emitted when on-chain code at the predicted address matches the verified hash.
    event DeploymentConfirmed(bytes32 indexed moduleId, address indexed predicted);

    /// @notice Emitted when a reserved plan is cleared by an admin.
    event PlanCleared(bytes32 indexed moduleId, address indexed predicted);

    error ZeroModuleId();
    error ZeroSalt();
    error ZeroInitCodeHash();
    error ZeroDeployer();
    error ZeroAddress();
    error PlanAlreadyExists(bytes32 moduleId);
    error PlanNotFound(bytes32 moduleId);
    error SaltAlreadyUsed(bytes32 derivedSalt);
    error AddressCollision(address predicted, bytes32 existingModuleId);
    error TargetAlreadyHasCode(address predicted);
    error BytecodeHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice Runtime bytecode exceeds the EIP-170 maximum code size.
    error RuntimeBytecodeTooLarge(uint256 actual, uint256 maximum);
    error BytecodeNotVerified(bytes32 moduleId);
    error DeploymentCodeMissing(address predicted);
    error NotReadyForRegistration(bytes32 moduleId);

    /**
     * @notice Pure CREATE2 address prediction.
     * @param deployer CREATE2 factory / deployer address.
     * @param salt Domain-separated salt.
     * @param initCodeHash keccak256 of creation (init) bytecode.
     */
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        external
        pure
        returns (address predicted);

    /**
     * @notice Domain-separates a reviewed salt with the module id for collision safety.
     */
    function deriveSalt(bytes32 moduleId, bytes32 reviewedSalt) external pure returns (bytes32);

    /**
     * @notice Reserves a deterministic address for `moduleId` from a reviewed salt.
     * @dev Reverts on zero inputs, salt reuse, address collision, or existing code at target.
     */
    function planAddress(
        bytes32 moduleId,
        bytes32 reviewedSalt,
        bytes32 initCodeHash,
        address deployer
    ) external returns (address predicted);

    /**
     * @notice Verifies runtime bytecode against the hash recorded (or set) for the plan.
     * @dev Accepts at most 24,576 bytes, the EIP-170 runtime-code limit.
     * @dev If the plan has no runtime hash yet, the provided bytecode hash becomes the expected hash.
     *      If an expected hash is already set, the bytecode must match it.
     */
    function verifyBytecode(bytes32 moduleId, bytes calldata runtimeBytecode) external;

    /**
     * @notice Sets the expected runtime code hash before bytecode is supplied.
     */
    function setExpectedRuntimeCodeHash(bytes32 moduleId, bytes32 runtimeCodeHash) external;

    /**
     * @notice Confirms that code at the predicted address matches the verified runtime hash.
     */
    function confirmDeployment(bytes32 moduleId) external returns (bool);

    /**
     * @notice Returns true only when the plan is reserved, bytecode-verified, and deployment-confirmed.
     */
    function isReadyForRegistration(bytes32 moduleId) external view returns (bool);

    /**
     * @notice Returns the plan for `moduleId` (empty / zeroed if unset).
     */
    function getPlan(bytes32 moduleId) external view returns (Plan memory);

    /**
     * @notice Clears a plan. Admin only. Fails closed if ready-for-registration unless forced via role.
     */
    function clearPlan(bytes32 moduleId) external;
}

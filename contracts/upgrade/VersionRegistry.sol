// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IVersionRegistry.sol";

/**
 * @title VersionRegistry
 * @notice Canonical registry for protocol contract version history
 * @dev Maintains an immutable record of every deployed version with metadata
 *      including implementation addresses, deployment timestamps, governance
 *      proposal IDs, and upgrade hashes for full audit trail
 */
contract VersionRegistry is IVersionRegistry, AccessControl {
    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");

    struct VersionList {
        VersionEntry[] entries;
        mapping(string => uint256) versionToIndex;
        string[] versionStrings;
        string activeVersion;
    }

    mapping(string => VersionList) internal _versions;
    string[] internal _contractNames;
    mapping(string => bool) internal _contractRegistered;

    error ContractAlreadyRegistered(string contractName);
    error ContractNotRegistered(string contractName);
    error VersionNotFound(string contractName, string version);
    error ZeroAddress();
    error EmptyString();

    event ContractRegistered(string indexed contractName);

    constructor(address admin) {
        require(admin != address(0), "Zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRY_ROLE, admin);
    }

    function registerVersion(
        string calldata contractName,
        address implementation,
        address proxy,
        string calldata semanticVersion,
        bytes32 governanceProposalId,
        bytes32 upgradeHash
    ) external override onlyRole(REGISTRY_ROLE) returns (uint256 index) {
        if (implementation == address(0)) revert ZeroAddress();
        if (bytes(contractName).length == 0) revert EmptyString();
        if (bytes(semanticVersion).length == 0) revert EmptyString();

        if (!_contractRegistered[contractName]) {
            _contractNames.push(contractName);
            _contractRegistered[contractName] = true;
            emit ContractRegistered(contractName);
        }

        VersionList storage versionList = _versions[contractName];

        index = versionList.entries.length;

        versionList.entries.push(VersionEntry({
            contractName: contractName,
            implementation: implementation,
            proxy: proxy,
            semanticVersion: semanticVersion,
            deployedAt: block.timestamp,
            governanceProposalId: governanceProposalId,
            upgradeHash: upgradeHash,
            status: VersionStatus.ACTIVE
        }));

        versionList.versionToIndex[semanticVersion] = index;
        versionList.versionStrings.push(semanticVersion);
        versionList.activeVersion = semanticVersion;

        emit VersionRegistered(contractName, semanticVersion, implementation);
    }

    function updateVersionStatus(
        string calldata contractName,
        string calldata semanticVersion,
        VersionStatus newStatus
    ) external override onlyRole(REGISTRY_ROLE) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);

        VersionList storage versionList = _versions[contractName];
        uint256 idx;
        bool found = false;

        for (uint256 i = 0; i < versionList.versionStrings.length; i++) {
            if (_strEq(versionList.versionStrings[i], semanticVersion)) {
                idx = i;
                found = true;
                break;
            }
        }

        if (!found) revert VersionNotFound(contractName, semanticVersion);

        versionList.entries[idx].status = newStatus;

        if (newStatus == VersionStatus.ACTIVE) {
            versionList.activeVersion = semanticVersion;
        }

        emit VersionStatusUpdated(contractName, semanticVersion, newStatus);
    }

    function getLatestVersion(string calldata contractName) external view override returns (VersionEntry memory) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        VersionList storage versionList = _versions[contractName];
        require(versionList.entries.length > 0, "No versions");
        return versionList.entries[versionList.entries.length - 1];
    }

    function getVersion(string memory contractName, string memory semanticVersion)
        public view override returns (VersionEntry memory)
    {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        VersionList storage versionList = _versions[contractName];
        uint256 idx;
        bool found = false;
        for (uint256 i = 0; i < versionList.versionStrings.length; i++) {
            if (_strEq(versionList.versionStrings[i], semanticVersion)) {
                idx = i;
                found = true;
                break;
            }
        }
        if (!found) revert VersionNotFound(contractName, semanticVersion);
        return versionList.entries[idx];
    }

    function getVersionAtIndex(string calldata contractName, uint256 index)
        external view override returns (VersionEntry memory)
    {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        return _versions[contractName].entries[index];
    }

    function getVersionCount(string calldata contractName) external view override returns (uint256) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        return _versions[contractName].entries.length;
    }

    function getActiveVersion(string calldata contractName) external view override returns (VersionEntry memory) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        VersionList storage versionList = _versions[contractName];
        if (bytes(versionList.activeVersion).length == 0) revert VersionNotFound(contractName, "");
        return getVersion(contractName, versionList.activeVersion);
    }

    function isVersionActive(string calldata contractName, string calldata semanticVersion)
        external view override returns (bool)
    {
        if (!_contractRegistered[contractName]) return false;
        VersionList storage versionList = _versions[contractName];
        if (bytes(versionList.activeVersion).length == 0) return false;
        return _strEq(versionList.activeVersion, semanticVersion);
    }

    function getContractNames() external view returns (string[] memory) {
        return _contractNames;
    }

    function isContractRegistered(string calldata contractName) external view returns (bool) {
        return _contractRegistered[contractName];
    }

    /// @dev V2-SC-160: hashes the raw string bytes directly (byte-identical to the former
    ///      single-argument packed form) so no packed encoding remains in the upgrade surface.
    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

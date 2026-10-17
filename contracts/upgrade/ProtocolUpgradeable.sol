// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../governance/GovernanceOwnable.sol";
import "../governance/GovernanceHooks.sol";
import "./IUpgradeController.sol";

/**
 * @title ProtocolUpgradeable
 * @notice Abstract base for upgradeable TruthBounty protocol contracts
 * @dev Integrates with UpgradeController for governance-controlled upgrades.
 *      Follows the same UUPS proxy pattern as TruthBountyToken.
 *      All protocol upgrades must go through the UpgradeController.
 */
abstract contract ProtocolUpgradeable is
    Initializable,
    UUPSUpgradeable,
    GovernanceOwnable
{
    bytes32 public constant UPGRADE_CONTROLLER_ROLE = keccak256("UPGRADE_CONTROLLER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    IUpgradeController public upgradeController;

    event UpgradeControllerUpdated(address indexed oldController, address indexed newController);
    event ContractUpgraded(address indexed oldImpl, address indexed newImpl, string version);

    error UpgradeNotAuthorized();

    function _initializeProtocolUpgradeable(
        address _admin,
        address _upgradeController,
        address _governanceController
    ) internal onlyInitializing {
        require(_admin != address(0), ZeroAddress());


        if (_upgradeController != address(0)) {
            upgradeController = IUpgradeController(_upgradeController);
        }

        _initializeGovernance(_governanceController, _admin, _admin);
    }

    function setUpgradeController(address _newController)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        address oldController = address(upgradeController);

        if (oldController != address(0)) {
            if (hasRole(UPGRADE_CONTROLLER_ROLE, oldController)) {
                _revokeRole(UPGRADE_CONTROLLER_ROLE, oldController);
            }
        }

        upgradeController = IUpgradeController(_newController);

        if (_newController != address(0)) {
            _grantRole(UPGRADE_CONTROLLER_ROLE, _newController);
        }

        emit UpgradeControllerUpdated(oldController, _newController);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!hasRole(UPGRADE_CONTROLLER_ROLE, msg.sender)) {
            revert UpgradeNotAuthorized();
        }
    }

    uint256[46] private __gap;
}
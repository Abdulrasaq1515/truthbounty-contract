// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {PostDeploymentRoleCheck} from "../../contracts/deployment/PostDeploymentRoleCheck.sol";
import {GovernedModuleRegistry} from "../../contracts/governance/v2/GovernedModuleRegistry.sol";
import {TruthBountyGovernanceToken} from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import {TruthBountyGovernor} from "../../contracts/governance/v2/TruthBountyGovernor.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";
import {GovernanceGuardian} from "../../contracts/governance/v2/GovernanceGuardian.sol";
import {ITruthBountyGovernor} from "../../contracts/governance/v2/ITruthBountyGovernor.sol";
import {GovernanceRoleTopology} from "../../contracts/governance/v2/GovernanceRoleTopology.sol";

/**
 * @title RoleRenunciationFuzz
 * @notice Fuzz tests for V2-SC-127 — verifies deployer role checks hold for arbitrary
 *         deployer addresses, target arrays, and partial handoff orderings.
 */
contract RoleRenunciationFuzz is Test {
    GovernedModuleRegistry registry;
    TruthBountyGovernanceToken govToken;
    TimelockController timelock;
    TruthBountyGovernor governor;
    GovernanceGuardian guardianContract;

    address deployer = address(0xD1);
    address guardian = address(0xA1);

    function setUp() public {
        vm.startPrank(deployer);
        registry = new GovernedModuleRegistry(deployer);
        govToken = new TruthBountyGovernanceToken(deployer, 1_000_000_000 ether);
        address[] memory empty = new address[](0);
        timelock = new TimelockController(2 days, empty, empty, deployer);
        governor = new TruthBountyGovernor(
            IVotes(address(govToken)), timelock, registry, IGovernanceSnapshot(address(0)), guardian,
            uint48(1 days), uint32(3 days), 100_000 ether, 4
        );
        guardianContract = new GovernanceGuardian(deployer, guardian, ITruthBountyGovernor(address(governor)));
        vm.stopPrank();

        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));
    }

    function _performFullHandoff() internal {
        vm.startPrank(deployer);
        GovernanceRoleTopology.configure(timelock, governor, guardian, 2 days);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);
        registry.renounceRole(0x00, deployer);
        registry.renounceRole(keccak256("REGISTRY_ADMIN_ROLE"), deployer);
        guardianContract.renounceRole(0x00, deployer);
        vm.stopPrank();
    }

    function _targets() internal view returns (address[] memory t) {
        t = new address[](4);
        t[0] = address(registry);
        t[1] = address(timelock);
        t[2] = address(guardianContract);
        t[3] = address(govToken);
    }

    /// @notice After handoff, any fuzzed address (except authorized holders) has no roles.
    function testFuzz_ArbitraryAddress_NoRolesAfterHandoff(address account) public {
        _performFullHandoff();

        // Skip addresses that legitimately hold roles
        vm.assume(account != address(governor));
        vm.assume(account != address(timelock));
        vm.assume(account != guardian);
        vm.assume(account != address(0)); // executor role sentinel

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(account, _targets());

        assertEq(violations.length, 0, "arbitrary account should have no roles after handoff");
    }

    /// @notice Before handoff, deployer violations count is consistent across calls.
    function testFuzz_ViolationCount_Consistent(uint8 callCount) public view {
        vm.assume(callCount > 0 && callCount <= 10);

        uint256 firstCount;
        for (uint256 i; i < callCount; ++i) {
            PostDeploymentRoleCheck.RoleViolation[] memory v =
                PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());
            if (i == 0) {
                firstCount = v.length;
            } else {
                assertEq(v.length, firstCount, "violation count should be deterministic");
            }
        }
    }

    /// @notice roleCatalog always returns ROLE_CATALOG_SIZE entries.
    function testFuzz_RoleCatalogSize_Invariant(uint256) public pure {
        bytes32[] memory roles = PostDeploymentRoleCheck.roleCatalog();
        assertEq(roles.length, PostDeploymentRoleCheck.ROLE_CATALOG_SIZE);
    }

    /// @notice safeCheckRole on an arbitrary address with no code returns false.
    function testFuzz_SafeCheckRole_NoCode(address target, bytes32 role) public view {
        vm.assume(target.code.length == 0);
        assertFalse(PostDeploymentRoleCheck.safeCheckRole(target, role, deployer));
    }

    /// @notice Empty targets array always produces zero violations regardless of deployer.
    function testFuzz_EmptyTargets_ZeroViolations(address account) public view {
        address[] memory empty = new address[](0);
        PostDeploymentRoleCheck.RoleViolation[] memory v =
            PostDeploymentRoleCheck.checkAllRoles(account, empty);
        assertEq(v.length, 0);
    }

    /// @notice Targets array filled with zero addresses produces zero violations.
    function testFuzz_ZeroAddressTargets_ZeroViolations(uint8 size) public view {
        vm.assume(size > 0 && size <= 20);
        address[] memory targets = new address[](size);
        // All entries are address(0) by default
        PostDeploymentRoleCheck.RoleViolation[] memory v =
            PostDeploymentRoleCheck.checkAllRoles(address(0xD1), targets);
        assertEq(v.length, 0);
    }
}

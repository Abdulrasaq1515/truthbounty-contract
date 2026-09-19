import { expect } from "chai";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";

describe("ProtocolUpgradeManager", function () {
  const MODULE_BOUNTY = ethers.id("TRUTH_BOUNTY");
  const MODULE_STAKING = ethers.id("STAKING");

  const V1 = { major: 1n, minor: 0n, patch: 0n };
  const V1_0_1 = { major: 1n, minor: 0n, patch: 1n };
  const V1_1_0 = { major: 1n, minor: 1n, patch: 0n };
  const V2 = { major: 2n, minor: 0n, patch: 0n };

  const STORAGE_HASH_V1 = ethers.id("layout-v1");
  const STORAGE_HASH_V2 = ethers.id("layout-v2");
  const MIGRATION_HASH = ethers.id("migration-1->2");
  const ZERO_HASH = ethers.ZeroHash;

  // Deploy a fresh contract to use as a stand-in "implementation" address (needs code).
  async function deployImpl(name = "Impl", symbol = "IMP") {
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const impl = await MockERC20.deploy(name, symbol);
    await impl.waitForDeployment();
    return impl;
  }

  async function deployFixture() {
    const [admin, proposer, validator, upgrader, executor, guardian, user] =
      await ethers.getSigners();

    const Manager = await ethers.getContractFactory("ProtocolUpgradeManager");
    const manager = await Manager.deploy(admin.address, ethers.ZeroAddress);
    await manager.waitForDeployment();

    await manager.grantRole(await manager.PROPOSER_ROLE(), proposer.address);
    await manager.grantRole(await manager.VALIDATOR_ROLE(), validator.address);
    await manager.grantRole(await manager.UPGRADER_ROLE(), upgrader.address);
    await manager.grantRole(await manager.EXECUTOR_ROLE(), executor.address);
    await manager.grantRole(await manager.GUARDIAN_ROLE(), guardian.address);

    const implV1 = await deployImpl("V1", "V1");
    const implV2 = await deployImpl("V2", "V2");

    return {
      admin,
      proposer,
      validator,
      upgrader,
      executor,
      guardian,
      user,
      manager,
      implV1,
      implV2,
    };
  }

  // Registers MODULE_BOUNTY at V1 => implV1.
  async function withRegisteredModule() {
    const ctx = await loadFixture(deployFixture);
    await ctx.manager
      .connect(ctx.admin)
      .registerModule(MODULE_BOUNTY, await ctx.implV1.getAddress(), V1, STORAGE_HASH_V1);
    return ctx;
  }

  // Drives a proposal all the way to Approved (compatible minor bump, no migration).
  async function withApprovedUpgrade() {
    const ctx = await withRegisteredModule();
    const { manager, proposer, validator, upgrader, implV2 } = ctx;

    await manager
      .connect(proposer)
      .proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V1_1_0, STORAGE_HASH_V2, ZERO_HASH, "minor");
    await manager.connect(validator).attestStorageCompatibility(1, true);
    await manager.connect(upgrader).approveUpgrade(1);

    return { ...ctx, proposalId: 1n };
  }

  describe("Deployment", function () {
    it("grants all operational roles to the initial admin", async function () {
      const { manager, admin } = await loadFixture(deployFixture);
      expect(await manager.hasRole(await manager.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
      expect(await manager.hasRole(await manager.ADMIN_ROLE(), admin.address)).to.be.true;
      expect(await manager.hasRole(await manager.PROPOSER_ROLE(), admin.address)).to.be.true;
      expect(await manager.hasRole(await manager.VALIDATOR_ROLE(), admin.address)).to.be.true;
      expect(await manager.hasRole(await manager.UPGRADER_ROLE(), admin.address)).to.be.true;
      expect(await manager.hasRole(await manager.EXECUTOR_ROLE(), admin.address)).to.be.true;
      expect(await manager.hasRole(await manager.GUARDIAN_ROLE(), admin.address)).to.be.true;
      expect(await manager.hasRole(await manager.PAUSER_ROLE(), admin.address)).to.be.true;
    });

    it("uses a 7 day default timelock", async function () {
      const { manager } = await loadFixture(deployFixture);
      expect(await manager.upgradeTimelock()).to.equal(7n * 24n * 60n * 60n);
    });

    it("starts with no registered modules or proposals", async function () {
      const { manager } = await loadFixture(deployFixture);
      expect(await manager.getRegisteredModuleCount()).to.equal(0n);
      expect(await manager.getProposalCount()).to.equal(0n);
    });
  });

  describe("Module registration", function () {
    it("registers a module and sets baseline state", async function () {
      const { manager, admin, implV1 } = await loadFixture(deployFixture);
      const addr = await implV1.getAddress();

      await expect(manager.connect(admin).registerModule(MODULE_BOUNTY, addr, V1, STORAGE_HASH_V1))
        .to.emit(manager, "ModuleRegistered")
        .withArgs(MODULE_BOUNTY, addr, 1n, 0n, 0n, STORAGE_HASH_V1);

      const state = await manager.getModuleState(MODULE_BOUNTY);
      expect(state.registered).to.be.true;
      expect(state.currentImplementation).to.equal(addr);
      expect(state.currentVersion.major).to.equal(1n);
      expect(state.storageLayoutHash).to.equal(STORAGE_HASH_V1);
      expect(state.previousImplementation).to.equal(ethers.ZeroAddress);

      expect(await manager.versionString(MODULE_BOUNTY)).to.equal("1.0.0");
      expect(await manager.latestAuthorized(MODULE_BOUNTY)).to.equal(addr);
      expect(await manager.getRegisteredModuleCount()).to.equal(1n);
    });

    it("reverts on zero implementation address", async function () {
      const { manager, admin } = await loadFixture(deployFixture);
      await expect(
        manager.connect(admin).registerModule(MODULE_BOUNTY, ethers.ZeroAddress, V1, STORAGE_HASH_V1)
      ).to.be.revertedWithCustomError(manager, "InvalidAddress");
    });

    it("reverts when implementation has no code", async function () {
      const { manager, admin, user } = await loadFixture(deployFixture);
      await expect(
        manager.connect(admin).registerModule(MODULE_BOUNTY, user.address, V1, STORAGE_HASH_V1)
      ).to.be.revertedWithCustomError(manager, "NoContractCode");
    });

    it("reverts on duplicate registration", async function () {
      const { manager, admin, implV1 } = await withRegisteredModule();
      await expect(
        manager.connect(admin).registerModule(MODULE_BOUNTY, await implV1.getAddress(), V1, STORAGE_HASH_V1)
      ).to.be.revertedWithCustomError(manager, "ModuleAlreadyRegistered");
    });

    it("reverts when caller lacks ADMIN_ROLE", async function () {
      const { manager, user, implV1 } = await loadFixture(deployFixture);
      await expect(
        manager.connect(user).registerModule(MODULE_BOUNTY, await implV1.getAddress(), V1, STORAGE_HASH_V1)
      ).to.be.revertedWithCustomError(manager, "AccessControlUnauthorizedAccount");
    });
  });

  describe("proposeUpgrade", function () {
    it("creates a proposal with expected fields", async function () {
      const { manager, proposer, implV2 } = await withRegisteredModule();
      const addr = await implV2.getAddress();

      await expect(
        manager.connect(proposer).proposeUpgrade(MODULE_BOUNTY, addr, V1_1_0, STORAGE_HASH_V2, ZERO_HASH, "minor bump")
      )
        .to.emit(manager, "UpgradeProposed")
        .withArgs(1n, MODULE_BOUNTY, addr, 1n, 1n, 0n, ZERO_HASH, proposer.address);

      const p = await manager.getUpgradeProposal(1);
      expect(p.moduleId).to.equal(MODULE_BOUNTY);
      expect(p.newImplementation).to.equal(addr);
      expect(p.fromVersion.major).to.equal(1n);
      expect(p.toVersion.minor).to.equal(1n);
      expect(p.status).to.equal(1n); // Proposed
      expect(await manager.getProposalCount()).to.equal(1n);
    });

    it("reverts for an unregistered module", async function () {
      const { manager, proposer, implV2 } = await withRegisteredModule();
      await expect(
        manager.connect(proposer).proposeUpgrade(MODULE_STAKING, await implV2.getAddress(), V2, STORAGE_HASH_V2, ZERO_HASH, "x")
      ).to.be.revertedWithCustomError(manager, "ModuleNotRegistered");
    });

    it("enforces strictly monotonic versions", async function () {
      const { manager, proposer, implV2 } = await withRegisteredModule();
      await expect(
        manager.connect(proposer).proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V1, STORAGE_HASH_V2, ZERO_HASH, "same")
      ).to.be.revertedWithCustomError(manager, "VersionNotNewer");
    });

    it("rejects reusing the current implementation", async function () {
      const { manager, proposer, implV1 } = await withRegisteredModule();
      await expect(
        manager.connect(proposer).proposeUpgrade(MODULE_BOUNTY, await implV1.getAddress(), V2, STORAGE_HASH_V2, ZERO_HASH, "same impl")
      ).to.be.revertedWithCustomError(manager, "SameImplementation");
    });

    it("rejects an implementation with no code", async function () {
      const { manager, proposer, user } = await withRegisteredModule();
      await expect(
        manager.connect(proposer).proposeUpgrade(MODULE_BOUNTY, user.address, V2, STORAGE_HASH_V2, ZERO_HASH, "eoa")
      ).to.be.revertedWithCustomError(manager, "NoContractCode");
    });

    it("reverts when caller lacks PROPOSER_ROLE", async function () {
      const { manager, user, implV2 } = await withRegisteredModule();
      await expect(
        manager.connect(user).proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V2, STORAGE_HASH_V2, ZERO_HASH, "x")
      ).to.be.revertedWithCustomError(manager, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Storage compatibility & migration policy", function () {
    it("blocks a minor/patch upgrade that is attested incompatible", async function () {
      const { manager, proposer, validator, upgrader, implV2 } = await withRegisteredModule();
      await manager
        .connect(proposer)
        .proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V1_0_1, STORAGE_HASH_V2, ZERO_HASH, "patch");

      await expect(manager.connect(validator).attestStorageCompatibility(1, false))
        .to.emit(manager, "StorageCompatibilityAttested")
        .withArgs(1n, MODULE_BOUNTY, false, validator.address);

      await expect(manager.connect(upgrader).approveUpgrade(1)).to.be.revertedWithCustomError(
        manager,
        "StorageIncompatible"
      );
    });

    it("requires attestation before approval", async function () {
      const { manager, proposer, upgrader, implV2 } = await withRegisteredModule();
      await manager
        .connect(proposer)
        .proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V1_1_0, STORAGE_HASH_V2, ZERO_HASH, "minor");
      await expect(manager.connect(upgrader).approveUpgrade(1)).to.be.revertedWithCustomError(
        manager,
        "StorageNotAttested"
      );
    });

    it("requires a migration for a storage-incompatible major upgrade", async function () {
      const { manager, proposer, validator, upgrader, implV2 } = await withRegisteredModule();
      // Major bump, no migration hash, attested incompatible.
      await manager
        .connect(proposer)
        .proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V2, STORAGE_HASH_V2, ZERO_HASH, "major no migration");
      await manager.connect(validator).attestStorageCompatibility(1, false);

      await expect(manager.connect(upgrader).approveUpgrade(1)).to.be.revertedWithCustomError(
        manager,
        "MigrationRequired"
      );
    });

    it("validates a migration hash and gates approval on it", async function () {
      const { manager, proposer, validator, upgrader, implV2 } = await withRegisteredModule();
      await manager
        .connect(proposer)
        .proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V2, STORAGE_HASH_V2, MIGRATION_HASH, "major");
      await manager.connect(validator).attestStorageCompatibility(1, false);

      // Not yet validated => approval blocked.
      await expect(manager.connect(upgrader).approveUpgrade(1)).to.be.revertedWithCustomError(
        manager,
        "MigrationNotValidated"
      );

      // Wrong hash rejected.
      await expect(
        manager.connect(validator).validateMigration(1, ethers.id("wrong"))
      ).to.be.revertedWithCustomError(manager, "MigrationHashMismatch");

      await expect(manager.connect(validator).validateMigration(1, MIGRATION_HASH))
        .to.emit(manager, "MigrationValidated")
        .withArgs(1n, MODULE_BOUNTY, MIGRATION_HASH, validator.address);

      await expect(manager.connect(upgrader).approveUpgrade(1)).to.emit(manager, "UpgradeApproved");
    });

    it("only VALIDATOR can attest / validate", async function () {
      const { manager, proposer, user, implV2 } = await withRegisteredModule();
      await manager
        .connect(proposer)
        .proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V2, STORAGE_HASH_V2, ZERO_HASH, "x");
      await expect(
        manager.connect(user).attestStorageCompatibility(1, true)
      ).to.be.revertedWithCustomError(manager, "AccessControlUnauthorizedAccount");
    });
  });

  describe("approveUpgrade / executeUpgrade", function () {
    it("sets executeAfter to now + timelock on approval", async function () {
      const { manager, proposalId } = await withApprovedUpgrade();
      const p = await manager.getUpgradeProposal(proposalId);
      expect(p.status).to.equal(2n); // Approved
      const now = BigInt(await time.latest());
      expect(p.executeAfter).to.be.closeTo(now + (await manager.upgradeTimelock()), 5n);
    });

    it("blocks execution before the timelock elapses", async function () {
      const { manager, executor, proposalId } = await withApprovedUpgrade();
      await expect(manager.connect(executor).executeUpgrade(proposalId)).to.be.revertedWithCustomError(
        manager,
        "TimelockNotPassed"
      );
    });

    it("executes after the timelock and updates module state", async function () {
      const { manager, executor, implV1, implV2, proposalId } = await withApprovedUpgrade();
      await time.increase(7 * 24 * 60 * 60 + 1);

      const oldAddr = await implV1.getAddress();
      const newAddr = await implV2.getAddress();

      await expect(manager.connect(executor).executeUpgrade(proposalId))
        .to.emit(manager, "UpgradeExecuted")
        .withArgs(proposalId, MODULE_BOUNTY, oldAddr, newAddr, executor.address);

      const state = await manager.getModuleState(MODULE_BOUNTY);
      expect(state.currentImplementation).to.equal(newAddr);
      expect(state.currentVersion.minor).to.equal(1n);
      expect(state.storageLayoutHash).to.equal(STORAGE_HASH_V2);
      expect(state.previousImplementation).to.equal(oldAddr);
      expect(state.upgradeCount).to.equal(1n);

      expect(await manager.versionString(MODULE_BOUNTY)).to.equal("1.1.0");
      expect(await manager.isUpgradeAuthorized(MODULE_BOUNTY, newAddr)).to.be.true;
      expect(await manager.isUpgradeAuthorized(MODULE_BOUNTY, oldAddr)).to.be.false;

      const history = await manager.getModuleUpgradeHistory(MODULE_BOUNTY);
      expect(history.length).to.equal(1);
      expect(history[0]).to.equal(proposalId);
    });

    it("cannot execute a non-approved proposal", async function () {
      const { manager, executor } = await withRegisteredModule();
      await expect(manager.connect(executor).executeUpgrade(1)).to.be.revertedWithCustomError(
        manager,
        "ProposalNotFound"
      );
    });

    it("only EXECUTOR can execute", async function () {
      const { manager, user, proposalId } = await withApprovedUpgrade();
      await time.increase(7 * 24 * 60 * 60 + 1);
      await expect(manager.connect(user).executeUpgrade(proposalId)).to.be.revertedWithCustomError(
        manager,
        "AccessControlUnauthorizedAccount"
      );
    });
  });

  describe("cancelUpgrade", function () {
    it("lets the proposer cancel a pending proposal", async function () {
      const { manager, proposer, implV2 } = await withRegisteredModule();
      await manager
        .connect(proposer)
        .proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V2, STORAGE_HASH_V2, ZERO_HASH, "x");

      await expect(manager.connect(proposer).cancelUpgrade(1))
        .to.emit(manager, "UpgradeCancelled")
        .withArgs(1n, MODULE_BOUNTY, proposer.address);

      const p = await manager.getUpgradeProposal(1);
      expect(p.status).to.equal(4n); // Cancelled
    });

    it("lets a guardian veto an approved proposal", async function () {
      const { manager, guardian, proposalId } = await withApprovedUpgrade();
      await expect(manager.connect(guardian).cancelUpgrade(proposalId)).to.emit(manager, "UpgradeCancelled");
    });

    it("blocks an unauthorized caller from cancelling", async function () {
      const { manager, user, proposalId } = await withApprovedUpgrade();
      await expect(manager.connect(user).cancelUpgrade(proposalId)).to.be.revertedWithCustomError(
        manager,
        "NotAuthorizedToCancel"
      );
    });

    it("cannot cancel an executed proposal", async function () {
      const { manager, executor, guardian, proposalId } = await withApprovedUpgrade();
      await time.increase(7 * 24 * 60 * 60 + 1);
      await manager.connect(executor).executeUpgrade(proposalId);
      await expect(manager.connect(guardian).cancelUpgrade(proposalId)).to.be.revertedWithCustomError(
        manager,
        "InvalidProposalStatus"
      );
    });
  });

  describe("rollbackUpgrade", function () {
    it("restores the previous implementation and re-points authorization", async function () {
      const { manager, executor, guardian, implV1, implV2, proposalId } = await withApprovedUpgrade();
      await time.increase(7 * 24 * 60 * 60 + 1);
      await manager.connect(executor).executeUpgrade(proposalId);

      const oldAddr = await implV1.getAddress();
      const newAddr = await implV2.getAddress();

      await expect(manager.connect(guardian).rollbackUpgrade(MODULE_BOUNTY, "incident"))
        .to.emit(manager, "UpgradeRolledBack")
        .withArgs(MODULE_BOUNTY, newAddr, oldAddr, "incident", guardian.address);

      const state = await manager.getModuleState(MODULE_BOUNTY);
      expect(state.currentImplementation).to.equal(oldAddr);
      expect(state.currentVersion.minor).to.equal(0n);
      expect(await manager.isUpgradeAuthorized(MODULE_BOUNTY, oldAddr)).to.be.true;
      // Rollback is reversible: the demoted impl becomes the new previous.
      expect(state.previousImplementation).to.equal(newAddr);
    });

    it("reverts when there is no previous implementation", async function () {
      const { manager, guardian } = await withRegisteredModule();
      await expect(manager.connect(guardian).rollbackUpgrade(MODULE_BOUNTY, "x")).to.be.revertedWithCustomError(
        manager,
        "NoPreviousImplementation"
      );
    });

    it("blocks an unauthorized caller from rolling back", async function () {
      const { manager, user, executor, proposalId } = await withApprovedUpgrade();
      await time.increase(7 * 24 * 60 * 60 + 1);
      await manager.connect(executor).executeUpgrade(proposalId);
      await expect(manager.connect(user).rollbackUpgrade(MODULE_BOUNTY, "x")).to.be.revertedWithCustomError(
        manager,
        "NotAuthorizedToRollback"
      );
    });
  });

  describe("Pausing", function () {
    it("blocks execution while paused but allows rollback", async function () {
      const { manager, admin, executor, guardian, proposalId } = await withApprovedUpgrade();
      await time.increase(7 * 24 * 60 * 60 + 1);

      await manager.connect(admin).pause();
      await expect(manager.connect(executor).executeUpgrade(proposalId)).to.be.revertedWithCustomError(
        manager,
        "EnforcedPause"
      );

      await manager.connect(admin).unpause();
      await manager.connect(executor).executeUpgrade(proposalId);

      // Rollback remains available even during a pause (asset-protection path).
      await manager.connect(admin).pause();
      await expect(manager.connect(guardian).rollbackUpgrade(MODULE_BOUNTY, "incident")).to.emit(
        manager,
        "UpgradeRolledBack"
      );
    });

    it("only PAUSER can pause", async function () {
      const { manager, user } = await loadFixture(deployFixture);
      await expect(manager.connect(user).pause()).to.be.revertedWithCustomError(
        manager,
        "AccessControlUnauthorizedAccount"
      );
    });
  });

  describe("setUpgradeTimelock", function () {
    it("updates the timelock within bounds", async function () {
      const { manager, admin } = await loadFixture(deployFixture);
      await expect(manager.connect(admin).setUpgradeTimelock(8 * 24 * 60 * 60))
        .to.emit(manager, "UpgradeTimelockUpdated")
        .withArgs(7n * 24n * 60n * 60n, 8n * 24n * 60n * 60n);
      expect(await manager.upgradeTimelock()).to.equal(8n * 24n * 60n * 60n);
    });

    it("rejects out-of-bounds timelocks", async function () {
      const { manager, admin } = await loadFixture(deployFixture);
      await expect(manager.connect(admin).setUpgradeTimelock(60)).to.be.revertedWithCustomError(
        manager,
        "InvalidTimelock"
      );
      await expect(
        manager.connect(admin).setUpgradeTimelock(31 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(manager, "InvalidTimelock");
    });
  });

  describe("Version helpers", function () {
    it("orders versions across all components", async function () {
      const { manager, proposer, validator, upgrader, executor, implV1, implV2 } =
        await withRegisteredModule();

      // 1.0.0 -> 1.0.1 (patch) is newer.
      await manager
        .connect(proposer)
        .proposeUpgrade(MODULE_BOUNTY, await implV2.getAddress(), V1_0_1, STORAGE_HASH_V2, ZERO_HASH, "patch");
      await manager.connect(validator).attestStorageCompatibility(1, true);
      await manager.connect(upgrader).approveUpgrade(1);
      await time.increase(7 * 24 * 60 * 60 + 1);
      await manager.connect(executor).executeUpgrade(1);
      expect(await manager.versionString(MODULE_BOUNTY)).to.equal("1.0.1");

      // Now proposing 1.0.1 again must fail (not newer).
      await expect(
        manager
          .connect(proposer)
          .proposeUpgrade(MODULE_BOUNTY, await implV1.getAddress(), V1_0_1, STORAGE_HASH_V1, ZERO_HASH, "same")
      ).to.be.revertedWithCustomError(manager, "VersionNotNewer");
    });
  });
});

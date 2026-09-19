import { expect } from "chai";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";
import type {
  VerificationRoundManager,
} from "../typechain-types";

// ---------------------------------------------------------------------------
// Test suite: VerificationRoundManager (V2-SC-011)
// ---------------------------------------------------------------------------

describe("VerificationRoundManager", function () {
  // ─── Constants ────────────────────────────────────────────────────────────
  const ROUND_TYPE_FIRST  = 0;
  const ROUND_TYPE_APPEAL = 1;
  const ROUND_STATE_OPEN   = 0;
  const ROUND_STATE_CLOSED = 1;

  const MIN_STAKE  = ethers.parseEther("10");
  const MAX_STAKE  = ethers.parseEther("1000");
  const WEIGHT_CAP = ethers.parseEther("100");
  const THRESHOLD  = 6_000; // 60 % in BPS
  const PARAM_VER  = 1;

  const CLAIM_ID_1 = 1n;
  const CLAIM_ID_2 = 2n;

  // ─── Helpers ──────────────────────────────────────────────────────────────

  async function futureDeadline(offsetSeconds = 7 * 24 * 3600) {
    const now = await time.latest();
    return now + offsetSeconds;
  }

  // ─── Fixture ──────────────────────────────────────────────────────────────

  async function deployFixture() {
    const [admin, manager, other, verifier1, verifier2] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("VerificationRoundManager");
    const vrm = (await Factory.deploy(admin.address)) as VerificationRoundManager;
    await vrm.waitForDeployment();

    // Grant ROUND_MANAGER_ROLE to the `manager` account
    const ROUND_MANAGER_ROLE = await vrm.ROUND_MANAGER_ROLE();
    await vrm.connect(admin).grantRole(ROUND_MANAGER_ROLE, manager.address);

    return {
      vrm,
      admin,
      manager,
      other,
      verifier1,
      verifier2,
      ROUND_MANAGER_ROLE,
    };
  }

  // ─── Helper: open a first round ──────────────────────────────────────────

  async function openFirstRound(
    vrm: VerificationRoundManager,
    manager: Awaited<ReturnType<typeof ethers.getSigner>>,
    claimId = CLAIM_ID_1,
    offsetSeconds = 7 * 24 * 3600
  ) {
    const deadline = await futureDeadline(offsetSeconds);
    const tx = await vrm
      .connect(manager)
      .openRound(
        claimId,
        ROUND_TYPE_FIRST,
        deadline,
        MIN_STAKE,
        MAX_STAKE,
        WEIGHT_CAP,
        THRESHOLD,
        PARAM_VER
      );
    const receipt = await tx.wait();
    return { deadline, receipt };
  }

  // =========================================================================
  // Deployment
  // =========================================================================

  describe("Deployment", function () {
    it("grants DEFAULT_ADMIN_ROLE and ROUND_MANAGER_ROLE to admin", async function () {
      const { vrm, admin } = await loadFixture(deployFixture);
      const DEFAULT_ADMIN_ROLE = await vrm.DEFAULT_ADMIN_ROLE();
      const ROUND_MANAGER_ROLE  = await vrm.ROUND_MANAGER_ROLE();

      expect(await vrm.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
      expect(await vrm.hasRole(ROUND_MANAGER_ROLE,  admin.address)).to.be.true;
    });

    it("starts with totalRounds = 0", async function () {
      const { vrm } = await loadFixture(deployFixture);
      expect(await vrm.totalRounds()).to.equal(0n);
    });

    it("reverts if admin is zero address", async function () {
      const Factory = await ethers.getContractFactory("VerificationRoundManager");
      await expect(Factory.deploy(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        await Factory.deploy(ethers.Wallet.createRandom().address),
        "ZeroAddress"
      );
    });
  });

  // =========================================================================
  // openRound — first-round creation
  // =========================================================================

  describe("openRound — FIRST round", function () {
    it("creates a FIRST round, returns roundId = 1, emits RoundOpened", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const deadline = await futureDeadline();

      await expect(
        vrm
          .connect(manager)
          .openRound(
            CLAIM_ID_1,
            ROUND_TYPE_FIRST,
            deadline,
            MIN_STAKE,
            MAX_STAKE,
            WEIGHT_CAP,
            THRESHOLD,
            PARAM_VER
          )
      )
        .to.emit(vrm, "RoundOpened")
        .withArgs(
          CLAIM_ID_1,
          1n,
          ROUND_TYPE_FIRST,
          (v: bigint) => v > 0n,    // startedAt
          BigInt(deadline),
          MIN_STAKE,
          MAX_STAKE,
          WEIGHT_CAP,
          THRESHOLD,
          PARAM_VER
        );

      expect(await vrm.totalRounds()).to.equal(1n);
    });

    it("stores an immutable parameter snapshot after opening", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const deadline = await futureDeadline();

      await vrm
        .connect(manager)
        .openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, deadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER);

      const params = await vrm.getRound(1n);

      expect(params.claimId).to.equal(CLAIM_ID_1);
      expect(params.roundType).to.equal(ROUND_TYPE_FIRST);
      expect(params.state).to.equal(ROUND_STATE_OPEN);
      expect(params.deadline).to.equal(BigInt(deadline));
      expect(params.minStake).to.equal(MIN_STAKE);
      expect(params.maxStake).to.equal(MAX_STAKE);
      expect(params.weightCap).to.equal(WEIGHT_CAP);
      expect(params.passingThreshold).to.equal(THRESHOLD);
      expect(params.paramVersion).to.equal(PARAM_VER);
    });

    it("getActiveRound returns the open round id", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      const activeId = await vrm.getActiveRound(CLAIM_ID_1, ROUND_TYPE_FIRST);
      expect(activeId).to.equal(1n);
    });

    it("monotonically increments round IDs across claims", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager, CLAIM_ID_1);
      await openFirstRound(vrm, manager, CLAIM_ID_2);

      expect(await vrm.totalRounds()).to.equal(2n);
      const params1 = await vrm.getRound(1n);
      const params2 = await vrm.getRound(2n);
      expect(params1.claimId).to.equal(CLAIM_ID_1);
      expect(params2.claimId).to.equal(CLAIM_ID_2);
    });

    it("reverts if deadline is not in the future", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const now = await time.latest();

      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, now, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.be.revertedWithCustomError(vrm, "DeadlineMustBeFuture");
    });

    it("reverts if minStake > maxStake", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const deadline = await futureDeadline();

      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, deadline, MAX_STAKE + 1n, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.be.revertedWithCustomError(vrm, "InvalidStakeBounds");
    });

    it("reverts if passingThreshold exceeds 10 000", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const deadline = await futureDeadline();

      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, deadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, 10_001, PARAM_VER)
      ).to.be.revertedWithCustomError(vrm, "InvalidThreshold");
    });

    it("reverts if caller lacks ROUND_MANAGER_ROLE", async function () {
      const { vrm, other } = await loadFixture(deployFixture);
      const deadline = await futureDeadline();

      await expect(
        vrm.connect(other).openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, deadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.be.reverted;
    });
  });

  // =========================================================================
  // openRound — appeal-round creation
  // =========================================================================

  describe("openRound — APPEAL round", function () {
    it("creates an APPEAL round after the FIRST round is closed", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      // Close first round
      await time.increaseTo(deadline + 1);
      await vrm.closeRound(1n);

      // Open appeal
      const appealDeadline = await futureDeadline();
      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_APPEAL, appealDeadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      )
        .to.emit(vrm, "RoundOpened")
        .withArgs(
          CLAIM_ID_1,
          2n,
          ROUND_TYPE_APPEAL,
          (v: bigint) => v > 0n,
          BigInt(appealDeadline),
          MIN_STAKE,
          MAX_STAKE,
          WEIGHT_CAP,
          THRESHOLD,
          PARAM_VER
        );

      const params = await vrm.getRound(2n);
      expect(params.roundType).to.equal(ROUND_TYPE_APPEAL);
      expect(params.state).to.equal(ROUND_STATE_OPEN);
    });

    it("reverts if FIRST round is not yet closed", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager); // FIRST round is open

      const appealDeadline = await futureDeadline();
      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_APPEAL, appealDeadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.be.revertedWithCustomError(vrm, "FirstRoundNotClosed");
    });

    it("reverts if FIRST round was never opened (claim has no history)", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const deadline = await futureDeadline();

      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_APPEAL, deadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.be.revertedWithCustomError(vrm, "FirstRoundNotClosed");
    });
  });

  // =========================================================================
  // closeRound
  // =========================================================================

  describe("closeRound", function () {
    it("closes a round after deadline, emits RoundClosed", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(deadline + 1);

      await expect(vrm.closeRound(1n))
        .to.emit(vrm, "RoundClosed")
        .withArgs(CLAIM_ID_1, 1n, (v: bigint) => v > 0n, 0n);
    });

    it("round state becomes CLOSED after closeRound", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(deadline + 1);
      await vrm.closeRound(1n);

      expect(await vrm.getRoundState(1n)).to.equal(ROUND_STATE_CLOSED);
    });

    it("clears the active-round pointer after closing", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(deadline + 1);
      await vrm.closeRound(1n);

      expect(await vrm.getActiveRound(CLAIM_ID_1, ROUND_TYPE_FIRST)).to.equal(0n);
    });

    it("includes participant count in RoundClosed event", async function () {
      const { vrm, manager, verifier1, verifier2 } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE);
      await vrm.connect(manager).recordParticipant(1n, verifier2.address, MIN_STAKE);

      await time.increaseTo(deadline + 1);

      await expect(vrm.closeRound(1n))
        .to.emit(vrm, "RoundClosed")
        .withArgs(CLAIM_ID_1, 1n, (v: bigint) => v > 0n, 2n);
    });

    it("reverts if deadline has not passed", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      await expect(vrm.closeRound(1n)).to.be.revertedWithCustomError(vrm, "DeadlineNotReached");
    });

    it("reverts if round is already closed", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(deadline + 1);
      await vrm.closeRound(1n);

      await expect(vrm.closeRound(1n)).to.be.revertedWithCustomError(vrm, "RoundAlreadyClosed");
    });

    it("reverts if round does not exist", async function () {
      const { vrm } = await loadFixture(deployFixture);
      await expect(vrm.closeRound(999n)).to.be.revertedWithCustomError(vrm, "RoundNotFound");
    });

    it("exact-deadline: reverts at deadline, succeeds at deadline + 1", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      // At the deadline timestamp itself — should still revert (block.timestamp <= deadline).
      // Use setNextBlockTimestamp so the closeRound transaction mines at exactly `deadline`.
      await time.setNextBlockTimestamp(deadline);
      await expect(vrm.closeRound(1n)).to.be.revertedWithCustomError(vrm, "DeadlineNotReached");

      // One second past the deadline — should succeed.
      await time.setNextBlockTimestamp(deadline + 1);
      await expect(vrm.closeRound(1n)).to.emit(vrm, "RoundClosed");
    });

    it("is permissionless — anyone can close after deadline", async function () {
      const { vrm, manager, other } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(deadline + 1);
      await expect(vrm.connect(other).closeRound(1n)).to.emit(vrm, "RoundClosed");
    });
  });

  // =========================================================================
  // recordParticipant
  // =========================================================================

  describe("recordParticipant", function () {
    it("records a participant and is retrievable", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      await vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE);

      expect(await vrm.hasParticipated(1n, verifier1.address)).to.be.true;
      expect(await vrm.getParticipantCount(1n)).to.equal(1n);

      const records = await vrm.getParticipants(1n, 0, 10);
      expect(records.length).to.equal(1);
      expect(records[0].participant).to.equal(verifier1.address);
      expect(records[0].stake).to.equal(MIN_STAKE);
    });

    it("reverts on duplicate participant in the same round", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      await vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE);

      await expect(
        vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE)
      ).to.be.revertedWithCustomError(vrm, "AlreadyParticipated");
    });

    it("reverts if stake is below minStake", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      await expect(
        vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE - 1n)
      ).to.be.revertedWithCustomError(vrm, "InsufficientStake");
    });

    it("reverts if stake exceeds maxStake", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      await expect(
        vrm.connect(manager).recordParticipant(1n, verifier1.address, MAX_STAKE + 1n)
      ).to.be.revertedWithCustomError(vrm, "ExceedsMaxStake");
    });

    it("reverts if round is closed", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(deadline + 1);
      await vrm.closeRound(1n);

      await expect(
        vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE)
      ).to.be.revertedWithCustomError(vrm, "RoundClosed_Submissions");
    });

    it("reverts if round does not exist", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await expect(
        vrm.connect(manager).recordParticipant(999n, verifier1.address, MIN_STAKE)
      ).to.be.revertedWithCustomError(vrm, "RoundNotFound");
    });

    it("allows maxStake exactly", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      await expect(
        vrm.connect(manager).recordParticipant(1n, verifier1.address, MAX_STAKE)
      ).not.to.be.reverted;
    });

    it("allows minStake exactly", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      await expect(
        vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE)
      ).not.to.be.reverted;
    });
  });

  // =========================================================================
  // Overlapping-round prevention
  // =========================================================================

  describe("Overlap prevention", function () {
    it("reverts if a second FIRST round is opened before the first is closed", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager, CLAIM_ID_1);

      const deadline = await futureDeadline();
      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, deadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.be.revertedWithCustomError(vrm, "OverlappingActiveRound");
    });

    it("reverts if a second APPEAL round is opened before the first APPEAL is closed", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline: firstDeadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(firstDeadline + 1);
      await vrm.closeRound(1n);

      // Open first APPEAL
      const appealDeadline = await futureDeadline();
      await vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_APPEAL, appealDeadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER);

      // Attempt second APPEAL while first is still open
      const deadline2 = await futureDeadline(14 * 24 * 3600);
      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_APPEAL, deadline2, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.be.revertedWithCustomError(vrm, "OverlappingActiveRound");
    });

    it("allows a new FIRST round after the previous one is closed", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager, CLAIM_ID_1);

      await time.increaseTo(deadline + 1);
      await vrm.closeRound(1n);

      // Now a new first round on the same claim should succeed
      const deadline2 = await futureDeadline();
      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, deadline2, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.emit(vrm, "RoundOpened");

      expect(await vrm.totalRounds()).to.equal(2n);
    });
  });

  // =========================================================================
  // Pause / unpause
  // =========================================================================

  describe("Pause", function () {
    it("admin can pause and unpause", async function () {
      const { vrm, admin } = await loadFixture(deployFixture);
      await vrm.connect(admin).pause();
      expect(await vrm.paused()).to.be.true;
      await vrm.connect(admin).unpause();
      expect(await vrm.paused()).to.be.false;
    });

    it("non-admin cannot pause", async function () {
      const { vrm, other } = await loadFixture(deployFixture);
      await expect(vrm.connect(other).pause()).to.be.reverted;
    });

    it("openRound reverts when paused", async function () {
      const { vrm, admin, manager } = await loadFixture(deployFixture);
      await vrm.connect(admin).pause();
      const deadline = await futureDeadline();

      await expect(
        vrm.connect(manager).openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, deadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER)
      ).to.be.revertedWithCustomError(vrm, "EnforcedPause");
    });

    it("closeRound reverts when paused", async function () {
      const { vrm, admin, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(deadline + 1);
      await vrm.connect(admin).pause();

      await expect(vrm.closeRound(1n)).to.be.revertedWithCustomError(vrm, "EnforcedPause");
    });

    it("recordParticipant reverts when paused", async function () {
      const { vrm, admin, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      await vrm.connect(admin).pause();

      await expect(
        vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE)
      ).to.be.revertedWithCustomError(vrm, "EnforcedPause");
    });
  });

  // =========================================================================
  // Participant pagination (getParticipants)
  // =========================================================================

  describe("getParticipants — pagination", function () {
    it("paginates participants correctly", async function () {
      const [, manager, , v1, v2] = await ethers.getSigners();
      const Factory = await ethers.getContractFactory("VerificationRoundManager");
      const vrm = (await Factory.deploy((await ethers.getSigners())[0].address)) as VerificationRoundManager;
      await vrm.waitForDeployment();

      const ROUND_MANAGER_ROLE = await vrm.ROUND_MANAGER_ROLE();
      await vrm.grantRole(ROUND_MANAGER_ROLE, manager.address);

      await openFirstRound(vrm, manager);
      await vrm.connect(manager).recordParticipant(1n, v1.address, MIN_STAKE);
      await vrm.connect(manager).recordParticipant(1n, v2.address, MIN_STAKE);

      const page1 = await vrm.getParticipants(1n, 0, 1);
      const page2 = await vrm.getParticipants(1n, 1, 1);
      const all   = await vrm.getParticipants(1n, 0, 0); // limit=0 means all

      expect(page1.length).to.equal(1);
      expect(page1[0].participant).to.equal(v1.address);

      expect(page2.length).to.equal(1);
      expect(page2[0].participant).to.equal(v2.address);

      expect(all.length).to.equal(2);
    });

    it("returns empty array when offset >= participant count", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      const records = await vrm.getParticipants(1n, 10, 5);
      expect(records.length).to.equal(0);
    });

    it("reverts on non-existent roundId", async function () {
      const { vrm } = await loadFixture(deployFixture);
      await expect(vrm.getParticipants(999n, 0, 10)).to.be.revertedWithCustomError(vrm, "RoundNotFound");
    });
  });

  // =========================================================================
  // Regression — snapshot immutability
  // =========================================================================

  describe("Regression — frozen snapshot", function () {
    it("later config changes do NOT affect an open round's parameters", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const deadline = await futureDeadline();

      // Open a round with paramVersion = 1
      await vrm.connect(manager).openRound(
        CLAIM_ID_1, ROUND_TYPE_FIRST, deadline,
        MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD,
        1 /* paramVersion */
      );

      const paramsBefore = await vrm.getRound(1n);

      // Simulate "protocol config update" by opening a new round for a different
      // claim with different parameters (paramVersion = 2)
      const deadline2 = await futureDeadline(14 * 24 * 3600);
      await vrm.connect(manager).openRound(
        CLAIM_ID_2, ROUND_TYPE_FIRST, deadline2,
        MIN_STAKE * 2n, MAX_STAKE * 2n, WEIGHT_CAP, 7_000,
        2 /* paramVersion */
      );

      // Original round's snapshot must be unchanged
      const paramsAfter = await vrm.getRound(1n);

      expect(paramsAfter.minStake).to.equal(paramsBefore.minStake);
      expect(paramsAfter.maxStake).to.equal(paramsBefore.maxStake);
      expect(paramsAfter.passingThreshold).to.equal(paramsBefore.passingThreshold);
      expect(paramsAfter.paramVersion).to.equal(1);
    });

    it("closed round retains its snapshot after closure", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      const paramsBefore = await vrm.getRound(1n);

      await time.increaseTo(deadline + 1);
      await vrm.closeRound(1n);

      const paramsAfter = await vrm.getRound(1n);

      // State changes but parameters are frozen
      expect(paramsAfter.state).to.equal(ROUND_STATE_CLOSED);
      expect(paramsAfter.minStake).to.equal(paramsBefore.minStake);
      expect(paramsAfter.maxStake).to.equal(paramsBefore.maxStake);
      expect(paramsAfter.deadline).to.equal(paramsBefore.deadline);
      expect(paramsAfter.passingThreshold).to.equal(paramsBefore.passingThreshold);
    });
  });

  // =========================================================================
  // View helpers
  // =========================================================================

  describe("View helpers", function () {
    it("getRound reverts for non-existent round", async function () {
      const { vrm } = await loadFixture(deployFixture);
      await expect(vrm.getRound(1n)).to.be.revertedWithCustomError(vrm, "RoundNotFound");
    });

    it("getRoundState reverts for non-existent round", async function () {
      const { vrm } = await loadFixture(deployFixture);
      await expect(vrm.getRoundState(1n)).to.be.revertedWithCustomError(vrm, "RoundNotFound");
    });

    it("getParticipantCount reverts for non-existent round", async function () {
      const { vrm } = await loadFixture(deployFixture);
      await expect(vrm.getParticipantCount(1n)).to.be.revertedWithCustomError(vrm, "RoundNotFound");
    });

    it("getActiveRound returns 0 when no active round", async function () {
      const { vrm } = await loadFixture(deployFixture);
      expect(await vrm.getActiveRound(CLAIM_ID_1, ROUND_TYPE_FIRST)).to.equal(0n);
    });

    it("hasParticipated returns false for unknown address", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);
      expect(await vrm.hasParticipated(1n, verifier1.address)).to.be.false;
    });
  });

  // =========================================================================
  // Gas benchmarks
  // =========================================================================

  describe("Gas benchmarks", function () {
    it("openRound gas usage", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const deadline = await futureDeadline();

      const tx = await vrm
        .connect(manager)
        .openRound(CLAIM_ID_1, ROUND_TYPE_FIRST, deadline, MIN_STAKE, MAX_STAKE, WEIGHT_CAP, THRESHOLD, PARAM_VER);
      const receipt = await tx.wait();

      console.log(`\n  ┌─ Gas Benchmarks ───────────────────────────────────`);
      console.log(`  │  openRound (first):  ${receipt?.gasUsed.toString()} gas`);
      expect(receipt?.gasUsed).to.be.greaterThan(0n);
    });

    it("recordParticipant gas usage (first participant)", async function () {
      const { vrm, manager, verifier1 } = await loadFixture(deployFixture);
      await openFirstRound(vrm, manager);

      const tx = await vrm.connect(manager).recordParticipant(1n, verifier1.address, MIN_STAKE);
      const receipt = await tx.wait();

      console.log(`  │  recordParticipant:  ${receipt?.gasUsed.toString()} gas`);
      expect(receipt?.gasUsed).to.be.greaterThan(0n);
    });

    it("closeRound gas usage (O(1))", async function () {
      const { vrm, manager } = await loadFixture(deployFixture);
      const { deadline } = await openFirstRound(vrm, manager);

      await time.increaseTo(deadline + 1);
      const tx = await vrm.closeRound(1n);
      const receipt = await tx.wait();

      console.log(`  │  closeRound:         ${receipt?.gasUsed.toString()} gas`);
      console.log(`  └────────────────────────────────────────────────────\n`);
      expect(receipt?.gasUsed).to.be.greaterThan(0n);
    });
  });
});

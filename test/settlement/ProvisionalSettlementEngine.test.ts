import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  ClaimRegistry,
  VerificationAggregator,
  ProvisionalSettlementEngine,
  TruthBountyWeighted,
  RewardToken,
  MockReputationOracle,
  GovernanceController,
} from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { deployClaimRegistry } from "../helpers/deployClaimRegistry";

describe("ProvisionalSettlementEngine (SC-015)", () => {
  let admin: SignerWithAddress;
  let claimCreator: SignerWithAddress;
  let verifier1: SignerWithAddress;
  let verifier2: SignerWithAddress;
  let outsider: SignerWithAddress;

  let token: RewardToken;
  let oracle: MockReputationOracle;
  let govController: GovernanceController;
  let truthBounty: TruthBountyWeighted;
  let claimRegistry: ClaimRegistry;
  let aggregator: VerificationAggregator;
  let settlementEngine: ProvisionalSettlementEngine;

  const CHALLENGE_WINDOW = 3 * 24 * 3600; // 3 days
  const VERIFICATION_WINDOW = 24 * 3600; // 1 day
  const MIN_STAKE = ethers.parseEther("100");

  beforeEach(async () => {
    [admin, claimCreator, verifier1, verifier2, outsider] = await ethers.getSigners();

    // 1. Deploy Token
    const TokenFactory = await ethers.getContractFactory("RewardToken");
    token = await TokenFactory.deploy(admin.address, ethers.parseEther("1000000"));
    await token.waitForDeployment();

    // 2. Deploy Mock Reputation Oracle
    const OracleFactory = await ethers.getContractFactory("MockReputationOracle");
    oracle = await OracleFactory.deploy();
    await oracle.waitForDeployment();

    // 3. Deploy Governance Controller
    const GovFactory = await ethers.getContractFactory("GovernanceController");
    govController = await GovFactory.deploy(admin.address);
    await govController.waitForDeployment();

    // 4. Deploy TruthBountyWeighted (Verification source)
    const TBFactory = await ethers.getContractFactory("TruthBountyWeighted");
    truthBounty = await TBFactory.deploy(
      await token.getAddress(),
      await oracle.getAddress(),
      admin.address,
      await govController.getAddress()
    );
    await truthBounty.waitForDeployment();

    // 5. Deploy ClaimRegistry
    claimRegistry = await deployClaimRegistry(admin.address);

    // 6. Deploy VerificationAggregator
    const AggFactory = await ethers.getContractFactory("VerificationAggregator");
    aggregator = await AggFactory.deploy(
      await truthBounty.getAddress(),
      admin.address,
      0, // minCount
      0, // minWeight
      0  // minConfidence
    );
    await aggregator.waitForDeployment();

    // 7. Deploy ProvisionalSettlementEngine
    const EngineFactory = await ethers.getContractFactory("ProvisionalSettlementEngine");
    settlementEngine = await EngineFactory.deploy(
      await claimRegistry.getAddress(),
      await aggregator.getAddress(),
      CHALLENGE_WINDOW,
      await govController.getAddress(),
      admin.address
    );
    await settlementEngine.waitForDeployment();

    // Distribute tokens to verifiers and claim creator
    await token.transfer(verifier1.address, ethers.parseEther("1000"));
    await token.transfer(verifier2.address, ethers.parseEther("1000"));
    await token.connect(verifier1).approve(await truthBounty.getAddress(), ethers.MaxUint256);
    await token.connect(verifier2).approve(await truthBounty.getAddress(), ethers.MaxUint256);

    // Set reputation scores
    await oracle.setReputationScore(verifier1.address, ethers.parseEther("1.0"));
    await oracle.setReputationScore(verifier2.address, ethers.parseEther("1.2"));
  });

  describe("Deployment & Configuration", () => {
    it("initializes immutable references and parameters correctly", async () => {
      expect(await settlementEngine.claimRegistry()).to.equal(await claimRegistry.getAddress());
      expect(await settlementEngine.aggregator()).to.equal(await aggregator.getAddress());
      expect(await settlementEngine.challengeWindowDuration()).to.equal(CHALLENGE_WINDOW);
      expect(await settlementEngine.parameterVersion()).to.equal(1);
    });

    it("rejects zero or invalid constructor parameters", async () => {
      const EngineFactory = await ethers.getContractFactory("ProvisionalSettlementEngine");
      await expect(
        EngineFactory.deploy(
          ethers.ZeroAddress,
          await aggregator.getAddress(),
          CHALLENGE_WINDOW,
          await govController.getAddress(),
          admin.address
        )
      ).to.be.revertedWithCustomError(settlementEngine, "InvalidClaimRegistryAddress");

      await expect(
        EngineFactory.deploy(
          await claimRegistry.getAddress(),
          ethers.ZeroAddress,
          CHALLENGE_WINDOW,
          await govController.getAddress(),
          admin.address
        )
      ).to.be.revertedWithCustomError(settlementEngine, "InvalidAggregatorAddress");

      await expect(
        EngineFactory.deploy(
          await claimRegistry.getAddress(),
          await aggregator.getAddress(),
          10, // below MIN_CHALLENGE_WINDOW (1 hour)
          await govController.getAddress(),
          admin.address
        )
      ).to.be.revertedWithCustomError(settlementEngine, "InvalidChallengeWindowDuration");
    });
  });

  describe("Provisional Settlement Execution", () => {
    let claimId: bigint;
    let deadline: number;

    beforeEach(async () => {
      const now = await time.latest();
      deadline = now + VERIFICATION_WINDOW;
      // Valid base58 CID of 46 chars
      const sampleCID = "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco";

      // Align claim IDs between TruthBountyWeighted (0-indexed) and ClaimRegistry (1-indexed)
      await truthBounty.connect(claimCreator).createClaim("Dummy Content 0");
      await truthBounty.connect(claimCreator).createClaim("Sample Content 1");

      // Create a claim in ClaimRegistry
      await claimRegistry.connect(claimCreator).createClaim(
        "Claim Statement Valid Length 123",
        sampleCID,
        deadline
      );
      claimId = 1n;

      // Staking on TruthBountyWeighted
      await truthBounty.connect(verifier1).stake(MIN_STAKE);
      await truthBounty.connect(verifier2).stake(MIN_STAKE);
    });

    it("reverts if claim ID is zero", async () => {
      await expect(settlementEngine.provisionalSettle(0)).to.be.revertedWithCustomError(
        settlementEngine,
        "ZeroClaimId"
      );
    });

    it("reverts if verification window has not expired", async () => {
      await expect(settlementEngine.provisionalSettle(claimId)).to.be.revertedWithCustomError(
        settlementEngine,
        "VerificationWindowStillOpen"
      );
    });

    it("allows permissionless settlement after deadline and sets VERIFIED_TRUE outcome", async () => {
      // Cast TRUE vote
      await truthBounty.connect(verifier1).vote(claimId, true, MIN_STAKE);

      // Fast forward past verification window
      await time.increase(VERIFICATION_WINDOW + 10);

      // Any outsider can trigger provisional settlement
      const settleTx = await settlementEngine.connect(outsider).provisionalSettle(claimId);
      await expect(settleTx)
        .to.emit(settlementEngine, "RoundAggregated")
        .and.to.emit(settlementEngine, "ProvisionalOutcomeCreated");

      const outcome = await settlementEngine.getProvisionalOutcome(claimId);
      expect(outcome.settled).to.be.true;
      expect(outcome.outcome).to.equal(1); // VERIFIED_TRUE
      expect(outcome.confidence).to.equal(10000); // 100%
      expect(outcome.trueWeight).to.be.gt(0);
      expect(outcome.falseWeight).to.equal(0);
      expect(await settlementEngine.isProvisionalSettled(claimId)).to.be.true;
      expect(await settlementEngine.isChallengeWindowOpen(claimId)).to.be.true;
    });

    it("correctly settles VERIFIED_FALSE outcome", async () => {
      // Cast FALSE vote
      await truthBounty.connect(verifier2).vote(claimId, false, MIN_STAKE);

      // Fast forward past verification window
      await time.increase(VERIFICATION_WINDOW + 10);

      await settlementEngine.provisionalSettle(claimId);

      const outcome = await settlementEngine.getProvisionalOutcome(claimId);
      expect(outcome.outcome).to.equal(2); // VERIFIED_FALSE
      expect(outcome.falseWeight).to.be.gt(0);
    });

    it("correctly settles INCONCLUSIVE outcome on zero votes or tie", async () => {
      // Zero votes cast
      await time.increase(VERIFICATION_WINDOW + 10);

      await settlementEngine.provisionalSettle(claimId);

      const outcome = await settlementEngine.getProvisionalOutcome(claimId);
      expect(outcome.outcome).to.equal(3); // INCONCLUSIVE
      expect(outcome.confidence).to.equal(0);
    });

    it("reverts on duplicate provisional settlement attempts", async () => {
      await time.increase(VERIFICATION_WINDOW + 10);
      await settlementEngine.provisionalSettle(claimId);

      await expect(settlementEngine.provisionalSettle(claimId)).to.be.revertedWithCustomError(
        settlementEngine,
        "AlreadyProvisionallySettled"
      );
    });

    it("correctly closes challenge window after duration expires", async () => {
      await time.increase(VERIFICATION_WINDOW + 10);
      await settlementEngine.provisionalSettle(claimId);

      expect(await settlementEngine.isChallengeWindowOpen(claimId)).to.be.true;

      // Fast forward past challenge window
      await time.increase(CHALLENGE_WINDOW + 10);
      expect(await settlementEngine.isChallengeWindowOpen(claimId)).to.be.false;
    });

    it("reverts when paused", async () => {
      await settlementEngine.pause();
      await time.increase(VERIFICATION_WINDOW + 10);

      await expect(settlementEngine.provisionalSettle(claimId)).to.be.revertedWithCustomError(
        settlementEngine,
        "EnforcedPause"
      );
    });
  });

  describe("Governance & Parameters", () => {
    it("allows admin to update challenge window duration", async () => {
      const newDuration = 7 * 24 * 3600; // 7 days
      await expect(settlementEngine.setChallengeWindowDuration(newDuration))
        .to.emit(settlementEngine, "ChallengeWindowDurationUpdated")
        .withArgs(CHALLENGE_WINDOW, newDuration);

      expect(await settlementEngine.challengeWindowDuration()).to.equal(newDuration);
    });

    it("rejects unauthorized challenge window updates", async () => {
      await expect(
        settlementEngine.connect(outsider).setChallengeWindowDuration(3600)
      ).to.be.revertedWithCustomError(settlementEngine, "UnauthorizedGovernance");
    });

    it("allows admin to update parameter version", async () => {
      await expect(settlementEngine.setParameterVersion(2))
        .to.emit(settlementEngine, "ParameterVersionUpdated")
        .withArgs(1, 2);

      expect(await settlementEngine.parameterVersion()).to.equal(2);
    });
  });
});

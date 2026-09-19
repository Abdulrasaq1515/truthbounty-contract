import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  ClaimRegistry,
  VerificationAggregator,
  AppealVerificationRound,
  RewardToken,
  MockReputationOracle,
  GovernanceController,
} from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { deployClaimRegistry } from "../helpers/deployClaimRegistry";

describe("AppealVerificationRound (SC-017)", () => {
  let admin: SignerWithAddress;
  let claimCreator: SignerWithAddress;
  let appellant1: SignerWithAddress;
  let appellant2: SignerWithAddress;
  let outsider: SignerWithAddress;

  let token: RewardToken;
  let oracle: MockReputationOracle;
  let govController: GovernanceController;
  let claimRegistry: ClaimRegistry;
  let appealManager: AppealVerificationRound;
  let appealAggregator: VerificationAggregator;

  const APPEAL_DURATION = 3 * 24 * 3600; // 3 days
  const MIN_APPEAL_STAKE = ethers.parseEther("200");
  const STAKE_MULTIPLIER_BPS = 15000; // 1.5x
  const MAX_WEIGHT_CAP = ethers.parseEther("10000");

  beforeEach(async () => {
    [admin, claimCreator, appellant1, appellant2, outsider] = await ethers.getSigners();

    // 1. Deploy Token
    const TokenFactory = await ethers.getContractFactory("RewardToken");
    token = await TokenFactory.deploy(admin.address, ethers.parseEther("1000000"));
    await token.waitForDeployment();

    // 2. Deploy Mock Oracle
    const OracleFactory = await ethers.getContractFactory("MockReputationOracle");
    oracle = await OracleFactory.deploy();
    await oracle.waitForDeployment();

    // 3. Deploy Governance Controller
    const GovFactory = await ethers.getContractFactory("GovernanceController");
    govController = await GovFactory.deploy(admin.address);
    await govController.waitForDeployment();

    // 4. Deploy ClaimRegistry
    claimRegistry = await deployClaimRegistry(admin.address);

    // 5. Deploy AppealVerificationRound
    const AppealFactory = await ethers.getContractFactory("AppealVerificationRound");
    const initialConfig = {
      roundDuration: APPEAL_DURATION,
      minStakeAmount: MIN_APPEAL_STAKE,
      stakeMultiplierBps: STAKE_MULTIPLIER_BPS,
      maxWeightCap: MAX_WEIGHT_CAP,
      parameterVersion: 1,
    };

    appealManager = await AppealFactory.deploy(
      await token.getAddress(),
      await claimRegistry.getAddress(),
      await oracle.getAddress(),
      initialConfig,
      await govController.getAddress(),
      admin.address
    );
    await appealManager.waitForDeployment();

    // 6. Deploy VerificationAggregator pointing to AppealVerificationRound
    const AggFactory = await ethers.getContractFactory("VerificationAggregator");
    appealAggregator = await AggFactory.deploy(
      await appealManager.getAddress(),
      admin.address,
      0, // minCount
      0, // minWeight
      0  // minConfidence
    );
    await appealAggregator.waitForDeployment();

    // Fund appellants and approve
    await token.transfer(appellant1.address, ethers.parseEther("1000"));
    await token.transfer(appellant2.address, ethers.parseEther("1000"));
    await token.connect(appellant1).approve(await appealManager.getAddress(), ethers.MaxUint256);
    await token.connect(appellant2).approve(await appealManager.getAddress(), ethers.MaxUint256);

    // Set reputations
    await oracle.setReputationScore(appellant1.address, ethers.parseEther("1.0")); // 1.0x
    await oracle.setReputationScore(appellant2.address, ethers.parseEther("1.2")); // 1.2x
  });

  describe("Appeal Round Lifecycle", () => {
    let claimId: bigint;

    beforeEach(async () => {
      const now = await time.latest();
      const sampleCID = "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco";
      await claimRegistry.connect(claimCreator).createClaim(
        "Claim Under Dispute Test 123",
        sampleCID,
        now + 86400
      );
      claimId = 1n;
    });

    it("opens an appeal round with frozen immutable parameters", async () => {
      const tx = await appealManager.connect(outsider).openAppealRound(claimId);
      await expect(tx).to.emit(appealManager, "AppealRoundOpened");

      const round = await appealManager.getAppealRound(claimId);
      expect(round.status).to.equal(1); // OPEN
      expect(round.minStakeAmount).to.equal(MIN_APPEAL_STAKE);
      expect(round.stakeMultiplierBps).to.equal(STAKE_MULTIPLIER_BPS);
      expect(await appealManager.isAppealOpen(claimId)).to.be.true;
    });

    it("reverts on duplicate appeal round opening for the same claim", async () => {
      await appealManager.openAppealRound(claimId);
      await expect(appealManager.openAppealRound(claimId)).to.be.revertedWithCustomError(
        appealManager,
        "AppealRoundAlreadyExists"
      );
    });

    it("reverts if claim does not exist in registry", async () => {
      await expect(appealManager.openAppealRound(999)).to.be.revertedWithCustomError(
        claimRegistry,
        "ClaimNotFound"
      );
    });

    it("accepts valid appeal votes, custodies stake, and computes weights", async () => {
      await appealManager.openAppealRound(claimId);

      const stake = ethers.parseEther("200");
      // appellant1 (1.0 rep, 1.5x appeal multiplier) -> 200 * 1.5 = 300 effective weight
      await expect(appealManager.connect(appellant1).submitAppealVote(claimId, true, stake))
        .to.emit(appealManager, "AppealVoteSubmitted")
        .withArgs(claimId, appellant1.address, true, stake, ethers.parseEther("300"));

      // Check contract token balance
      expect(await token.balanceOf(await appealManager.getAddress())).to.equal(stake);

      const vote = await appealManager.getAppealVote(claimId, appellant1.address);
      expect(vote.voted).to.be.true;
      expect(vote.support).to.be.true;
      expect(vote.effectiveStake).to.equal(ethers.parseEther("300"));
    });

    it("reverts if vote stake is below minStakeAmount", async () => {
      await appealManager.openAppealRound(claimId);
      const lowStake = ethers.parseEther("50");
      await expect(
        appealManager.connect(appellant1).submitAppealVote(claimId, true, lowStake)
      ).to.be.revertedWithCustomError(appealManager, "InsufficientStake");
    });

    it("reverts on duplicate voting by the same address in the appeal round", async () => {
      await appealManager.openAppealRound(claimId);
      await appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE);

      await expect(
        appealManager.connect(appellant1).submitAppealVote(claimId, false, MIN_APPEAL_STAKE)
      ).to.be.revertedWithCustomError(appealManager, "AlreadyVotedInAppeal");
    });

    it("reverts when voting after appeal deadline", async () => {
      await appealManager.openAppealRound(claimId);
      await time.increase(APPEAL_DURATION + 10);

      await expect(
        appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE)
      ).to.be.revertedWithCustomError(appealManager, "AppealRoundExpired");
    });

    it("permissionlessly closes the appeal round after deadline", async () => {
      await appealManager.openAppealRound(claimId);
      await appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE);

      await expect(appealManager.closeAppealRound(claimId)).to.be.revertedWithCustomError(
        appealManager,
        "AppealRoundNotExpired"
      );

      await time.increase(APPEAL_DURATION + 10);
      await expect(appealManager.connect(outsider).closeAppealRound(claimId))
        .to.emit(appealManager, "AppealRoundClosed");

      const round = await appealManager.getAppealRound(claimId);
      expect(round.status).to.equal(2); // CLOSED
      expect(await appealManager.isAppealOpen(claimId)).to.be.false;
    });

    it("implements IVerificationSource and integrates seamlessly with VerificationAggregator", async () => {
      await appealManager.openAppealRound(claimId);

      // Appellant 1 votes TRUE with 200 stake (rep 1.0 -> weight 300)
      await appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE);
      // Appellant 2 votes FALSE with 200 stake (rep 1.2 -> 200 * 1.2 * 1.5 = 360 weight)
      await appealManager.connect(appellant2).submitAppealVote(claimId, false, MIN_APPEAL_STAKE);

      expect(await appealManager.getClaimVoterCount(claimId)).to.equal(2);
      expect(await appealManager.getClaimVoterAt(claimId, 0)).to.equal(appellant1.address);
      expect(await appealManager.getClaimVoterAt(claimId, 1)).to.equal(appellant2.address);

      // Aggregate via VerificationAggregator
      await appealAggregator.aggregateClaim(claimId);
      const aggResult = await appealAggregator.getAggregation(claimId);

      expect(aggResult.outcome).to.equal(1); // VERIFIED_FALSE (360 > 300)
      expect(aggResult.trueWeight).to.equal(ethers.parseEther("300"));
      expect(aggResult.falseWeight).to.equal(ethers.parseEther("360"));
      expect(aggResult.totalWeight).to.equal(ethers.parseEther("660"));
    });
  });

  describe("Governance & Configuration", () => {
    it("allows admin to update default appeal round config", async () => {
      const newConfig = {
        roundDuration: 5 * 24 * 3600,
        minStakeAmount: ethers.parseEther("500"),
        stakeMultiplierBps: 20000, // 2.0x
        maxWeightCap: ethers.parseEther("50000"),
        parameterVersion: 2,
      };

      await expect(appealManager.setDefaultConfig(newConfig))
        .to.emit(appealManager, "DefaultAppealConfigUpdated");

      const cfg = await appealManager.defaultConfig();
      expect(cfg.minStakeAmount).to.equal(ethers.parseEther("500"));
    });

    it("rejects unauthorized config changes", async () => {
      const newConfig = {
        roundDuration: 5 * 24 * 3600,
        minStakeAmount: ethers.parseEther("500"),
        stakeMultiplierBps: 20000,
        maxWeightCap: ethers.parseEther("50000"),
        parameterVersion: 2,
      };

      await expect(
        appealManager.connect(outsider).setDefaultConfig(newConfig)
      ).to.be.revertedWithCustomError(appealManager, "UnauthorizedGovernance");
    });
  });
});

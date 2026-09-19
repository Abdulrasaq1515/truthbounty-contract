import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("VerificationAggregator", function () {
  let truthBounty: any;
  let bountyToken: any;
  let mockOracle: any;
  let aggregator: any;
  let owner: Signer;
  let submitter: Signer;
  let verifier1: Signer;
  let verifier2: Signer;
  let verifier3: Signer;
  let verifier4: Signer;
  let stranger: Signer;

  const MIN_STAKE = ethers.parseEther("100");
  const GRACE_PERIOD_ADVANCE = 2 * 24 * 60 * 60 + 1; // > 2-day reputation grace period

  const outcome = {
    VERIFIED_TRUE: 0n,
    VERIFIED_FALSE: 1n,
    INCONCLUSIVE: 2n,
  };

  beforeEach(async function () {
    [owner, submitter, verifier1, verifier2, verifier3, verifier4, stranger] =
      await ethers.getSigners();

    const TruthBountyToken = await ethers.getContractFactory("TruthBountyToken");
    bountyToken = await TruthBountyToken.deploy(await owner.getAddress());
    await bountyToken.waitForDeployment();

    const MockReputationOracle = await ethers.getContractFactory("MockReputationOracle");
    mockOracle = await MockReputationOracle.deploy();
    await mockOracle.waitForDeployment();

    const TruthBountyWeighted = await ethers.getContractFactory("TruthBountyWeighted");
    truthBounty = await TruthBountyWeighted.deploy(
      await bountyToken.getAddress(),
      await mockOracle.getAddress(),
      await owner.getAddress(),
      await owner.getAddress()
    );
    await truthBounty.waitForDeployment();

    await bountyToken.transfer(await truthBounty.getAddress(), ethers.parseEther("1000000"));

    for (const signer of [verifier1, verifier2, verifier3, verifier4]) {
      await bountyToken.transfer(await signer.getAddress(), ethers.parseEther("100000"));
      await bountyToken.connect(signer).approve(await truthBounty.getAddress(), ethers.MaxUint256);
    }

    const VerificationAggregator = await ethers.getContractFactory("VerificationAggregator");
    aggregator = await VerificationAggregator.deploy(
      await truthBounty.getAddress(),
      await owner.getAddress(),
      1, // minVerificationCount
      0, // minTotalWeight
      0 // minConfidenceBps
    );
    await aggregator.waitForDeployment();
  });

  async function createClaim(): Promise<bigint> {
    const tx = await truthBounty.connect(submitter).createClaim("QmTestHash");
    await tx.wait();
    return (await truthBounty.claimCounter()) - 1n;
  }

  async function stakeFor(signers: Signer[], amount: bigint = MIN_STAKE) {
    for (const s of signers) {
      await truthBounty.connect(s).stake(amount);
    }
  }

  async function voteFor(
    claimId: bigint,
    votes: Array<{ signer: Signer; support: boolean; stake: bigint; reputation?: bigint }>
  ) {
    // Set reputations outside the grace window relative to claim creation so the
    // effective stake reflects the intended multiplier.
    await time.increase(GRACE_PERIOD_ADVANCE);
    for (const v of votes) {
      if (v.reputation !== undefined) {
        await mockOracle.setReputationScore(await v.signer.getAddress(), v.reputation);
      }
    }
    for (const v of votes) {
      await truthBounty.connect(v.signer).vote(claimId, v.support, v.stake);
    }
  }

  async function deployAggregator(opts: { minCount?: bigint; minWeight?: bigint; minConfidence?: bigint } = {}) {
    const VerificationAggregator = await ethers.getContractFactory("VerificationAggregator");
    const agg = await VerificationAggregator.deploy(
      await truthBounty.getAddress(),
      await owner.getAddress(),
      opts.minCount ?? 1n,
      opts.minWeight ?? 0n,
      opts.minConfidence ?? 0n
    );
    await agg.waitForDeployment();
    return agg;
  }

  describe("Weight calculation", function () {
    it("accumulates effective stake per side (unanimous TRUE)", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE },
        { signer: verifier2, support: true, stake: MIN_STAKE },
      ]);

      const [trueWeight, falseWeight, count] = await aggregator.calculateWeights(claimId);
      expect(trueWeight).to.equal(MIN_STAKE * 2n);
      expect(falseWeight).to.equal(0n);
      expect(count).to.equal(2n);
    });

    it("accumulates weighted stake for mixed verifications", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2, verifier3]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE, reputation: ethers.parseEther("2") },
        { signer: verifier2, support: false, stake: MIN_STAKE, reputation: ethers.parseEther("1") },
        { signer: verifier3, support: false, stake: MIN_STAKE, reputation: ethers.parseEther("0.5") },
      ]);

      const [trueWeight, falseWeight, count] = await aggregator.calculateWeights(claimId);
      expect(trueWeight).to.equal(ethers.parseEther("200"));
      expect(falseWeight).to.equal(ethers.parseEther("150"));
      expect(count).to.equal(3n);
    });
  });

  describe("Confidence calculation", function () {
    it("returns winning weight over total in basis points", async function () {
      expect(await aggregator.calculateConfidence(ethers.parseEther("99"), ethers.parseEther("100")))
        .to.equal(9900n);
      expect(await aggregator.calculateConfidence(ethers.parseEther("75"), ethers.parseEther("100")))
        .to.equal(7500n);
      expect(await aggregator.calculateConfidence(ethers.parseEther("51"), ethers.parseEther("100")))
        .to.equal(5100n);
    });

    it("returns 0 for zero total weight", async function () {
      expect(await aggregator.calculateConfidence(0, 0)).to.equal(0n);
    });

    it("returns 10000 for unanimous results", async function () {
      expect(await aggregator.calculateConfidence(ethers.parseEther("100"), ethers.parseEther("100")))
        .to.equal(10000n);
    });
  });

  describe("Outcome resolution", function () {
    it("resolves unanimous TRUE as VERIFIED_TRUE", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE },
        { signer: verifier2, support: true, stake: MIN_STAKE },
      ]);

      await expect(aggregator.aggregateClaim(claimId))
        .to.emit(aggregator, "ClaimAggregated")
        .withArgs(claimId, outcome.VERIFIED_TRUE, 10000n);

      const result = await aggregator.getAggregation(claimId);
      expect(result.outcome).to.equal(outcome.VERIFIED_TRUE);
      expect(result.confidence).to.equal(10000n);
      expect(result.totalWeight).to.equal(MIN_STAKE * 2n);
    });

    it("resolves unanimous FALSE as VERIFIED_FALSE", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2]);
      await voteFor(claimId, [
        { signer: verifier1, support: false, stake: MIN_STAKE },
        { signer: verifier2, support: false, stake: MIN_STAKE },
      ]);

      await expect(aggregator.aggregateClaim(claimId))
        .to.emit(aggregator, "ClaimAggregated")
        .withArgs(claimId, outcome.VERIFIED_FALSE, 10000n);

      const result = await aggregator.getAggregation(claimId);
      expect(result.outcome).to.equal(outcome.VERIFIED_FALSE);
      expect(result.confidence).to.equal(10000n);
    });

    it("resolves weighted TRUE majority", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2, verifier3, verifier4]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE, reputation: ethers.parseEther("3") },
        { signer: verifier2, support: true, stake: MIN_STAKE, reputation: ethers.parseEther("1") },
        { signer: verifier3, support: false, stake: MIN_STAKE },
        { signer: verifier4, support: false, stake: MIN_STAKE },
      ]);

      // trueWeight 400 vs falseWeight 200 → VERIFIED_TRUE @ 6666 bps
      await expect(aggregator.aggregateClaim(claimId))
        .to.emit(aggregator, "ClaimAggregated")
        .withArgs(claimId, outcome.VERIFIED_TRUE, 6666n);

      const result = await aggregator.getAggregation(claimId);
      expect(result.trueWeight).to.equal(ethers.parseEther("400"));
      expect(result.falseWeight).to.equal(ethers.parseEther("200"));
      expect(result.confidence).to.equal(6666n);
    });

    it("resolves weighted FALSE majority", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2, verifier3]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE },
        { signer: verifier2, support: false, stake: MIN_STAKE, reputation: ethers.parseEther("3") },
        { signer: verifier3, support: false, stake: MIN_STAKE },
      ]);

      // trueWeight 100 vs falseWeight 400 → VERIFIED_FALSE @ 8000 bps
      await expect(aggregator.aggregateClaim(claimId))
        .to.emit(aggregator, "ClaimAggregated")
        .withArgs(claimId, outcome.VERIFIED_FALSE, 8000n);
    });
  });

  describe("Tie handling", function () {
    it("resolves exact TRUE/FALSE weight tie as INCONCLUSIVE", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE },
        { signer: verifier2, support: false, stake: MIN_STAKE },
      ]);

      await expect(aggregator.aggregateClaim(claimId))
        .to.emit(aggregator, "ClaimAggregated")
        .withArgs(claimId, outcome.INCONCLUSIVE, 0n);

      const result = await aggregator.getAggregation(claimId);
      expect(result.outcome).to.equal(outcome.INCONCLUSIVE);
      expect(result.confidence).to.equal(0n);
    });

    it("resolves equal-stake weighted tie as INCONCLUSIVE", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE, reputation: ethers.parseEther("2") },
        { signer: verifier2, support: false, stake: MIN_STAKE, reputation: ethers.parseEther("2") },
      ]);

      await expect(aggregator.aggregateClaim(claimId))
        .to.emit(aggregator, "ClaimAggregated")
        .withArgs(claimId, outcome.INCONCLUSIVE, 0n);
    });

    it("resolves no-participation claims as INCONCLUSIVE", async function () {
      const aggregator = await deployAggregator({ minCount: 0n });
      const claimId = await createClaim();

      await expect(aggregator.aggregateClaim(claimId))
        .to.emit(aggregator, "ClaimAggregated")
        .withArgs(claimId, outcome.INCONCLUSIVE, 0n);
    });
  });

  describe("Minimum participation thresholds", function () {
    it("reverts when verification count is below minimum", async function () {
      const aggregator = await deployAggregator({ minCount: 2n });
      const claimId = await createClaim();
      await stakeFor([verifier1]);
      await voteFor(claimId, [{ signer: verifier1, support: true, stake: MIN_STAKE }]);

      await expect(aggregator.aggregateClaim(claimId))
        .to.be.revertedWithCustomError(aggregator, "ThresholdNotMet")
        .withArgs("Insufficient verification count");
    });

    it("reverts when total weight is below minimum", async function () {
      const aggregator = await deployAggregator({ minWeight: ethers.parseEther("500") });
      const claimId = await createClaim();
      await stakeFor([verifier1]);
      await voteFor(claimId, [{ signer: verifier1, support: true, stake: MIN_STAKE }]);

      await expect(aggregator.aggregateClaim(claimId))
        .to.be.revertedWithCustomError(aggregator, "ThresholdNotMet")
        .withArgs("Insufficient total weight");
    });

    it("reverts when confidence is below minimum", async function () {
      const aggregator = await deployAggregator({ minConfidence: 8000n });
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2, verifier3]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE },
        { signer: verifier2, support: true, stake: MIN_STAKE },
        { signer: verifier3, support: false, stake: MIN_STAKE },
      ]);

      // Confidence 6666 < 8000
      await expect(aggregator.aggregateClaim(claimId))
        .to.be.revertedWithCustomError(aggregator, "ThresholdNotMet")
        .withArgs("Insufficient confidence");
    });
  });

  describe("Determinism and order independence", function () {
    it("produces the same aggregation regardless of vote submission order", async function () {
      const votes = [
        { signer: verifier1, support: true, stake: MIN_STAKE, reputation: ethers.parseEther("2") },
        { signer: verifier2, support: false, stake: MIN_STAKE, reputation: ethers.parseEther("1") },
        { signer: verifier3, support: true, stake: MIN_STAKE, reputation: ethers.parseEther("3") },
        { signer: verifier4, support: false, stake: MIN_STAKE, reputation: ethers.parseEther("1") },
      ];
      const claim1 = await createClaim();
      await stakeFor([verifier1, verifier2, verifier3, verifier4], MIN_STAKE);
      await voteFor(claim1, votes.slice().reverse());

      const claim2 = await createClaim();
      await stakeFor([verifier1, verifier2, verifier3, verifier4], MIN_STAKE);
      await voteFor(claim2, votes);

      const [true1, false1, count1] = await aggregator.calculateWeights(claim1);
      const [true2, false2, count2] = await aggregator.calculateWeights(claim2);
      expect(true1).to.equal(true2);
      expect(false1).to.equal(false2);
      expect(count1).to.equal(count2);
    });

    it("returns identical aggregation on repeated calls", async function () {
      const claimId = await createClaim();
      await stakeFor([verifier1, verifier2]);
      await voteFor(claimId, [
        { signer: verifier1, support: true, stake: MIN_STAKE },
        { signer: verifier2, support: false, stake: MIN_STAKE },
      ]);
      await aggregator.aggregateClaim(claimId);
      const first = await aggregator.getAggregation(claimId);
      await expect(aggregator.aggregateClaim(claimId))
        .to.be.revertedWithCustomError(aggregator, "AlreadyAggregated")
        .withArgs(claimId);
      const second = await aggregator.getAggregation(claimId);
      expect(second.outcome).to.equal(first.outcome);
      expect(second.confidence).to.equal(first.confidence);
    });

    it("handles numeric bounds without overflow", async function () {
      const values = [0n, 1n, 100n, 1_000_000n, 1_000_000_000n];
      for (const trueWeight of values) {
        for (const falseWeight of values) {
          const total = trueWeight + falseWeight;
          if (total === 0n) continue;
          const confidence = await aggregator.calculateConfidence(trueWeight, total);
          expect(confidence).to.be.lte(10000n);
        }
      }
    });
  });
});

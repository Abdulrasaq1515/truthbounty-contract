import { expect } from "chai";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { ClaimRegistry, StakeVault, DisputeResolution, MockERC20 } from "../typechain-types";
import { deployClaimRegistry } from "./helpers/deployClaimRegistry";

describe("DisputeResolution", function () {
    const BOND = ethers.parseEther("500");
    const WINDOW = 3n * 24n * 60n * 60n; // 3 days (seconds)
    const RATIONALE = ethers.id("evidence-cid-123");
    const VALID_CID = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
    const VALID_STATEMENT = "The unemployment rate in Germany fell to 5.1% in Q1 2026 according to Destatis.";

    // IClaimRegistry.ClaimStatus
    const PENDING = 0n;
    const VERIFIED_TRUE = 2n;
    const VERIFIED_FALSE = 3n;
    const DISPUTED = 4n;
    const CANCELLED = 5n;

    // IDisputeResolution.ChallengedOutcome
    const OUTCOME_TRUE = 0n;
    const OUTCOME_FALSE = 1n;

    type Fixture = {
        registry: ClaimRegistry;
        vault: StakeVault;
        dispute: DisputeResolution;
        token: MockERC20;
        admin: SignerWithAddress;
        updater: SignerWithAddress;
        challenger: SignerWithAddress;
        challenger2: SignerWithAddress;
        claimCreator: SignerWithAddress;
    };

    async function deployFixture(): Promise<Fixture> {
        const [admin, updater, challenger, challenger2, claimCreator] = await ethers.getSigners();

        const registry = await deployClaimRegistry(admin.address);

        const REGISTRY_UPDATER_ROLE = await registry.REGISTRY_UPDATER_ROLE();
        await registry.connect(admin).grantRole(REGISTRY_UPDATER_ROLE, updater.address);

        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        const token = (await MockERC20Factory.deploy("Bounty", "BOUNTY")) as MockERC20;
        await token.waitForDeployment();

        const StakeVaultFactory = await ethers.getContractFactory("contracts/StakeVault.sol:StakeVault");
        const vault = (await StakeVaultFactory.deploy(admin.address, await token.getAddress())) as StakeVault;
        await vault.waitForDeployment();

        const DisputeResolutionFactory = await ethers.getContractFactory("DisputeResolution");
        const dispute = (await DisputeResolutionFactory.deploy(
            await registry.getAddress(),
            await vault.getAddress(),
            await token.getAddress(),
            BOND,
            WINDOW,
            admin.address
        )) as DisputeResolution;
        await dispute.waitForDeployment();

        // Authorise the dispute module to transition claims.
        await registry.connect(admin).grantRole(REGISTRY_UPDATER_ROLE, await dispute.getAddress());
        // Authorise the dispute module as the vault operator.
        const OPERATOR_ROLE = await vault.OPERATOR_ROLE();
        await vault.connect(admin).grantRole(OPERATOR_ROLE, await dispute.getAddress());

        // Fund challengers and creator.
        await token.mint(challenger.address, ethers.parseEther("100000"));
        await token.mint(challenger2.address, ethers.parseEther("100000"));
        await token.mint(claimCreator.address, ethers.parseEther("100000"));

        return { registry, vault, dispute, token, admin, updater, challenger, challenger2, claimCreator };
    }

    async function createClaim(fx: Fixture, offset = 24n * 60n * 60n) {
        const deadline = BigInt(await time.latest()) + offset;
        await fx.registry.connect(fx.claimCreator).createClaim(VALID_STATEMENT, VALID_CID, deadline);
        return deadline;
    }

    async function driveToOutcome(fx: Fixture, claimId: bigint, outcome: bigint) {
        await fx.registry.connect(fx.updater).updateClaimStatus(claimId, outcome);
    }

    async function jumpIntoWindow(fx: Fixture, claimId: bigint) {
        const deadline = (await fx.registry.getClaim(claimId)).verificationDeadline;
        await time.increaseTo(Number(deadline) + 1);
    }

    async function approveChallenge(fx: Fixture, who: SignerWithAddress, amount = BOND) {
        await fx.token.connect(who).approve(await fx.vault.getAddress(), amount);
    }

    describe("openDispute - success", function () {
        it("opens with a valid timestamp, custodies the bond, and transitions the claim", async function () {
            const fx = await loadFixture(deployFixture);
            const { registry, vault, dispute, token, challenger } = fx;
            const deadline = await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await jumpIntoWindow(fx, claimId);
            await approveChallenge(fx, challenger);

            const vaultBefore = await token.balanceOf(await vault.getAddress());

            await dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE);

            expect(await dispute.totalDisputes()).to.equal(1n);
            expect(await dispute.disputeExists(1n)).to.equal(true);
            expect(await dispute.getDisputeByClaim(claimId)).to.equal(1n);

            // Bond custody: tokens vaulted.
            expect(await token.balanceOf(await vault.getAddress())).to.equal(vaultBefore + BOND);
            expect(await vault.totalLocked()).to.equal(BOND);
            const lock = await vault.getLock(1n);
            expect(lock.amount).to.equal(BOND);
            expect(lock.depositor).to.equal(challenger.address);

            // Dispute record content.
            const d = await dispute.getDispute(1n);
            expect(d.claimId).to.equal(claimId);
            expect(d.challenger).to.equal(challenger.address);
            expect(d.challengedOutcome).to.equal(OUTCOME_TRUE);
            expect(d.challengedStatus).to.equal(VERIFIED_TRUE);
            expect(d.bondToken).to.equal(await token.getAddress());
            expect(d.bondAmount).to.equal(BOND);
            expect(d.appealRationaleHash).to.equal(RATIONALE);
            expect(d.appealDeadline).to.equal(deadline + WINDOW);
            expect(d.settled).to.equal(false);

            // Claim transitioned to Disputed.
            expect(await registry.getClaimStatus(claimId)).to.equal(DISPUTED);
        });

        it("emits DisputeOpenedV1 with all challenge-bond inputs", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, token, challenger } = fx;
            const deadline = await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_FALSE);
            await jumpIntoWindow(fx, claimId);
            await approveChallenge(fx, challenger);

            await expect(dispute.connect(challenger).openDispute(claimId, OUTCOME_FALSE, RATIONALE))
                .to.emit(dispute, "DisputeOpenedV1")
                .withArgs(
                    claimId,
                    1n,
                    challenger.address,
                    OUTCOME_FALSE,
                    VERIFIED_FALSE,
                    await token.getAddress(),
                    BOND,
                    deadline + WINDOW,
                    RATIONALE,
                    anyUint64,
                    1n
                );
        });

        it("supports challenging a VerifiedFalse claim", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger } = fx;
            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_FALSE);
            await jumpIntoWindow(fx, claimId);
            await approveChallenge(fx, challenger);

            await dispute.connect(challenger).openDispute(claimId, OUTCOME_FALSE, RATIONALE);
            const d = await dispute.getDispute(1n);
            expect(d.challengedStatus).to.equal(VERIFIED_FALSE);
        });
    });

    describe("openDispute - timing", function () {
        it("reverts when challenged inside the verification window (too early)", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger } = fx;
            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await approveChallenge(fx, challenger);

            await expect(dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE))
                .to.be.revertedWithCustomError(dispute, "ChallengeWindowNotOpen");

            expect(await dispute.totalDisputes()).to.equal(0n);
            expect(await dispute.getDisputeByClaim(claimId)).to.equal(0n);
        });

        it("reverts when challenged after the frozen deadline (too late)", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger } = fx;
            const deadline = await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await time.increaseTo(Number(deadline) + Number(WINDOW) + 1);
            await approveChallenge(fx, challenger);

            await expect(dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE))
                .to.be.revertedWithCustomError(dispute, "FrozenDeadlinePassed");

            expect(await dispute.totalDisputes()).to.equal(0n);
        });
    });

    describe("openDispute - one appeal path per claim", function () {
        it("rejects a duplicate challenge (even from another address)", async function () {
            const fx = await loadFixture(deployFixture);
            const { vault, dispute, challenger, challenger2 } = fx;
            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await jumpIntoWindow(fx, claimId);
            await approveChallenge(fx, challenger);

            await dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE);

            await approveChallenge(fx, challenger2);
            await expect(dispute.connect(challenger2).openDispute(claimId, OUTCOME_FALSE, RATIONALE))
                .to.be.revertedWithCustomError(dispute, "DisputeAlreadyOpen");

            expect(await dispute.totalDisputes()).to.equal(1n);
            expect(await vault.totalLocked()).to.equal(BOND);
        });

        it("rejects a recursive reopen on an already-Disputed claim", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger } = fx;
            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await jumpIntoWindow(fx, claimId);
            await approveChallenge(fx, challenger);

            await dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE);

            await expect(dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE))
                .to.be.revertedWithCustomError(dispute, "DisputeAlreadyOpen")
                .withArgs(claimId);
        });
    });

    describe("openDispute - non-challengeable states", function () {
        it("reverts for a Pending claim", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger } = fx;
            await createClaim(fx);
            const claimId = 1n;
            await approveChallenge(fx, challenger);

            await expect(dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE))
                .to.be.revertedWithCustomError(dispute, "ClaimNotChallengeable");
        });

        it("reverts for a Cancelled claim", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger } = fx;
            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, CANCELLED);
            await jumpIntoWindow(fx, claimId);
            await approveChallenge(fx, challenger);

            await expect(dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE))
                .to.be.revertedWithCustomError(dispute, "ClaimNotChallengeable");
        });
    });

    describe("openDispute - bond gating", function () {
        it("reverts with insufficient allowance (bond is mandatory)", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger } = fx;
            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await jumpIntoWindow(fx, claimId);

            await expect(dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE))
                .to.be.revertedWithCustomError(dispute, "InsufficientBondAllowance");
        });

        it("admin cannot waive the bond requirement", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, admin } = fx;
            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await jumpIntoWindow(fx, claimId);

            await expect(dispute.connect(admin).openDispute(claimId, OUTCOME_TRUE, RATIONALE))
                .to.be.revertedWithCustomError(dispute, "InsufficientBondAllowance");
        });

        it("failing bond transfer reverts atomically with no state or custody", async function () {
            const fx = await loadFixture(deployFixture);
            const { registry, vault, admin, challenger } = fx;

            const FailingFactory = await ethers.getContractFactory("MockFailingBondERC20");
            const failing = await FailingFactory.deploy();
            await failing.waitForDeployment();

            const DisputeResolutionFactory = await ethers.getContractFactory("DisputeResolution");
            const failingModule = (await DisputeResolutionFactory.deploy(
                await registry.getAddress(),
                await vault.getAddress(),
                await failing.getAddress(),
                BOND,
                WINDOW,
                admin.address
            )) as DisputeResolution;
            await failingModule.waitForDeployment();

            await registry.connect(admin).grantRole(await registry.REGISTRY_UPDATER_ROLE(), await failingModule.getAddress());
            const OPERATOR_ROLE = await vault.OPERATOR_ROLE();
            await vault.connect(admin).grantRole(OPERATOR_ROLE, await failingModule.getAddress());

            await failing.mint(challenger.address, ethers.parseEther("100000"));
            await failing.connect(challenger).approve(await vault.getAddress(), BOND);

            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await jumpIntoWindow(fx, claimId);

            await expect(failingModule.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE))
                .to.be.revertedWithCustomError(failingModule, "CustodyTransitionFailed");

            // Atomic: no dispute record, claim transition, or vault lock.
            expect(await failingModule.totalDisputes()).to.equal(0n);
            expect(await registry.getClaimStatus(claimId)).to.equal(VERIFIED_TRUE);
            expect(await vault.totalLocked()).to.equal(0n);
            expect(await failing.allowance(challenger.address, await vault.getAddress())).to.equal(BOND);
        });
    });

    describe("openDispute - paused", function () {
        it("reverts when paused", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger, admin } = fx;
            await dispute.connect(admin).grantRole(await dispute.PAUSER_ROLE(), admin.address);
            await dispute.connect(admin).pause();

            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await jumpIntoWindow(fx, claimId);
            await approveChallenge(fx, challenger);

            await expect(dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE)).to.be.reverted;
        });

        it("succeeds after unpause", async function () {
            const fx = await loadFixture(deployFixture);
            const { dispute, challenger, admin } = fx;
            await dispute.connect(admin).grantRole(await dispute.PAUSER_ROLE(), admin.address);
            await dispute.connect(admin).pause();
            await dispute.connect(admin).unpause();

            await createClaim(fx);
            const claimId = 1n;
            await driveToOutcome(fx, claimId, VERIFIED_TRUE);
            await jumpIntoWindow(fx, claimId);
            await approveChallenge(fx, challenger);

            await dispute.connect(challenger).openDispute(claimId, OUTCOME_TRUE, RATIONALE);
            expect(await dispute.totalDisputes()).to.equal(1n);
        });
    });

    describe("view helpers", function () {
        it("exposes configured bond and window", async function () {
            const { registry, vault, dispute, token } = await loadFixture(deployFixture);
            expect(await dispute.bondToken()).to.equal(await token.getAddress());
            expect(await dispute.bondAmount()).to.equal(BOND);
            expect(await dispute.challengeWindowDuration()).to.equal(WINDOW);
            expect(await dispute.claimRegistry()).to.equal(await registry.getAddress());
            expect(await dispute.vault()).to.equal(await vault.getAddress());
        });

        it("returns false for unknown disputes", async function () {
            const { dispute } = await loadFixture(deployFixture);
            expect(await dispute.disputeExists(999n)).to.equal(false);
            expect(await dispute.getDisputeByClaim(999n)).to.equal(0n);
        });
    });
});

function anyUint64(value: unknown): boolean {
    return typeof value === "bigint" && value >= 0n && value <= (1n << 64n) - 1n;
}

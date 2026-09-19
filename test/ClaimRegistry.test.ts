import { expect } from "chai";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";
import type { ClaimRegistry } from "../typechain-types";
import { deployClaimRegistry } from "./helpers/deployClaimRegistry";

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/** A valid 46-character CIDv0 (sha2-256 base58) */
const VALID_CID = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"; // 46 chars

/** A valid statement of exactly 10 characters */
const MIN_STATEMENT = "0123456789";

/** A typical, realistic statement */
const TYPICAL_STATEMENT =
    "The unemployment rate in Germany fell to 5.1% in Q1 2026 according to Destatis.";

/** Returns a deadline `offsetSeconds` seconds in the future from `now` */
async function futureDeadline(offsetSeconds = 7 * 24 * 60 * 60 /* 7 days */): Promise<number> {
    const now = await time.latest();
    return now + offsetSeconds;
}

// ─────────────────────────────────────────────────────────────────────────────
// Fixture
// ─────────────────────────────────────────────────────────────────────────────

async function deployFixture() {
    const [admin, updater, user, other] = await ethers.getSigners();

    const registry = await deployClaimRegistry(admin.address);

    // Grant the REGISTRY_UPDATER_ROLE to `updater` so we can test status updates
    const REGISTRY_UPDATER_ROLE = await registry.REGISTRY_UPDATER_ROLE();
    await registry.connect(admin).grantRole(REGISTRY_UPDATER_ROLE, updater.address);

    return { registry, admin, updater, user, other, REGISTRY_UPDATER_ROLE };
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Suite
// ─────────────────────────────────────────────────────────────────────────────

describe("ClaimRegistry", function () {
    // =========================================================================
    // Deployment
    // =========================================================================

    describe("Deployment", function () {
        it("grants DEFAULT_ADMIN_ROLE and ADMIN_ROLE to the initial admin", async function () {
            const { registry, admin } = await loadFixture(deployFixture);

            const DEFAULT_ADMIN_ROLE = await registry.DEFAULT_ADMIN_ROLE();
            const ADMIN_ROLE = await registry.ADMIN_ROLE();

            expect(await registry.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
            expect(await registry.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
        });

        it("initialises totalClaims to zero", async function () {
            const { registry } = await loadFixture(deployFixture);
            expect(await registry.totalClaims()).to.equal(0);
        });

        it("reverts if initial admin is the zero address", async function () {
            const [admin] = await ethers.getSigners();
            const ParamFactory = await ethers.getContractFactory("ParameterVersionRegistry");
            const paramRegistry = await ParamFactory.deploy(admin.address, admin.address);
            await paramRegistry.waitForDeployment();

            const ClaimRegistry = await ethers.getContractFactory("ClaimRegistry");
            await expect(
                ClaimRegistry.deploy(ethers.ZeroAddress, await paramRegistry.getAddress())
            ).to.be.revertedWith("ClaimRegistry: zero admin address");
        });
    });

    // =========================================================================
    // Successful Claim Creation
    // =========================================================================

    describe("createClaim — success cases", function () {
        it("creates the first claim and returns ID 1", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();

            // staticCall previews the return value without consuming the ID
            const claimId = await registry
                .connect(user)
                .createClaim.staticCall(TYPICAL_STATEMENT, VALID_CID, deadline);
            expect(claimId).to.equal(1n);

            // Now actually send the transaction and verify it does not revert
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline),
            ).to.not.be.reverted;
        });

        it("assigns sequential IDs to multiple claims", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            const id1 = await registry
                .connect(user)
                .createClaim.staticCall(TYPICAL_STATEMENT, VALID_CID, deadline);
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            const id2 = await registry
                .connect(user)
                .createClaim.staticCall(TYPICAL_STATEMENT + " 2", VALID_CID, deadline);
            await registry.connect(user).createClaim(TYPICAL_STATEMENT + " 2", VALID_CID, deadline);

            expect(id1).to.equal(1n);
            expect(id2).to.equal(2n);
        });

        it("stores the creator address correctly", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            expect(await registry.getClaimCreator(1)).to.equal(user.address);
        });

        it("records createdAt close to block.timestamp", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            const claim = await registry.getClaim(1);
            const blockTimestamp = BigInt(await time.latest());

            // Allow 1 second tolerance
            expect(claim.createdAt).to.be.gte(blockTimestamp - 1n);
            expect(claim.createdAt).to.be.lte(blockTimestamp + 1n);
        });

        it("stores the verification deadline correctly", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline(14 * 24 * 60 * 60); // 14 days
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            const claim = await registry.getClaim(1);
            expect(claim.verificationDeadline).to.equal(BigInt(deadline));
        });

        it("initialises status to Pending (0)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            const status = await registry.getClaimStatus(1);
            expect(status).to.equal(0); // ClaimStatus.Pending
        });

        it("stores statement and evidenceCID verbatim", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            const claim = await registry.getClaim(1);
            expect(claim.statement).to.equal(TYPICAL_STATEMENT);
            expect(claim.evidenceCID).to.equal(VALID_CID);
        });

        it("stores claim ID inside the struct", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            const claim = await registry.getClaim(1);
            expect(claim.id).to.equal(1n);
        });

        it("emits ClaimCreated with correct indexed args", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await expect(registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline))
                .to.emit(registry, "ClaimCreated(uint256,address,string)")
                .withArgs(1n, user.address, VALID_CID);
        });

        it("emits ClaimCreated exactly once per createClaim call", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            const receipt = await (
                await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline)
            ).wait();

            const events = receipt!.logs.filter(
                (l: { topics: readonly string[] }) =>
                    l.topics[0] === registry.interface.getEvent("ClaimCreated(uint256,address,string)").topicHash,
            );
            expect(events.length).to.equal(1);
        });

        it("increments totalClaims with each successful creation", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            expect(await registry.totalClaims()).to.equal(0);
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);
            expect(await registry.totalClaims()).to.equal(1);
            await registry.connect(user).createClaim(TYPICAL_STATEMENT + " v2", VALID_CID, deadline);
            expect(await registry.totalClaims()).to.equal(2);
        });

        it("accepts the minimum-length statement (10 chars)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await expect(registry.connect(user).createClaim(MIN_STATEMENT, VALID_CID, deadline)).to
                .not.be.reverted;
        });

        it("accepts the maximum-length statement (2000 chars)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const maxStatement = "a".repeat(2000);
            const deadline = await futureDeadline();
            await expect(registry.connect(user).createClaim(maxStatement, VALID_CID, deadline)).to
                .not.be.reverted;
        });

        it("accepts a 128-char CID (upper boundary)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const longCid = "b".repeat(128);
            const deadline = await futureDeadline();
            await expect(registry.connect(user).createClaim(TYPICAL_STATEMENT, longCid, deadline)).to
                .not.be.reverted;
        });

        it("different callers each become the creator of their own claims", async function () {
            const { registry, user, other } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);
            await registry
                .connect(other)
                .createClaim(TYPICAL_STATEMENT + " other", VALID_CID, deadline);

            expect(await registry.getClaimCreator(1)).to.equal(user.address);
            expect(await registry.getClaimCreator(2)).to.equal(other.address);
        });
    });

    // =========================================================================
    // Input Validation — Statement
    // =========================================================================

    describe("createClaim — statement validation", function () {
        it("reverts with InvalidStatement when statement is empty", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await expect(
                registry.connect(user).createClaim("", VALID_CID, deadline),
            ).to.be.revertedWithCustomError(registry, "InvalidStatement");
        });

        it("reverts with InvalidStatement when statement is 9 chars (below minimum)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await expect(
                registry.connect(user).createClaim("123456789", VALID_CID, deadline),
            ).to.be.revertedWithCustomError(registry, "InvalidStatement");
        });

        it("reverts with InvalidStatement when statement is 2001 chars (above maximum)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const overSized = "a".repeat(2001);
            const deadline = await futureDeadline();
            await expect(
                registry.connect(user).createClaim(overSized, VALID_CID, deadline),
            ).to.be.revertedWithCustomError(registry, "InvalidStatement");
        });
    });

    // =========================================================================
    // Input Validation — CID
    // =========================================================================

    describe("createClaim — CID validation", function () {
        it("reverts with InvalidCID when CID is empty", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, "", deadline),
            ).to.be.revertedWithCustomError(registry, "InvalidCID");
        });

        it("reverts with InvalidCID when CID is 45 chars (below minimum)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const shortCid = "c".repeat(45);
            const deadline = await futureDeadline();
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, shortCid, deadline),
            ).to.be.revertedWithCustomError(registry, "InvalidCID");
        });

        it("reverts with InvalidCID when CID is 129 chars (above maximum)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const overCid = "c".repeat(129);
            const deadline = await futureDeadline();
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, overCid, deadline),
            ).to.be.revertedWithCustomError(registry, "InvalidCID");
        });
    });

    // =========================================================================
    // Input Validation — Deadline
    // =========================================================================

    describe("createClaim — deadline validation", function () {
        it("reverts with InvalidDeadline when deadline equals block.timestamp", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const now = await time.latest();
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, now),
            ).to.be.revertedWithCustomError(registry, "InvalidDeadline");
        });

        it("reverts with InvalidDeadline when deadline is in the past", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const past = (await time.latest()) - 3600;
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, past),
            ).to.be.revertedWithCustomError(registry, "InvalidDeadline");
        });

        it("reverts with InvalidDeadline when deadline exceeds maximum horizon (365 days + 1)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const tooFar = (await time.latest()) + 365 * 24 * 60 * 60 + 2;
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, tooFar),
            ).to.be.revertedWithCustomError(registry, "InvalidDeadline");
        });

        it("accepts a deadline exactly 1 second in the future", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const minFuture = (await time.latest()) + 2; // +2 to survive mine latency
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, minFuture),
            ).to.not.be.reverted;
        });

        it("accepts a deadline exactly at the maximum horizon (365 days)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const maxDeadline = (await time.latest()) + 365 * 24 * 60 * 60;
            await expect(
                registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, maxDeadline),
            ).to.not.be.reverted;
        });
    });

    // =========================================================================
    // Registry Behaviour — claimExists
    // =========================================================================

    describe("claimExists", function () {
        it("returns false for ID 0", async function () {
            const { registry } = await loadFixture(deployFixture);
            expect(await registry["claimExists(uint256)"](0)).to.be.false;
        });

        it("returns false for an uncreated claim ID", async function () {
            const { registry } = await loadFixture(deployFixture);
            expect(await registry["claimExists(uint256)"](999)).to.be.false;
        });

        it("returns true after a claim is created", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            expect(await registry["claimExists(uint256)"](1)).to.be.true;
        });

        it("returns false for a future ID that has not yet been created", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            expect(await registry["claimExists(uint256)"](2)).to.be.false;
        });
    });

    // =========================================================================
    // Registry Behaviour — totalClaims
    // =========================================================================

    describe("totalClaims", function () {
        it("returns 0 before any claims are created", async function () {
            const { registry } = await loadFixture(deployFixture);
            expect(await registry.totalClaims()).to.equal(0);
        });

        it("returns the correct count after several creations", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            for (let i = 0; i < 5; i++) {
                await registry
                    .connect(user)
                    .createClaim(`Claim number ${i + 1} statement`, VALID_CID, deadline);
            }
            expect(await registry.totalClaims()).to.equal(5);
        });
    });

    // =========================================================================
    // Registry Behaviour — getClaim
    // =========================================================================

    describe("getClaim", function () {
        it("returns the full Claim struct with correct fields", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            const claim = await registry.getClaim(1);

            expect(claim.id).to.equal(1n);
            expect(claim.creator).to.equal(user.address);
            expect(claim.statement).to.equal(TYPICAL_STATEMENT);
            expect(claim.evidenceCID).to.equal(VALID_CID);
            expect(claim.status).to.equal(0); // Pending
            expect(claim.verificationDeadline).to.equal(BigInt(deadline));
        });

        it("reverts with ClaimNotFound for a non-existent claim", async function () {
            const { registry } = await loadFixture(deployFixture);

            await expect(registry.getClaim(42))
                .to.be.revertedWithCustomError(registry, "ClaimNotFound")
                .withArgs(42);
        });
    });

    // =========================================================================
    // Registry Behaviour — getClaimCreator
    // =========================================================================

    describe("getClaimCreator", function () {
        it("returns the correct creator address", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            expect(await registry.getClaimCreator(1)).to.equal(user.address);
        });

        it("reverts with ClaimNotFound for a non-existent claim", async function () {
            const { registry } = await loadFixture(deployFixture);

            await expect(registry.getClaimCreator(99))
                .to.be.revertedWithCustomError(registry, "ClaimNotFound")
                .withArgs(99);
        });
    });

    // =========================================================================
    // Registry Behaviour — getClaimStatus
    // =========================================================================

    describe("getClaimStatus", function () {
        it("returns Pending (0) immediately after creation", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            expect(await registry.getClaimStatus(1)).to.equal(0);
        });

        it("reverts with ClaimNotFound for a non-existent claim", async function () {
            const { registry } = await loadFixture(deployFixture);

            await expect(registry.getClaimStatus(7))
                .to.be.revertedWithCustomError(registry, "ClaimNotFound")
                .withArgs(7);
        });
    });

    // =========================================================================
    // Status Updates
    // =========================================================================

    describe("updateClaimStatus", function () {
        it("authorised updater can transition Pending → UnderVerification", async function () {
            const { registry, user, updater } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            await registry.connect(updater).updateClaimStatus(1, 1 /* UnderVerification */);
            expect(await registry.getClaimStatus(1)).to.equal(1);
        });

        it("emits ClaimStatusUpdated with correct args", async function () {
            const { registry, user, updater } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            await expect(registry.connect(updater).updateClaimStatus(1, 2 /* VerifiedTrue */))
                .to.emit(registry, "ClaimStatusUpdated")
                .withArgs(1n, 0 /* Pending */, 2 /* VerifiedTrue */);
        });

        it("reverts with ClaimNotFound for a non-existent claim", async function () {
            const { registry, updater } = await loadFixture(deployFixture);

            await expect(registry.connect(updater).updateClaimStatus(55, 1))
                .to.be.revertedWithCustomError(registry, "ClaimNotFound")
                .withArgs(55);
        });

        it("reverts with InvalidStatusTransition when transitioning to the same status", async function () {
            const { registry, user, updater } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            await expect(
                registry.connect(updater).updateClaimStatus(1, 0 /* Pending → Pending */),
            ).to.be.revertedWithCustomError(registry, "InvalidStatusTransition");
        });

        it("reverts with AccessControlUnauthorizedAccount for an unauthorised caller", async function () {
            const { registry, user, other } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            await expect(
                registry.connect(other).updateClaimStatus(1, 1),
            ).to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount");
        });

        it("supports all ClaimStatus enum values (0–5)", async function () {
            const { registry, user, updater } = await loadFixture(deployFixture);
            const deadline = await futureDeadline();

            // Each iteration creates a fresh claim to test each target status
            for (let targetStatus = 1; targetStatus <= 5; targetStatus++) {
                await registry.connect(user).createClaim(
                    `Claim for status ${targetStatus} testing`,
                    VALID_CID,
                    deadline,
                );
                const claimId = await registry.totalClaims();
                await registry.connect(updater).updateClaimStatus(claimId, targetStatus);
                expect(await registry.getClaimStatus(claimId)).to.equal(targetStatus);
            }
        });
    });

    // =========================================================================
    // Immutability
    // =========================================================================

    describe("Immutability", function () {
        it("claim metadata does not change after a status update", async function () {
            const { registry, user, updater } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            await registry.connect(updater).updateClaimStatus(1, 1); // → UnderVerification

            const claim = await registry.getClaim(1);
            expect(claim.creator).to.equal(user.address);
            expect(claim.statement).to.equal(TYPICAL_STATEMENT);
            expect(claim.evidenceCID).to.equal(VALID_CID);
            expect(claim.verificationDeadline).to.equal(BigInt(deadline));
        });
    });

    // =========================================================================
    // Access Control
    // =========================================================================

    describe("Access Control", function () {
        it("admin can grant REGISTRY_UPDATER_ROLE to a new address", async function () {
            const { registry, admin, other } = await loadFixture(deployFixture);

            const REGISTRY_UPDATER_ROLE = await registry.REGISTRY_UPDATER_ROLE();
            await registry.connect(admin).grantRole(REGISTRY_UPDATER_ROLE, other.address);
            expect(await registry.hasRole(REGISTRY_UPDATER_ROLE, other.address)).to.be.true;
        });

        it("admin can revoke REGISTRY_UPDATER_ROLE", async function () {
            const { registry, admin, updater, REGISTRY_UPDATER_ROLE } =
                await loadFixture(deployFixture);

            await registry.connect(admin).revokeRole(REGISTRY_UPDATER_ROLE, updater.address);
            expect(await registry.hasRole(REGISTRY_UPDATER_ROLE, updater.address)).to.be.false;
        });

        it("anyone can call createClaim (permissionless creation)", async function () {
            const { registry, other } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await expect(
                registry.connect(other).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline),
            ).to.not.be.reverted;
        });
    });

    // =========================================================================
    // Gas Benchmarks
    // =========================================================================

    describe("Gas Benchmarks", function () {
        it("measures gas for first claim creation", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            const tx = await registry
                .connect(user)
                .createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);
            const receipt = await tx.wait();

            const gasUsed = receipt!.gasUsed;
            console.log(`\n  ┌─ Gas Benchmarks ─────────────────────────────────────`);
            console.log(`  │  First claim creation:       ${gasUsed.toString()} gas`);

            // Sanity bounds: should be between 80k and 300k gas
            expect(gasUsed).to.be.greaterThan(80_000n);
            expect(gasUsed).to.be.lessThan(300_000n);
        });

        it("measures gas for subsequent claim creation (warm storage)", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            // First claim — cold
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            // Second claim — counter slot is warm
            const tx = await registry
                .connect(user)
                .createClaim(TYPICAL_STATEMENT + " v2", VALID_CID, deadline);
            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed;

            console.log(`  │  Subsequent claim creation:  ${gasUsed.toString()} gas`);
            expect(gasUsed).to.be.greaterThan(60_000n);
            expect(gasUsed).to.be.lessThan(300_000n);
        });

        it("measures gas for getClaim view call", async function () {
            const { registry, user } = await loadFixture(deployFixture);

            const deadline = await futureDeadline();
            await registry.connect(user).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);

            const gasEstimate = await registry.getClaim.estimateGas(1);
            console.log(`  │  getClaim view estimate:     ${gasEstimate.toString()} gas`);
            console.log(`  └────────────────────────────────────────────────────────\n`);

            expect(gasEstimate).to.be.lessThan(50_000n);
        });
    });
});

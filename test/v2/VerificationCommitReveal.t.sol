// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {VerificationCommitReveal} from "../../contracts/v2/VerificationCommitReveal.sol";
import {SignatureNonces} from "../../contracts/v2/SignatureNonces.sol";
import {V2ReplayDomain} from "../../contracts/v2/libraries/V2ReplayDomain.sol";

/// @title VerificationCommitRevealTest
/// @notice PREWAVE-SC-085 evidence: a commitment settles once; duplicate, conflicting, wrong-field
///         and replayed reveals are rejected and leave state untouched.
contract VerificationCommitRevealTest is Test {
    VerificationCommitReveal internal cr;

    uint256 internal constant VERIFIER_PK = 0xA11CE;
    address internal verifier;
    address internal other = address(0xBEEF);
    address internal relayer = address(0xCAFE);

    uint256 internal constant CLAIM = 7;
    uint256 internal constant ROUND = 1;
    bool internal constant DECISION = true;
    bytes32 internal constant RATIONALE = keccak256("rationale");
    bytes32 internal constant SALT = keccak256("salt");

    function setUp() public {
        cr = new VerificationCommitReveal();
        verifier = vm.addr(VERIFIER_PK);
        vm.warp(1_000);
    }

    // ---- helpers ------------------------------------------------------------------------

    function _commitment(address who, uint256 claimId, uint256 roundId, bool decision, bytes32 rationale, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return cr.computeCommitment(who, claimId, roundId, decision, rationale, salt);
    }

    function _commit() internal returns (bytes32 c) {
        c = _commitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT);
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c);
    }

    function _sign(uint256 pk, bytes32 commitment, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = V2ReplayDomain.digest(
            cr.REVEAL_ACTION(),
            address(cr),
            block.chainid,
            V2ReplayDomain.REPLAY_DOMAIN_VERSION,
            vm.addr(pk),
            uint256(commitment),
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _assertRevealedAsOriginal() internal view {
        VerificationCommitReveal.Record memory rec = cr.getRecord(verifier, CLAIM, ROUND);
        assertEq(uint8(rec.status), uint8(VerificationCommitReveal.Status.Revealed));
        assertEq(rec.decision, DECISION);
        assertEq(rec.rationaleHash, RATIONALE);
    }

    // ---- happy path ---------------------------------------------------------------------

    function test_CommitThenRevealSettles() public {
        bytes32 c = _commit();
        vm.prank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);

        VerificationCommitReveal.Record memory rec = cr.getRecord(verifier, CLAIM, ROUND);
        assertEq(uint8(rec.status), uint8(VerificationCommitReveal.Status.Revealed));
        assertEq(rec.commitment, c);
        assertEq(rec.decision, DECISION);
        assertEq(rec.rationaleHash, RATIONALE);
    }

    // ---- same reveal / settles once -----------------------------------------------------

    function test_SameRevealTwiceReverts() public {
        _commit();
        vm.startPrank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);
        vm.expectRevert(VerificationCommitReveal.AlreadyRevealed.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);
        vm.stopPrank();
        _assertRevealedAsOriginal();
    }

    // ---- post-settlement: conflicting reveal / re-commit cannot overwrite ----------------

    function test_PostSettlementConflictingRevealCannotOverwrite() public {
        _commit();
        vm.startPrank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);

        vm.expectRevert(VerificationCommitReveal.AlreadyRevealed.selector);
        cr.reveal(CLAIM, ROUND, !DECISION, keccak256("other rationale"), keccak256("other salt"));
        vm.stopPrank();

        _assertRevealedAsOriginal();
    }

    function test_PostSettlementRecommitCannotOverwrite() public {
        bytes32 original = _commit();
        vm.startPrank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);

        bytes32 other2 = _commitment(verifier, CLAIM, ROUND, !DECISION, RATIONALE, SALT);
        vm.expectRevert(VerificationCommitReveal.CommitmentAlreadyExists.selector);
        cr.commit(CLAIM, ROUND, other2);
        vm.stopPrank();

        assertEq(cr.getRecord(verifier, CLAIM, ROUND).commitment, original);
        _assertRevealedAsOriginal();
    }

    function test_CommitBeforeRevealCannotBeReplaced() public {
        bytes32 original = _commit();
        bytes32 replacement = _commitment(verifier, CLAIM, ROUND, !DECISION, RATIONALE, SALT);
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentAlreadyExists.selector);
        cr.commit(CLAIM, ROUND, replacement);
        assertEq(cr.getRecord(verifier, CLAIM, ROUND).commitment, original);
    }

    // ---- changed fields -----------------------------------------------------------------

    function test_ChangedDecisionReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, !DECISION, RATIONALE, SALT);
    }

    function test_ChangedRationaleReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, DECISION, keccak256("changed"), SALT);
    }

    // ---- wrong salt / verifier / round --------------------------------------------------

    function test_WrongSaltReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, keccak256("wrong salt"));
    }

    function test_ZeroSaltReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.ZeroSalt.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, bytes32(0));
    }

    function test_WrongVerifierReverts() public {
        _commit();
        vm.prank(other);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);
    }

    function test_WrongRoundReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM, ROUND + 1, DECISION, RATIONALE, SALT);
    }

    function test_WrongClaimReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM + 1, ROUND, DECISION, RATIONALE, SALT);
    }

    function test_RevealWithoutCommitReverts() public {
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);
    }

    function test_ZeroCommitmentReverts() public {
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.ZeroCommitment.selector);
        cr.commit(CLAIM, ROUND, bytes32(0));
    }

    // ---- failed reveal leaves commitment intact -----------------------------------------

    function test_FailedRevealLeavesCommitmentIntact() public {
        bytes32 c = _commit();

        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, !DECISION, RATIONALE, SALT);

        VerificationCommitReveal.Record memory rec = cr.getRecord(verifier, CLAIM, ROUND);
        assertEq(uint8(rec.status), uint8(VerificationCommitReveal.Status.Committed));
        assertEq(rec.commitment, c);

        // the honest reveal still works afterwards
        vm.prank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);
        _assertRevealedAsOriginal();
    }

    // ---- events -------------------------------------------------------------------------

    function test_CommittedEventCarriesOnlyTheHash() public {
        bytes32 c = _commitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT);
        vm.expectEmit(true, true, true, true, address(cr));
        emit VerificationCommitReveal.Committed(verifier, CLAIM, ROUND, c);
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c);
    }

    function test_RevealedEventEmittedOnceAndNeverContainsSalt() public {
        bytes32 c = _commit();
        vm.recordLogs();
        vm.prank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], VerificationCommitReveal.Revealed.selector);
        assertEq(logs[0].data, abi.encode(c, DECISION, RATIONALE));
        // the salt appears nowhere in the event
        assertTrue(keccak256(logs[0].data) != keccak256(abi.encode(SALT)));
        for (uint256 i = 0; i < logs[0].topics.length; i++) {
            assertTrue(logs[0].topics[i] != SALT);
        }
    }

    function test_FailedRevealEmitsNothing() public {
        _commit();
        vm.recordLogs();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, !DECISION, RATIONALE, SALT);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ---- signature (relayed) reveal and replay ------------------------------------------

    function test_SignatureRevealSettlesOnce() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(relayer);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);

        _assertRevealedAsOriginal();
        assertTrue(cr.isNonceUsed(verifier, 1));
    }

    function test_SignatureReplayReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.startPrank(relayer);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);
        vm.expectRevert(VerificationCommitReveal.AlreadyRevealed.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);
        vm.stopPrank();

        _assertRevealedAsOriginal();
    }

    function test_SignatureAfterDirectRevealReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT);

        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.AlreadyRevealed.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);
    }

    function test_SignatureFromWrongSignerReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(0xB0B, c, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.InvalidSignature.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);

        assertFalse(cr.isNonceUsed(verifier, 1));
    }

    function test_SignatureWithTamperedNonceReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.InvalidSignature.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 2, deadline, sig);
    }

    function test_SignatureForOtherRoundCannotBeReused() public {
        bytes32 c = _commit();
        // a second commitment in another round
        bytes32 c2 = _commitment(verifier, CLAIM, ROUND + 1, DECISION, RATIONALE, SALT);
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND + 1, c2);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigRound1 = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.InvalidSignature.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND + 1, DECISION, RATIONALE, SALT, 1, deadline, sigRound1);
    }

    function test_ExpiredSignatureReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 10;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);
        vm.warp(deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.SignatureExpired.selector, deadline));
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);
    }

    function test_CancelledNonceBlocksSignature() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(verifier);
        cr.cancelNonce(1);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.NonceAlreadyUsed.selector, verifier, uint256(1)));
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);

        assertEq(uint8(cr.getRecord(verifier, CLAIM, ROUND).status), uint8(VerificationCommitReveal.Status.Committed));
    }

    function test_MalformedSignatureReverts() public {
        _commit();
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.InvalidSignature.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, hex"1234");
    }

    // ---- fuzz ---------------------------------------------------------------------------

    function testFuzz_AnyChangedFieldFailsAndLeavesStateIntact(
        bool decision2,
        bytes32 rationale2,
        bytes32 salt2
    ) public {
        vm.assume(salt2 != bytes32(0));
        vm.assume(decision2 != DECISION || rationale2 != RATIONALE || salt2 != SALT);
        bytes32 c = _commit();

        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, decision2, rationale2, salt2);

        VerificationCommitReveal.Record memory rec = cr.getRecord(verifier, CLAIM, ROUND);
        assertEq(uint8(rec.status), uint8(VerificationCommitReveal.Status.Committed));
        assertEq(rec.commitment, c);
    }
}

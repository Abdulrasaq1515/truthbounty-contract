// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EIP712CanonicalVectors
/// @notice Solidity mirror of test/vectors/eip712-verifier.vectors.json (V2-SC-152).
/// @dev Test-only constants. Every value is checked against ethers (scripts/check-eip712-vectors.mjs)
///      and against the live EIP712Verifier by test/v2/EIP712CanonicalVectors.t.sol.
///      Do not edit by hand: run `node scripts/check-eip712-vectors.mjs --emit`.
library EIP712CanonicalVectors {
    /// @notice Canonical verifying contract used by every vector (governs the domain separator).
    address internal constant VERIFYING_CONTRACT = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    /// @notice Chain id of the mainnet vectors.
    uint256 internal constant CHAIN_ID_MAINNET = 1;
    /// @notice Chain id of the local/test vectors.
    uint256 internal constant CHAIN_ID_LOCAL = 31337;

    // ---- canonical type strings ----
    string internal constant DOMAIN_TYPE_STRING = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
    string internal constant CLAIM_TYPE_STRING = "ClaimSubmission(address claimant,uint256 bountyId,bytes32 contentHash,uint256 nonce,uint256 deadline)";
    string internal constant VERIFICATION_INTENT_TYPE_STRING = "VerificationIntent(address verifier,uint256 bountyId,bool approve,string reason,uint256 nonce,uint256 deadline)";
    string internal constant MUTATED_CLAIM_TYPE_STRING = "ClaimSubmission(address claimant,uint256 bountyId,bytes32 contentHash,uint8 nonce,uint256 deadline)";

    // ---- adversarial deployment / chain used by the negative vectors ----
    address internal constant WRONG_VERIFYING_CONTRACT = 0x000000000000000000000000000000000000bEEF;
    uint256 internal constant CHAIN_ID_WRONG = 10;

    // ---- type hashes ----
    bytes32 internal constant DOMAIN_TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 internal constant CLAIM_SUBMISSION_TYPE_HASH = 0x583cd3a93ae50e2578ccd80e1f370aebc93e9e7f97bd0e38d39e542213b6e927;
    bytes32 internal constant VERIFICATION_INTENT_TYPE_HASH = 0xc5a057e833163fcd0c5e1783fe90adfb24b27445ca62299745fbddb51869fd69;
    bytes32 internal constant NAME_HASH = 0x2fa99e49f5b52f9531f70c914e05e3b21b20a47ed8412a97840d11b17c33037e;
    bytes32 internal constant VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    // ---- domain separators ----
    bytes32 internal constant DOMAIN_SEPARATOR_MAINNET = 0x3eb1639b71106693914d735157d11474bfdb60ffd5b896fb8311b7a8c9998b11;
    bytes32 internal constant DOMAIN_SEPARATOR_LOCAL = 0x50a672b15211d46ac48525c21fd2b336612308d62a2fcf5aeaffcfea87bce188;

    // ---- positive vectors: struct hashes ----
    bytes32 internal constant CLAIM_MAINNET_STRUCT_HASH = 0xc6398127fdbb4a3bd776eb683a6569078a2cfd1eb0bac2b44714d05a733ee96c;
    bytes32 internal constant CLAIM_LOCAL_STRUCT_HASH = 0x17a0828b8159f7e3fcd9e6e9ac42695948f679c0ea3ff30394ec9bdd5021e2c8;
    bytes32 internal constant INTENT_MAINNET_STRUCT_HASH = 0x815f537bcffdc44868a823f6bd959fe11b90e1641d0c5dc661b85847583fa4f5;
    bytes32 internal constant INTENT_LOCAL_STRUCT_HASH = 0x664ef87190c6c36a5f13dcec98307ee0eacd91d28f94f273735f6c4a9c3b31ed;

    // ---- negative vectors: struct hashes produced by mutated encodings ----
    bytes32 internal constant CLAIM_MUTATED_FIELD_ORDER_STRUCT_HASH = 0x39d6b7f4e2ff1cf7e594d9399a1d3ab4386b774964e5895a0252b7d8888d0dd3;
    bytes32 internal constant CLAIM_MUTATED_TYPE_STRING_STRUCT_HASH = 0x66ff8c8eff5f6f4613d6aaf648d2dd001395f8bb11350ddaa37f3f018160eea2;

    // ---- negative vectors: struct hashes produced by mutated encodings ----
    bytes32 internal constant CLAIM_MAINNET_DIGEST = 0xbb5a29bd1e537284bc2631d86375fd606d16aaf7bb45144fd39eeea665a8cdb7;
    bytes32 internal constant CLAIM_LOCAL_DIGEST = 0x3624b82c760989324db7d91cb30762b0c3dc60f7ec1ecf9b23b864d2ac2e12e3;
    bytes32 internal constant INTENT_MAINNET_DIGEST = 0xc24ae15f7579d0e5dac930fa987581be9895f8648630859ed87edc617f2f498a;
    bytes32 internal constant INTENT_LOCAL_DIGEST = 0x4cb2cda7f6326bad39f733145e9ccec0ffcdaae4b5e8089d3a41c4a68bfb6db6;

    // ---- negative vectors: digests that MUST differ from the positives ----
    bytes32 internal constant CLAIM_WRONG_CHAIN_ID_DIGEST = 0x29a07b0cb851e735e1b24eff7b0c28c10fbddb76740339ed9dd6c98d876bd067;
    bytes32 internal constant CLAIM_WRONG_VERIFYING_CONTRACT_DIGEST = 0x4f19d2936b9d635fc6071bf5ab59f2a3cac27da622a49382fec685f040ad9db8;
    bytes32 internal constant CLAIM_WRONG_DOMAIN_NAME_DIGEST = 0x1f8f2d5d044080f9d17ca414195c6164c4cadaac01c7123ee08fd35b5f66c9f3;
    bytes32 internal constant CLAIM_WRONG_NONCE_DIGEST = 0x29e682d8a3a1700dda7c3b1e8a1c1567b2d0a1a4f3a126cacdaa87e99d8d33d6;
    bytes32 internal constant CLAIM_WRONG_DEADLINE_DIGEST = 0xf2a3dcb9373cc48266a7102813180a56308a019d36ddb6db309684919ee03f8d;
    bytes32 internal constant CLAIM_MUTATED_FIELD_ORDER_DIGEST = 0x24506cb83fd05e41be9f0a7d73dda470e2578c9bcb7f0f4b230a67d5256c57b5;
    bytes32 internal constant CLAIM_MUTATED_TYPE_STRING_DIGEST = 0x019d904b3f6ec16bfa522cd00d39396a635bd2ede8e7b93a4091e6350c340cfd;
    bytes32 internal constant INTENT_WRONG_APPROVE_FLAG_DIGEST = 0x1098e444df7fe0aabe800043494864ccaf11210a27bf36a24d22f6080cfd7090;
    bytes32 internal constant INTENT_WRONG_REASON_DIGEST = 0x862028ada5fec6673a96453d38d7735b6a5937d0983e3d028536132f2edb663e;

    // ---- canonical message payloads (abi-free, human readable) ----
    address internal constant CLAIMANT_A = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant CLAIMANT_B = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant VERIFIER_A = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    uint256 internal constant BOUNTY_ID_A = 42;
    uint256 internal constant BOUNTY_ID_B = 1;
    uint256 internal constant CLAIM_NONCE_A = 7;
    uint256 internal constant CLAIM_NONCE_B = 0;
    uint256 internal constant INTENT_NONCE_A = 3;
    uint256 internal constant INTENT_NONCE_B = 4;
    uint256 internal constant CANONICAL_DEADLINE = 1767225600;
    string internal constant CLAIM_A_CONTENT = "truthbounty:claim:42";
    string internal constant CLAIM_B_CONTENT = "truthbounty:claim:1";
    string internal constant INTENT_A_REASON = "evidence verified";
    string internal constant INTENT_B_REASON = "content hash mismatch";

    function claimAContentHash() internal pure returns (bytes32) {
        return keccak256(bytes(CLAIM_A_CONTENT));
    }

    function claimBContentHash() internal pure returns (bytes32) {
        return keccak256(bytes(CLAIM_B_CONTENT));
    }
}

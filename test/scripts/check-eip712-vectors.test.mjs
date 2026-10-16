import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  buildVectors,
  compareConstants,
  compareDocuments,
  compareImplementations,
  expectedConstants,
  runCheck,
  SUITE,
  VECTORS_PATH,
  CONSTANTS_PATH,
  IMPLEMENTATION_PATHS,
  REPO_ROOT,
} from "../../scripts/check-eip712-vectors.mjs";

/**
 * V2-SC-152 — self-tests for the canonical vector drift check.
 *
 * These run without Foundry and without a network: they prove that the committed JSON, the
 * Solidity constants mirror, and the implementations are all in sync, and that a corrupted
 * mirror/vector is reported as drift with an actionable diff instead of passing silently.
 */

function readImplementationSources() {
  return Object.fromEntries(
    IMPLEMENTATION_PATHS.map((relative) => [relative, readFileSync(resolve(REPO_ROOT, relative), "utf8")])
  );
}

test("committed vectors match a deterministic rebuild", async () => {
  const rebuilt = await buildVectors();
  const committed = JSON.parse(readFileSync(VECTORS_PATH, "utf8"));
  assert.deepEqual(compareDocuments(rebuilt, committed, "vectors"), []);
});

test("solidity constant mirror matches the vectors", async () => {
  const doc = await buildVectors();
  const source = readFileSync(CONSTANTS_PATH, "utf8");
  assert.deepEqual(compareConstants(source, expectedConstants(doc)), []);
});

test("every implementation declares the canonical type strings", () => {
  assert.deepEqual(compareImplementations(readImplementationSources()), []);
});

test("drift in the solidity mirror fails with an actionable diff", async () => {
  const doc = await buildVectors();
  const source = readFileSync(CONSTANTS_PATH, "utf8");
  const corrupted = source.replace(
    /bytes32 internal constant CLAIM_MAINNET_DIGEST = 0x[0-9a-fA-F]{64};/,
    `bytes32 internal constant CLAIM_MAINNET_DIGEST = 0x${"ab".repeat(32)};`
  );
  assert.notEqual(corrupted, source, "fixture must actually change the canonical digest");

  const problems = compareConstants(corrupted, expectedConstants(doc));
  assert.equal(problems.length, 1, problems.join("\n"));
  assert.match(problems[0], /CLAIM_MAINNET_DIGEST/);
  assert.match(problems[0], /expected/);
  assert.match(problems[0], /0xabab/);
});

test("drift in the vector document is reported for the exact field", async () => {
  const doc = await buildVectors();
  const corrupted = JSON.parse(readFileSync(VECTORS_PATH, "utf8"));
  corrupted.positives[0].digest = `0x${"cd".repeat(32)}`;

  const problems = compareDocuments(doc, corrupted, "vectors");
  assert.ok(
    problems.some((problem) => problem.includes("positives[0].digest")),
    `expected a digest drift entry, got: ${problems.join(" | ")}`
  );
});

test("a renamed domain type string in an implementation is reported", () => {
  const sources = readImplementationSources();
  const first = Object.keys(sources)[0];
  sources[first] = sources[first].replace("uint256 chainId", "uint256 chainID");

  const problems = compareImplementations(sources);
  assert.equal(problems.length, 1, problems.join("\n"));
  assert.match(problems[0], new RegExp(first.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(problems[0], /chainId/);
});

test("the full check passes on the committed tree", async () => {
  const doc = await runCheck();
  assert.equal(doc.schema, SUITE);
  assert.ok(doc.positives.length >= 4);
  assert.ok(doc.negatives.length >= 9);
});

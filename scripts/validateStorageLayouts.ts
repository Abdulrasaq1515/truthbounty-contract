/**
 * Storage-layout validation entry point (V2-SC-040 / PREWAVE-SC-014).
 *
 * This module is the single callable surface used by:
 *   - test/ReleaseReadiness.test.ts
 *   - scripts/auditReleaseReadiness.ts
 *   - npm run test:layouts (CI gate)
 *
 * It delegates to generateStorageLayouts.ts (V2-SC-121) which performs the
 * real semantic comparison against the frozen manifest in
 * storage-layouts/manifest.json.
 *
 * Fail-closed contract:
 *   - Missing manifest           -> throws (no silent pass)
 *   - Parse / syntax failure     -> throws with raw error message
 *   - Slot / type mutation       -> throws with field description
 *   - Slot deletion              -> throws listing removed variable
 *   - Incompatible append        -> throws (gap grew or insert before boundary)
 *   - Compatible append-only     -> passes
 *   - Untracked gap contract     -> throws listing contract and file
 *
 * Toolchain pin (PREWAVE-SC-014):
 *   Node 22 (ci.yml setup-node step).
 *   ts-node ^10.9.2 (package.json devDependencies).
 *   TypeScript ^7.0 with "module":"nodenext"/"moduleResolution":"nodenext".
 *
 * Deterministic reproduction (clean checkout):
 *   node --version          # must be >= 22
 *   npm ci
 *   npm run compile         # hardhat compile -- populates artifacts/build-info/
 *   npm run test:layouts    # unit tests then semantic check
 *
 * To regenerate the manifest after a reviewed intentional layout change:
 *   npm run test:layouts:update
 *   git diff storage-layouts/manifest.json   # review the diff carefully
 */

import { checkStorageLayouts } from "./generateStorageLayouts.js";

/**
 * Validate compiled storage layouts against the frozen baseline manifest.
 *
 * Fail-closed: throws on ANY incompatibility rather than returning false,
 * so callers (tests, CI) never accidentally swallow failures.
 *
 * @throws {Error} when:
 *   - The build-info directory is absent (run `npm run compile` first)
 *   - The frozen manifest is absent (run `npm run test:layouts:update` first)
 *   - Any tracked contract has a slot/type/removal incompatibility
 *   - Any concrete contract declares a __gap but is not in TRACKED_CONTRACTS
 */
export async function validateStorageLayouts(): Promise<void> {
  const ok = checkStorageLayouts();
  if (!ok) {
    throw new Error(
      "Storage layout validation failed. " +
      "See the output above for the specific slot/type/removal issue. " +
      "If the change is intentional: npm run test:layouts:update"
    );
  }
}

// ---------------------------------------------------------------------------
// CLI entry point (CJS-compatible; works with ts-node default CJS loader)
// ---------------------------------------------------------------------------

if (typeof require !== "undefined" &&
    typeof module !== "undefined" &&
    require.main === module) {
  validateStorageLayouts()
    .then(() => {
      console.log("Storage layout validation passed.");
      process.exit(0);
    })
    .catch((err: unknown) => {
      console.error(err instanceof Error ? err.message : String(err));
      process.exit(1);
    });
}

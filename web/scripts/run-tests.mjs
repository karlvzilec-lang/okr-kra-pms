// Test runner wrapper for `npm test`.
//
// Why a script instead of `node --test "lib/**/*.test.ts"` inline: a glob that
// is unquoted, shell-expanded, or simply mistyped collects ZERO test files and
// still exits 0 — a green CI that proves nothing. This wrapper discovers the
// files itself (no shell involved), hard-fails when it finds none, and prints
// what it found before running it, so "0 tests" can never read as success.
//
// Kept deliberately lean: discover, count-check, run, propagate the exit code.
//
// This file is .mjs so it is unambiguously ESM regardless of package.json's
// `type` field (which is intentionally left unset — see the Round 8 ruling).
//
// Test files are TypeScript and run under Node's native type stripping, which
// is on by default from Node 22.18 onward. No transpile step, no dependency.

import { readdirSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const searchRoot = path.join(webRoot, "lib");

/** Every `*.test.ts` under lib/, at any depth, as paths relative to web/. */
function discoverTests(dir) {
  const found = [];
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules") continue;
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) {
      found.push(...discoverTests(full));
    } else if (entry.endsWith(".test.ts")) {
      found.push(path.relative(webRoot, full));
    }
  }
  return found;
}

let files = [];
try {
  files = discoverTests(searchRoot).sort();
} catch (error) {
  console.error(`Could not scan ${searchRoot} for test files: ${error.message}`);
  process.exit(1);
}

if (files.length === 0) {
  console.error(
    "No test files found under lib/ matching **/*.test.ts.\n" +
      "Refusing to exit 0: an empty test run is a broken runner, not a pass.",
  );
  process.exit(1);
}

console.log(`Found ${files.length} test file(s):`);
for (const file of files) console.log(`  ${file}`);
console.log("");

const result = spawnSync(process.execPath, ["--test", ...files], {
  cwd: webRoot,
  stdio: "inherit",
});

if (result.error) {
  console.error(`Failed to start the test runner: ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status ?? 1);

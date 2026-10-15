"use strict";

const path = require("path");
const { execSync } = require("child_process");

// INIT_CWD is set by npm to the package root when running lifecycle scripts.
const cwd = process.env.INIT_CWD || process.cwd();
const hooksDir = path.join(cwd, ".githooks");

function run(cmd) {
  return execSync(cmd, { cwd, encoding: "utf8" }).trim();
}

try {
  run("git rev-parse --git-dir");
  // Absolute path so worktrees and subdirectory commits resolve hooks reliably.
  run(`git config --local core.hooksPath "${hooksDir}"`);
  const configured = run("git config --local --get core.hooksPath");
  console.log(`[prepare] core.hooksPath=${configured}`);
} catch (err) {
  const msg = err && err.message ? err.message : String(err);
  console.warn(`[prepare] Skipped enabling git hooks (cwd=${cwd}): ${msg}`);
  console.warn("[prepare] Enable manually: git config --local core.hooksPath .githooks");
}

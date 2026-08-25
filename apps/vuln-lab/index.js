/*
 * apps/vuln-lab — DELIBERATELY VULNERABLE LAB (dependencies AND code).
 *
 * ============================ DO NOT IMPORT ============================
 * This package is NEVER imported by any deployed app (launch-ops,
 * control-tower, mcp-tools, directline-token, cost-ingest) and must never
 * be. It holds the seeds the L10 self-healing pipeline heals:
 *
 *   * three known-vulnerable dependency PINS  -> Dependabot track
 *   * two CodeQL-detectable CODE flaws in seeds/ -> Copilot Autofix track
 *
 * If you find a `require`/`import` of @mls/vuln-lab anywhere in an app, that
 * is a bug — remove it.
 * =======================================================================
 *
 * What this file does: requires each pinned package trivially, so the
 * dependencies are genuinely used (manifest + lockfile stay honest and the
 * upgrade PR has something to build against). It executes NO vulnerable code
 * path — no untrusted input reaches any of these calls, and none of the
 * exploited APIs (JSON5 prototype-polluting parse of attacker JSON, minimist
 * argv proto keys, semver ReDoS ranges) are reachable from anywhere.
 *
 * It also requires the two code seeds, purely to prove they are present and
 * parse — `reseed.ps1` and CI both rely on that. Requiring them builds NOTHING:
 * each module only exports a factory, so no HTTP server is created, no port is
 * bound and no command is ever run. The CodeQL alerts come from static
 * analysis of the source, not from executing it.
 */

"use strict";

const JSON5 = require("json5");
const minimist = require("minimist");
const semver = require("semver");

const reportViewer = require("./seeds/report-viewer.js");
const componentHistory = require("./seeds/component-history.js");

// Fixed, in-repo literals only — never process.argv, never network input.
const parsed = JSON5.parse('{ ok: true }');
const args = minimist(["--seeded", "true"]);
const newer = semver.gt("1.2.3", "1.2.2");

const status = {
  package: "@mls/vuln-lab",
  purpose: "L10 self-healing showpiece seed — never imported by a deployed app",
  json5: parsed.ok === true,
  minimist: args.seeded === "true",
  semver: newer === true,
  // Presence only. Neither factory is called here or anywhere else.
  codeSeeds: {
    "js/path-injection": typeof reportViewer.createReportServer === "function",
    "js/command-line-injection": typeof componentHistory.createHistoryServer === "function",
  },
};

if (require.main === module) {
  console.log(JSON.stringify(status, null, 2));
}

module.exports = status;

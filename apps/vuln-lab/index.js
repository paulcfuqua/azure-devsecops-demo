/*
 * apps/vuln-lab — DELIBERATELY VULNERABLE DEPENDENCY LAB.
 *
 * ============================ DO NOT IMPORT ============================
 * This package is NEVER imported by any deployed app (launch-ops,
 * control-tower, copilot-svc) and must never be. It exists only to hold
 * three known-vulnerable dependency pins so the L10 self-healing pipeline
 * has real Dependabot alerts to heal. If you find a `require`/`import` of
 * @mls/vuln-lab anywhere in an app, that is a bug — remove it.
 * =======================================================================
 *
 * What this file does: requires each pinned package trivially, so the
 * dependencies are genuinely used (manifest + lockfile stay honest and the
 * upgrade PR has something to build against). It executes NO vulnerable code
 * path — no untrusted input reaches any of these calls, and none of the
 * exploited APIs (JSON5 prototype-polluting parse of attacker JSON, minimist
 * argv proto keys, semver ReDoS ranges) are reachable from anywhere.
 */

"use strict";

const JSON5 = require("json5");
const minimist = require("minimist");
const semver = require("semver");

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
};

if (require.main === module) {
  console.log(JSON.stringify(status, null, 2));
}

module.exports = status;

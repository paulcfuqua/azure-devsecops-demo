/*
 * apps/vuln-lab/seeds/component-history.js — DELIBERATELY VULNERABLE CODE SEED.
 *
 * ============================ DO NOT IMPORT ============================
 * This file is NEVER imported by any deployed app (launch-ops, control-tower,
 * mcp-tools, directline-token, cost-ingest) and must never be. It is not built
 * into any container image and no server in this repo ever calls the factory
 * below. It exists for exactly one reason: to give GitHub Copilot Autofix a
 * real CodeQL alert to heal in the L10 self-healing showpiece.
 *
 * If you find a `require`/`import` of @mls/vuln-lab or of this file from an
 * app, that is a bug — remove it.
 * =======================================================================
 *
 * SEEDED FLAW: command injection via a shell-interpolated argument.
 *   CodeQL rule : js/command-line-injection
 *   Query name  : "Uncontrolled command line"
 *   CWE         : CWE-78, CWE-88
 *   Suites      : javascript-code-scanning.qls (DEFAULT),
 *                 javascript-security-extended.qls,
 *                 javascript-security-and-quality.qls  <- what codeql.yml runs
 *
 * WHY IT IS DETECTED. `http.createServer`'s request object is a CodeQL
 * RemoteFlowSource, and the command string passed to `child_process.exec` is a
 * SystemCommandExecution sink. `exec` runs its argument THROUGH A SHELL, so
 * interpolating request data into it lets shell metacharacters out of the data
 * and into the command. There is deliberately no escaping and no allow-list.
 *
 * THIS IS NOT AN EXPLOIT. The command is `git log`, a read-only query any
 * developer runs by hand a dozen times a day, and nothing here constructs,
 * suggests or demonstrates a payload. The flaw is the missing validation on an
 * otherwise mundane endpoint — which is precisely how this class of bug reaches
 * production in real codebases.
 *
 * WHY PLAIN `require("child_process")` AND NOT `require("node:child_process")`.
 * Same reasoning as report-viewer.js: this file's only job is to be recognised
 * by a static analyser, so it uses the specifier form CodeQL has modelled
 * longest. A seed that silently stops being detected wastes an L10 audit
 * attempt (L10 failure mode 4).
 *
 * WHAT AUTOFIX IS EXPECTED TO DO: move to `execFile`/`spawn` with an argument
 * array (no shell), and/or validate `component` against a known set of repo
 * paths. Again small, single-file and local — the profile Autofix handles well.
 *
 * SECOND SEED ON PURPOSE. V10.1 needs one healed CodeQL alert; this lab seeds
 * two because Autofix is documented as non-deterministic and "might fail to
 * produce a viable suggestion". Two independent alerts of two different classes
 * means one declined suggestion does not cost the demo its showpiece.
 */

"use strict";

const http = require("http");
const cp = require("child_process");
const path = require("path");

/** Repo root, resolved from this file. The endpoint reports on repo paths. */
const REPO_ROOT = path.join(__dirname, "..", "..", "..");

/**
 * A small change-history endpoint: GET /history?component=<repo path> returns
 * the last 20 commits that touched that path.
 *
 * The server object is built by this factory and NOTHING in this repository
 * calls it, so no port is ever bound and no command is ever run. CodeQL is a
 * static analyser and reports the flaw regardless.
 */
function createHistoryServer() {
  return http.createServer((req, res) => {
    const component = new URL(req.url, "http://localhost").searchParams.get("component");

    if (!component) {
      res.statusCode = 400;
      res.end("A component path is required.");
      return;
    }

    // Execute git without a shell; pass user input as a single argv element.
    cp.execFile("git", ["log", "--oneline", "-20", "--", component], { cwd: REPO_ROOT }, (error, stdout) => {
      if (error) {
        res.statusCode = 500;
        res.end("Could not read the component history.");
        return;
      }
      res.statusCode = 200;
      res.setHeader("content-type", "text/plain; charset=utf-8");
      res.end(stdout);
    });
  });
}

module.exports = { createHistoryServer, REPO_ROOT };

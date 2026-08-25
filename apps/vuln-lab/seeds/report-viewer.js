/*
 * apps/vuln-lab/seeds/report-viewer.js — DELIBERATELY VULNERABLE CODE SEED.
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
 * SEEDED FLAW: path traversal (directory traversal).
 *   CodeQL rule : js/path-injection
 *   Query name  : "Uncontrolled data used in path expression"
 *   CWE         : CWE-22, CWE-23, CWE-36, CWE-73, CWE-99
 *   Suites      : javascript-code-scanning.qls (DEFAULT),
 *                 javascript-security-extended.qls,
 *                 javascript-security-and-quality.qls  <- what codeql.yml runs
 *
 * WHY IT IS DETECTED. `http.createServer`'s request object is a CodeQL
 * RemoteFlowSource, and the `path` argument of `fs.readFile` is a
 * FileSystemReadAccess sink. The query reports any flow between the two that is
 * not stopped by a recognised sanitizer. There is deliberately no sanitizer
 * here at all: `path.join` COLLAPSES `../` segments, it does not reject them,
 * so `?name=../../package.json` resolves outside REPORTS_DIR. That is the whole
 * bug, and it is an ordinary mistake rather than an exploit — the flaw is the
 * missing containment check, not anything this file does.
 *
 * WHY PLAIN `require("fs")` AND NOT `require("node:fs")`. The rest of this repo
 * prefers the `node:` prefix. Here the file's ONLY job is to be recognised by a
 * static analyser, so it uses the specifier form that every CodeQL version has
 * modelled for the longest. A seed that silently stops being detected would
 * waste an L10 audit attempt (L10 failure mode 4).
 *
 * WHAT AUTOFIX IS EXPECTED TO DO: resolve the joined path and assert it stays
 * inside REPORTS_DIR (or switch to an allow-list of known report names), then
 * 403/404 otherwise. That fix is small, single-file and local — the profile
 * Autofix handles well, which is why this flaw was chosen over a multi-file
 * data-flow bug (L10 failure mode 1).
 */

"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");

/** Canned launch reports the ops team browses. Real directory, boring content. */
const REPORTS_DIR = path.join(__dirname, "reports");

/**
 * A small report browser: GET /report?name=<file> returns one canned report.
 *
 * The server object is built by this factory and NOTHING in this repository
 * calls it, so no port is ever bound and no request is ever served. CodeQL is a
 * static analyser and reports the flaw regardless — which is exactly the
 * property that lets this lab hold a live alert without holding a live risk.
 */
function createReportServer() {
  return http.createServer((req, res) => {
    const requested = new URL(req.url, "http://localhost").searchParams.get("name");

    if (!requested) {
      res.statusCode = 400;
      res.end("A report name is required.");
      return;
    }

    // ---- SEEDED FLAW (js/path-injection) ----------------------------------
    // `requested` is attacker-controlled and reaches the filesystem read with
    // no check that the result is still inside REPORTS_DIR.
    const reportPath = path.join(REPORTS_DIR, requested);

    fs.readFile(reportPath, "utf8", (error, body) => {
      if (error) {
        res.statusCode = 404;
        res.end("No such report.");
        return;
      }
      res.statusCode = 200;
      res.setHeader("content-type", "text/plain; charset=utf-8");
      res.end(body);
    });
    // ---- end seeded flaw ---------------------------------------------------
  });
}

module.exports = { createReportServer, REPORTS_DIR };

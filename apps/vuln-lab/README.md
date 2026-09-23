# @mls/vuln-lab

> ## ⚠️ This lab is no longer LOAD-BEARING. It is not being removed, and re-arming is allowed.
>
> *This replaces a banner that said the package was being removed and that re-arming is
> F190. Both were wrong.* The sponsor-approved design of 2026-09-05 —
> `docs/superpowers/specs/2026-09-05-operationalize-self-healing-design.md` **section 7**,
> merged as PR #237 — says this package and `reseed.ps1` **stay in the repository** and
> stop being load-bearing. *(It named `.github/workflows/vuln-lab-witness.yml` too; that
> file and the container app it stamped were deleted later the same day by PR #255 — see
> the last section.)* **No criterion depends on them**, and **F190 dissolves**: re-arming was a
> loop because the verification *required* it every cycle, not because the act itself is
> wrong.
>
> What it is now: a **manual demonstration generator**. Arming it is a rare, deliberate act
> a human authorises with `--admin` and a stated reason — the right posture for
> reintroducing a critical vulnerability — when the queue is empty, when showing the chain
> to an audience, or when testing a change to the pipeline itself. The administrator
> override is the safety property, not the obstacle: a pull request reintroducing a critical
> alert cannot merge past code scanning protection unless a human chooses to bypass it.
>
> **The three seeded pins stay, deliberately.** The chain otherwise runs on real findings in
> real deployed applications, and a quiet week with no real findings would leave it
> unexercised and rotting unnoticed. This is what a quiet week is exercised with.
>
> The one thing arming is never for: manufacturing a subject so a criterion has something to
> pass on. If a validation fails, fix the stage and let the chain re-run against the next
> real finding.

> ## ⚠️ This package is deliberately vulnerable. It is NEVER imported by any deployed app.
>
> Nothing in `launch-ops`, `control-tower`, `mcp-tools`, `directline-token` or
> `cost-ingest` may depend on `@mls/vuln-lab`, and it is not built into any
> container image. It exists only to hold the seeds the L10 self-healing
> pipeline heals. A `require`/`import` of this package — or of anything under
> `seeds/` — from an app is a bug; remove it.

## Purpose — showpiece #3 seed (L10)

The self-healing loop is the demo's third showpiece. Since the 2026-08-24
Copilot Studio amendment it runs on **two tracks**, because GitHub heals the two
finding types with two different mechanisms and
[Copilot Autofix covers CodeQL code-scanning alerts, not Dependabot alerts](https://docs.github.com/en/code-security/code-scanning/managing-code-scanning-alerts/about-autofix-for-codeql-code-scanning):

| Track | Seed | Who writes the fix |
|---|---|---|
| **Code** | 2 CodeQL-detectable flaws in `seeds/` | **Copilot Autofix** |
| **Dependency** | 3 vulnerable dependency pins | **Dependabot security updates** |

Both then ride the identical L9 gauntlet (CodeQL, tests, Trivy, ZAP) →
auto-merge on green → deploy → alert closed.

This lab contains **vulnerable dependencies and deliberately unsafe code paths,
not exploit code** (spec F5). Nothing here constructs, demonstrates or ships a
payload; the flaws are ordinary missing-validation mistakes.

---

## Part 1 — the seeded code flaws (Autofix track)

Before this existed `vuln-lab` seeded only dependency CVEs, so the Autofix track
had nothing to act on — the amendment names that gap explicitly. Two flaws now
live under `seeds/`.

| File | CodeQL rule | Query name | CWE |
|---|---|---|---|
| `seeds/report-viewer.js` | [`js/path-injection`](https://codeql.github.com/codeql-query-help/javascript/js-path-injection/) | Uncontrolled data used in path expression | CWE-22, CWE-23, CWE-36, CWE-73, CWE-99 |
| `seeds/component-history.js` | [`js/command-line-injection`](https://codeql.github.com/codeql-query-help/javascript/js-command-line-injection/) | Uncontrolled command line | CWE-78, CWE-88 |

### What each flaw is

**`seeds/report-viewer.js` — path traversal.** A report browser serves canned
launch reports: `GET /report?name=<file>`. The `name` parameter is joined onto
`REPORTS_DIR` and read with `fs.readFile` **with no containment check**.
`path.join` *collapses* `../` segments, it does not reject them, so
`?name=../../package.json` resolves outside the reports directory. The bug is
the missing check, and it is one of the most common real-world JavaScript
findings there is.

**`seeds/component-history.js` — command injection.** A change-history endpoint
answers `GET /history?component=<repo path>` by shelling out to `git log`. The
`component` parameter is concatenated into the command string handed to
`child_process.exec`, which runs it **through a shell** — so shell
metacharacters in the parameter escape the data and become command syntax. The
command itself is a read-only `git log`; the flaw is that nothing validates or
escapes the argument, and nothing switches to `execFile` with an argument array.

### Why CodeQL reliably flags them

Both queries are in the **default** CodeQL suite, not only `security-extended`:

```
js/path-injection           -> javascript-code-scanning.qls
                               javascript-security-extended.qls
                               javascript-security-and-quality.qls
js/command-line-injection   -> javascript-code-scanning.qls
                               javascript-security-extended.qls
                               javascript-security-and-quality.qls
```

`.github/workflows/codeql.yml` runs `queries: security-and-quality`, which
includes both — and because they are *also* in `javascript-code-scanning.qls`,
they would fire under GitHub's **default setup** too. That matters twice over:
Copilot Autofix supports fix generation for "a subset of queries included in the
default and security-extended CodeQL query suites for … JavaScript/TypeScript",
and Autofix **validates** its suggestions by re-running CodeQL with the
*code-scanning* suite — so a flaw that lives in that suite is one Autofix can
both fix and confirm.

Each flaw's data flow is the textbook shape the queries are written for:

* **source** — the request object of `http.createServer(...)`, a CodeQL
  `RemoteFlowSource`;
* **sink** — the `path` argument of `fs.readFile` (`FileSystemReadAccess`), and
  the command string of `child_process.exec` (`SystemCommandExecution`);
* **no sanitizer** anywhere between them, deliberately.

Both files use plain `require("fs")` / `require("child_process")` rather than the
`node:`-prefixed specifiers the rest of the repo prefers. These files' only job
is to be recognised by a static analyser, so they use the form CodeQL has
modelled longest. A seed that silently stops being detected would waste an L10
audit attempt (L10 failure mode 4).

### Why they are safe to keep in the repo

* **No server is ever started.** Each module exports a *factory*
  (`createReportServer`, `createHistoryServer`). Nothing in this repository calls
  either one, so no port is ever bound, no file is ever read from a request and
  no command is ever executed. CodeQL is a static analyser and reports the flaws
  from the source regardless — which is exactly what lets this lab hold a live
  alert without holding a live risk.
* **Never in a deployed graph.** `vuln-lab` is deliberately excluded from the
  repo-root `workspaces` list and is not in any Dockerfile.
* **No payload.** Reading a file by name and running `git log` are ordinary
  application code.

### Two flaws, not one

V10.1 needs **one** healed CodeQL alert to pass. This lab seeds two, of two
different classes, because Autofix is documented as non-deterministic and "might
fail to produce a viable suggestion, or the suggestion might vary across
attempts". A second, independent alert means one declined suggestion does not
cost the demo its showpiece. Both will normally produce their own heal PR.

### What Autofix is expected to do

Both fixes are small, single-file and local — the profile Autofix handles well,
which is why these two were chosen over a multi-file data-flow bug (L10 failure
mode 1):

* path traversal → resolve the joined path and assert it stays inside
  `REPORTS_DIR`, or switch to an allow-list of known report names;
* command injection → `execFile`/`spawn` with an argument array (no shell),
  and/or validate `component` against a known set of repo paths.

---

## Part 2 — the seeded dependency advisories (Dependabot track)

The three pins are chosen so that each one:

1. carries a real published advisory that Dependabot and `npm audit` detect;
2. has a patched version available, so the heal has a clean upgrade path; and
3. is fixable **without a major-version bump**, so the patch PR lands green
   instead of breaking the build.

| Package | Pinned (vulnerable) | Advisory | CVE | Severity | First patched |
| --- | --- | --- | --- | --- | --- |
| `json5` | `2.2.0` | [GHSA-9c47-m6qq-7p4h](https://github.com/advisories/GHSA-9c47-m6qq-7p4h) — Prototype Pollution via `parse` | CVE-2022-46175 | high | `2.2.2` |
| `minimist` | `1.2.5` | [GHSA-xvch-5gv4-984h](https://github.com/advisories/GHSA-xvch-5gv4-984h) — Prototype Pollution | CVE-2021-44906 | critical | `1.2.6` |
| `semver` | `7.5.1` | [GHSA-c2qf-rxjj-qqgw](https://github.com/advisories/GHSA-c2qf-rxjj-qqgw) — Regular Expression Denial of Service | CVE-2022-25883 | high | `7.5.2` |

All three are zero-/light-dependency packages, so the audit surface is exactly
these three advisories and nothing else — the demo's alert count is stable and
explainable rather than drifting with transitive churn. **The code seeds add no
dependencies**, so the count stays at 3.

Verify:

```sh
cd apps/vuln-lab
npm install
npm audit          # 3 vulnerabilities (2 high, 1 critical)
```

Upgrading all three to their patched versions yields `found 0 vulnerabilities` —
that is the state a completed dependency heal leaves behind.

## `index.js` — trivial requires only

`index.js` requires each pinned package and calls one harmless API on it with
in-repo literals (`JSON5.parse('{ ok: true }')`, `minimist(["--seeded","true"])`,
`semver.gt("1.2.3","1.2.2")`). **No vulnerable dependency code path is
executed**: no untrusted input, no `process.argv`, no network data reaches any
of them.

It also requires the two code seeds and reports their presence in its status
object, so `npm test` proves they exist and parse. Requiring them builds
nothing — each module only exports a factory.

```sh
npm test   # node index.js — prints a status object, exit 0
```

## ~~Re-arming after a heal~~ — `reseed.ps1` (RETIRED, see the banner; do not run)

A successful heal cycle rewrites the flawed code and upgrades the pins, which
disarms the lab on both tracks. `reseed.ps1` (pwsh 7) restored it. **Recorded for
reference only — do not run any of these.** Letting a healed lab stay healed is now the
correct outcome:

```powershell
pwsh apps/vuln-lab/reseed.ps1            # restore code flaws + pins + lockfile, verify
pwsh apps/vuln-lab/reseed.ps1 -WhatIf    # show what would change
pwsh apps/vuln-lab/reseed.ps1 -SkipAudit # offline: skip the npm audit step
```

In order:

1. **restores each `seeds/<name>.js` from its armed twin `seeds/<name>.js.seed`**
   and verifies the flaw's marker line is back, throwing if it is not;
2. rewrites the dependency block to the vulnerable pins;
3. regenerates `package-lock.json` from them via `npm install --package-lock-only`
   (no packages downloaded);
4. verifies with `npm audit` that all three advisories are back, throwing if any
   is missing.

**How the code restore works, and why it cannot half-succeed.** Autofix edits
`seeds/*.js`. It never touches `seeds/*.js.seed`, and CodeQL does not extract
that extension — so the `.js.seed` twin is an armed original that survives the
very heal it exists to undo, and does not itself raise a duplicate alert.
Restoring is a whole-file copy, not a patch, so it either lands or throws. Step 1
runs **first** and is entirely offline, so `-SkipAudit` (which returns early)
can never leave the code half of the lab disarmed.

A missing `.js.seed` is a hard error, not a warning: a silently unarmed lab
wastes an L10 audit attempt.

The script **never commits or pushes**. Per CLAUDE.md the restored seeds reach
`main` through a normal PR, and it is that merge which re-raises both the
CodeQL alerts and the Dependabot alerts. The L10 playbook references this script
at `apps/vuln-lab/reseed.ps1`.

## Layout

```
index.js                          trivial requires; proves the seeds are present
reseed.ps1                        re-arms BOTH tracks
seeds/
  report-viewer.js                ARMED — js/path-injection
  report-viewer.js.seed           the armed original (not extracted by CodeQL)
  component-history.js            ARMED — js/command-line-injection
  component-history.js.seed       the armed original
  reports/                        a real directory so report-viewer.js is plausible
```

## ~~`mls-vuln-lab-demo-ca` — a witness, not this package~~ — DELETED

**[corrected 2026-09-22] There is no longer a container app named after this lab, and
no `vuln-lab-witness.yml` workflow.** Both were deleted by **PR #255**
(`fix(L10): a pull request that TALKS about an alert did not heal it, and the witness
goes`), because nothing had read the witness since the operations model landed and dead
scaffolding is how someone rediscovers a retired mechanism. `infra/bicep/apps/main.bicep`
declares **five** container apps and none of them is this one; the only surviving trace is
the `vulnLab` key in `infra/bicep/naming.bicep`, whose description still describes the
deleted app.

What the section used to say: L10's audit ended each healing trail with a deploy stage — a
container-app revision timestamped after the heal merged — and `mls-vuln-lab-demo-ca`
(module `vulnLabWitnessApp`) was a container app running a pinned public placeholder
image, ingress disabled, `minReplicas: 0`, whose environment carried the heal's merge
commit.

The guarantees this package makes are unaffected, because they were never about the
witness:

- **no Dockerfile** references this package;
- the pins never reach a running container, so the L9 Trivy CRITICAL gate — the same
  gauntlet every heal PR must pass — never sees them;
- neither seed factory is ever called, so no server is started anywhere.

**What does still exist:** this source directory, its three seeded pins, and the
**3 Dependabot alerts** they raise. Those alerts are excluded from the self-healing
backlog by policy — they are a manual demonstration generator, not queue material — which
is the banner at the top of this file.

## Notes

- Teardown for L10 means *re-arming*, not deleting (master plan §L10) — hence a
  re-seed script rather than a cleanup script.
- Because the pins are exact (not `^`-ranged), `npm audit fix` reports the fix as
  "outside the stated dependency range". That is intentional: the heal must come
  from the pipeline's patch PR, not from a local `audit fix`.
- If a code seed ever stops producing an alert, check first that CodeQL actually
  scanned `apps/vuln-lab/` on the merge commit (`codeql.yml` `paths-ignore` only
  excludes `node_modules`, `dist` and `*.min.js`), then that the marker lines are
  still present — `reseed.ps1` checks the second for you.

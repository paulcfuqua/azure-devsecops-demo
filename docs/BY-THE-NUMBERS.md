# By the Numbers

What it took to make an enterprise Azure environment reproducible — and auditable against
a federal standard — from an empty directory. Re-measured on the
`feat/remediation-and-compliance` tree, **2026-08-28**, on the working tree that became
this file's own commit — still before any tenant exists. The compliance state artifact is
re-collected and committed immediately after, as `.github/workflows/compliance.yml` does
on every push, so the file counts below are one commit older than the tip by design.

> Counts come from `git ls-files` and real test runs, not estimates. Generated lockfiles
> and the three PDF briefs are excluded from every "authored" figure and reported
> separately, because counting 21,978 lines of dependency resolution as authorship would
> flatter the total.

> **The single most important number here is zero.** Zero cloud writes. No `az login` has
> ever run on the machine that produced any of this. Every figure below was measured by
> code reading files on a laptop; none of it was reported by a live Azure, Graph, Fabric
> or GitHub API.

## Headline

| | |
|---|---|
| **Tracked files** | **567** (559 authored + 5 lockfiles + 3 PDF briefs) |
| **Authored lines** | **118,314** |
| **Automated tests** | **2,342 passing, 0 failing** |
| **Verification criteria** | **45** implemented as Verifier audit assertions (V1.1–V11.5), plus **6** more (V12.1–V12.6) that L12 enforces through CI gates rather than a deployed-state audit — a deviation `docs/runbooks/layers/L12.md` states plainly rather than papering over |
| **NIST SP 800-171 requirements rendered** | **110** — of which **0 COMPLIANT**, and that is the honest answer |
| **Commits** | 162 at the point measured |
| **Cloud writes** | **0** |

## Tests: 2,342

| Runner | Scope | Tests |
|---|---|---|
| Pester (PowerShell 7) | bootstrap, Entra, Purview, Fabric, seed, Defender, fuse scripts, the 11 Verifier audits, **and the compliance platform's catalog / collectors / derivation / emitter** | **1,352** |
| Vitest | mcp-tools 329 · data-api 295 · control-tower 98 · spec-renderer 59 · compliance 50 · launch-ops 33 | **864** |
| `node --test` | cost-ingest 84 · directline-token 12 | **96** |
| pytest | data generators, determinism and schema parity | **30** |

**172 of the 559 authored files are test files — 32,408 lines, roughly one line of test
for every 2.7 lines of everything else.** Every cloud call in all 2,342 is mocked; the
suite has never contacted Azure, Graph, Fabric or GitHub.

Two gates sit alongside them and are not counted as "tests" because they are not test
cases: **PSScriptAnalyzer** at Error + Warning across `scripts`, `infra`, `verification`,
`data`, `compliance` and `.github` (**0 findings**), and the **golden-question MCP eval**
(`npm run eval`), which boots the real tool server in-process and answers 10 of 10 pinned
questions through the MCP transport, asserting the advertised tool surface matches the
allowlist exactly in both directions.

## Lines by language

| Language | Files | Lines | What it is |
|---|---|---|---|
| PowerShell (`.ps1`) | 89 | 29,363 | bootstrap, Entra/Purview/Fabric automation, seeding, the 11 audits, the compliance collectors and state emitter, the fuse |
| TypeScript | 129 | 24,091 | MCP tool server (6 tools), data API, providers, telemetry, Functions |
| JSON | 108 | 19,959 | the 110-requirement NIST catalog, manifests, schemas, fixtures, the emitted compliance state |
| Markdown | 57 | 16,683 | brief, specs, plans, 12 layer playbooks, runbooks, the 56-finding security review |
| YAML | 37 | 10,127 | 24 workflows + 3 composite actions + Dependabot |
| TSX | 36 | 4,551 | Fluent UI renderer and three app shells |
| PowerShell modules | 7 | 4,182 | the audit engine, the compliance derivation, Fabric REST client, seed libraries |
| Bicep (+ params) | 21 | 3,508 | landing zone, platform, apps — on Azure Verified Modules |
| HTML | 6 | 1,394 | app shells and nginx templates |
| Python | 14 | 1,363 | deterministic synthetic-data generators |
| JS / MJS | 10 | 943 | validators, seeded CodeQL flaws |
| SQL | 13 | 622 | Azure SQL schema, dependency-ordered |

## Lines by area

| Area | Files | Lines | |
|---|---|---|---|
| `apps/` | 251 | 34,019 | 8 packages: 3 frontends, MCP server, data API, 2 Functions, shared renderer (+ the vulnerable lab) |
| `compliance/` | 96 | 26,096 | the NIST catalog, the assessment register, the 56-finding review, 5 collectors, the derivation, the emitter, the committed state |
| `infra/` | 40 | 12,624 | Bicep, Entra manifest, Purview labels, Fabric REST, Copilot Studio ALM |
| `docs/` | 32 | 11,010 | decision record, specs, plans, 12 playbooks, runbooks |
| `verification/` | 38 | 11,997 | the Verifier's audit engine and 11 layer audits |
| `.github/` | 30 | 9,349 | 24 workflows: layer deploys, per-app CI, DevSecOps chain, self-healing, compliance collection |
| `data/` | 42 | 5,980 | generators, SQL schema, lakehouse loaders |
| `scripts/` | 14 | 5,184 | G0 bootstrap, the `up`/`down` fuse, Defender toggle |

## What the counts don't show

Line totals are a weak proxy for whether a demo survives contact with a stage. Four
numbers say more:

- **43 verification criteria**, each with a named expected value, a bounded propagation
  window, and an audit script that runs read-only under a separate identity. A layer is
  done when an independent auditor says so, not when a deploy exits zero.
- **0 of 110 NIST requirements are `COMPLIANT`, and 95 are `NOT_ASSESSED`.** On an estate
  that has never been deployed, that is the only truthful board there is. The platform is
  built so a human's strongest written claim cannot derive to `COMPLIANT`, and so that no
  blended percentage exists anywhere to paper over the difference.
- **83 security findings** (36 pre-publication, 47 more raised by the first live
  tenant bring-up and the first four real deployments, 2026-08-29/30), each with severity, `file:line`, an attack
  path and a fix — found by reviewing this repository before publishing it, and closed on
  this branch. **All nineteen control records now assert `CLOSED`**, so there are zero
  `GAP` rows on the board — and `CLOSED` still means only "no known open finding", which
  is why the ceiling those rows reach is `PARTIAL` and not `COMPLIANT`. The last one to
  close was F13's seventh workload RBAC grant, which had no principal to be granted to
  until F19 provisioned `apps/cost-ingest` as a real Function App.
- **10 defects caught by re-verifying subagent work** rather than trusting it — including
  a shared audit action that piped every audit through `tee`, so a failing audit could
  never fail its layer, and a Layer 1 criterion that was structurally unpassable.

And two things this repo does **not** have, stated here because a numbers page is exactly
where they would otherwise be quietly missing:

- **No `verification/layer-12-audit.ps1`.** The compliance platform's own criteria are
  enforced by CI gates, not by the Verifier under `mls-verifier` against deployed state.
  `docs/runbooks/layers/L12.md` says so in its Teardown and Deferred-validation sections
  rather than implying a triplet it does not have.
- **1 remaining manual step** at tenant time: authoring the Copilot Studio agent in the
  portal once and exporting it. Everything else — 12 layers, 4 resource groups, the
  lakehouse, the identity estate, the apps, the whole DevSecOps chain — replays from this
  repo.

## Cost of what it builds

| State | Run rate |
|---|---|
| Torn down (steady idle) | **< $5/month** |
| Active demo | **~$0.60–1.20/hour** |
| Kill and rebuild cycle | ~$1–2 |
| LLM usage | Copilot Credits at $0.01, pay-as-you-go, **zero idle** |
| Compliance platform | **$0** to collect (read-only, offline, no tenant); $0 idle for the board (scale-to-zero) |

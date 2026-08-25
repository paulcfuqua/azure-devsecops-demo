# By the Numbers

What it took to make an enterprise Azure environment reproducible from an empty
directory. Measured on the turn-key tree, 2026-08-25 (commit 30), before any tenant
existed.

> Counts come from `git ls-files` and real test runs, not estimates. Generated
> lockfiles are excluded from every "authored" figure and reported separately, because
> counting 21,769 lines of dependency resolution as authorship would flatter the total.

## Headline

| | |
|---|---|
| **Tracked files** | **394** (390 authored + 4 lockfiles) |
| **Authored lines** | **67,105** |
| **Automated tests** | **1,428 passing, 0 failing** |
| **Verification criteria** | **43**, each traced 1:1 from plan → playbook → audit script |
| **Commits** | 30 |
| **Cloud writes** | **0** — no `az login` has ever existed on this machine |

## Tests: 1,428

| Runner | Scope | Tests |
|---|---|---|
| Pester (PowerShell 7) | bootstrap, Entra, Purview, Fabric, seed, Defender, fuse scripts, **the 11 Verifier audits** | **597** |
| Vitest | data-api 292 · mcp-tools 248 · control-tower 77 · spec-renderer 59 · launch-ops 33 | **709** |
| `node --test` | cost-ingest 84 · directline-token 8 | **92** |
| pytest | data generators, determinism and schema parity | **30** |

**90 of the 390 authored files are test files — 19,376 lines, roughly one line of test
for every 2.5 lines of everything else.** Every cloud call in all 1,428 is mocked; the
suite has never contacted Azure, Graph, Fabric or GitHub.

## Lines by language

| Language | Files | Lines | What it is |
|---|---|---|---|
| TypeScript | 120 | 21,716 | MCP tool server, data API, providers, telemetry, Functions |
| PowerShell (`.ps1`) | 56 | 17,092 | bootstrap, Entra/Purview/Fabric automation, seeding, audits, fuse |
| Markdown | 46 | 8,426 | brief, spec, plans, 11 layer playbooks, runbooks |
| YAML | 26 | 7,562 | 22 workflows + 3 composite actions + Dependabot |
| PowerShell modules | 5 | 3,031 | the audit engine, Fabric REST client, seed libraries |
| JSON | 53 | 2,322 | manifests, schemas, fixtures, expectations |
| TSX | 21 | 2,054 | Fluent UI renderer and both app shells |
| Bicep (+ params) | 8 | 1,585 | landing zone, platform, apps — on Azure Verified Modules |
| Python | 14 | 1,363 | deterministic synthetic-data generators |
| SQL | 12 | 525 | Azure SQL schema, dependency-ordered |
| JS / MJS | 7 | 734 | validators, seeded CodeQL flaws, triage tooling |

## Lines by area

| Area | Files | Lines | |
|---|---|---|---|
| `apps/` | 220 | 28,431 | 7 packages: 2 frontends, MCP server, data API, 2 Functions, shared renderer (+ the vulnerable lab) |
| `verification/` | 27 | 8,217 | the Verifier's audit engine and 11 layer audits |
| `.github/` | 28 | 7,931 | 22 workflows: layer deploys, per-app CI, DevSecOps chain, self-healing |
| `infra/` | 28 | 7,120 | Bicep, Entra manifest, Purview labels, Fabric REST, Copilot Studio ALM |
| `data/` | 41 | 5,693 | generators, SQL schema, lakehouse loaders |
| `scripts/` | 14 | 4,661 | G0 bootstrap, the `up`/`down` fuse, Defender toggle |
| `docs/` | 21 | 4,656 | decision record, spec, plans, playbooks, runbooks |

## What the counts don't show

Line totals are a weak proxy for whether a demo survives contact with a stage. Three
numbers say more:

- **43 verification criteria**, each with a named expected value, a bounded propagation
  window, and an audit script that runs read-only under a separate identity. A layer is
  done when an independent auditor says so, not when a deploy exits zero.
- **10 defects caught by re-verifying subagent work** rather than trusting it — including
  a shared audit action that piped every audit through `tee`, so a failing audit could
  never fail its layer, and a Layer 1 criterion that was structurally unpassable.
- **1 remaining manual step** at tenant time: authoring the Copilot Studio agent in the
  portal once and exporting it. Everything else — 11 layers, 4 resource groups, the
  lakehouse, the identity estate, the apps, the whole DevSecOps chain — replays from
  this repo.

## Cost of what it builds

| State | Run rate |
|---|---|
| Torn down (steady idle) | **< $5/month** |
| Active demo | **~$0.60–1.20/hour** |
| Kill and rebuild cycle | ~$1–2 |
| LLM usage | Copilot Credits at $0.01, pay-as-you-go, **zero idle** |

# Phase P — Pre-Tenant Scaffold: Completion Report

**Date:** 2026-08-24 · **Status:** complete · **Cloud writes: zero** (no `az login` has
ever existed on this host; the mock-only rule held by construction, not just by policy)

220 tracked files across 15 commits. Every track was authored by a subagent, then its
validation was **re-run independently by the Orchestrator** before commit — a report of
"green" was never sufficient.

## Track results

| Track | Deliverable | Validation (re-run independently) |
|---|---|---|
| A | Synthetic data platform — 10 tables, deterministic seed `20260822` | 25 pytest green; launches = 1,200; Saturday argmax at 1.7× runner-up; referential integrity; determinism by output hash |
| B | `@mls/spec-renderer` — JSON Schema + fixed Fluent UI v9 renderer | 59 vitest green (46 → 59 after P-5); build clean |
| C | G0 bootstrap + Entra/Purview/Fabric governance scripts | Pester 89/89 under pwsh 7; PSScriptAnalyzer 0 findings on shipping scripts |
| D | 11 layer playbooks + demo script + kill/rebuild runbook | 40 master-plan Verify criteria traced 1:1; zero placeholders |
| E | Bicep/AVM tree — landing zone, platform, apps | `bicep build` + `build-params` clean on all layers; cost discipline asserted in compiled ARM |
| F1 | `launch-ops` + `control-tower` in local data mode; npm workspace root | 121 tests green across 4 packages; both apps browsed live rendering real generated data |
| F2 | `copilot-svc` (5-tool loop, real SQL, spec-validated) + `vuln-lab` CVE seed | 29 tests + 10/10 golden-question eval; `npm audit` exactly 3 advisories |
| G | 17 workflows + 3 composite actions + Dependabot + triage script | actionlint 1.7.12 clean with shellcheck active; canary-tested; 21 YAML files parse |
| H | Local toolchain | Bicep 0.46.1, az CLI 2.89.1 (not logged in), pwsh 7.6.5, Graph 2.39, Pester 6.1 |

## Defects caught by independent verification

Three that a self-report would have carried into the demo:

1. **vuln-lab CVE seed silently defeated** (P-6, closed). npm workspace hoisting resolved
   `json5` to the *patched* 2.2.3 over the pinned 2.2.0, so only 2 of 3 seeded CVEs
   surfaced. The authoring agent had tested in an isolated copy where the pin held.
   Fixed by narrowing `workspaces` to exclude `apps/vuln-lab` — which also enforces the
   rule that the vulnerable package never enters a deployed dependency graph.
2. **AVM container-app default `minReplicas: 3`.** Verified against compiled ARM rather
   than source: our templates do override it to 0 on all three apps. Had they not, the
   "scale-to-zero everywhere" cost principle would have been violated invisibly.
3. **Spec validation implemented twice** (P-5, closed). The gate that stops the copilot
   emitting UI code existed as two separate implementations. Now one: a UI-free
   `@mls/spec-renderer/validate` subpath, proven DOM-free by import-graph test (with a
   control group), bundle grep, and a real Node-process load.

Two more were caught by agents inside their own work and are worth recording: `LOCAL_DATA=1`
would have silently failed in production builds (Vite `define` only rewrites literal
`import.meta.env.X`), and chart date buckets rendered a day early west of Greenwich.

## What is demoable today, with no Azure and no credentials

- Both frontends run locally against the generated dataset (`npm run dev:launch-ops`,
  `npm run dev:control-tower`).
- The copilot answers its golden questions end to end — real SQL over the data, output
  validated against the renderer schema — via the deterministic mock driver. Supplying
  `ANTHROPIC_API_KEY` switches the same path to the live model with no code change.
- The self-heal triage script runs against a synthetic alert payload and produces its
  verdict artifacts.

## Open items carried into the cloud phase

Tracked in `docs/superpowers/plans/2026-08-22-phase-p-pre-tenant-scaffold.md`:
P-1 (container ports still on placeholder 80), P-2 (NIST assignment identity), P-3 (Key
Vault purge/recover behaviour), P-4 (honoured in CI; verify on first ubuntu run), P-7
(Dockerfiles unproven until CI builds them — no Docker on this host).
**Closed:** P-5, P-6.

## Not done, by design

The public GitHub repo has **not** been created or pushed — publishing is outward-facing
and is the sponsor's call. Everything needed for it is authored and validated locally.
All `verification/layer-NN-audit.ps1` scripts remain unwritten; the workflows call them
defensively (skip-with-notice) and they are the Verifier's first task once the tenant is
live.

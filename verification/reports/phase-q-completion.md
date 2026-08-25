# Phase Q — Turn-Key: Completion Report

**Date:** 2026-08-25 · **Status:** complete · **Cloud writes: zero** (no tenant, no
`az login` has ever existed on this host — the mocks-only rule held by construction)

29 commits, 393 tracked files. Seven tracks (A, B, C, D, V, W, X), each authored by a
subagent and then **independently re-verified by the Orchestrator before commit**. A
subagent's "green" was never sufficient, and that policy paid for itself repeatedly
(§3).

## 1. Gates, as measured on the final tree

| Gate | Result |
|---|---|
| actionlint (shellcheck active, proven by an injected SC2086) | **22 workflows, 0 findings** |
| Bicep `build` + `build-params` | **clean, all 3 layers** |
| PSScriptAnalyzer over `scripts`, `infra`, `data`, `verification`, `.github` | **0 findings at every severity** |
| Pester | **597 passed / 0 failed** |
| pytest (`data/`) | **30 passed** |
| npm workspaces | **green across 7 packages** |
| Dependabot coverage | 9 npm directories, all real; every real package covered (checked both directions) |

## 2. What Phase Q closed

| # | Gap | Closed by |
|---|---|---|
| Q-1 | `verification/` had **zero** audit scripts | `MlsAudit.psm1` + 11 layer audits, all 43 criteria, exact id parity |
| Q-2 | The five MCP tools' cloud adapters were stubs | Real adapters + the SQLite→T-SQL dialect port |
| Q-3 | No `data/seed/`, not one `.sql` file | 12-file T-SQL schema, lakehouse loaders, one `seed.ps1` |
| Q-4 | Both apps' `ApiProvider` fetched routes nothing served | `apps/data-api` + the same-origin `/api` nginx proxy |
| Q-5 | No OpenTelemetry anywhere | Traces/metrics in data-api, mcp-tools and both frontends |
| Q-6 | Cost-export ingestion unwritten | `apps/cost-ingest` |
| Q-7 | Fabric teardown and the fuse scripts missing | `teardown-items.ps1`, `up.ps1`, `down.ps1` |
| Q-8 | Autofix had nothing to act on | Two CodeQL-detectable seeds with verified rule ids |
| Q-9 | `eval:agent` was a placeholder | Real Direct Line driver |
| — | Audits existed but nothing invoked them | Every layer workflow now runs its audit as `mls-verifier`, exit code gating the layer |
| — | L9 had no workflow at all | `layer-09-devsecops.yml` + `toggle-containers-plan.ps1` |

## 3. Defects independent verification caught

Ordered by what they would have cost on tenant day.

1. **The layer-audit action could not fail a layer.** It piped each audit through `tee`,
   so the pipeline's exit code decided the step — and `ran=true` was never written on
   failure, so the report artifact was skipped exactly when someone needed it.
2. **L1's audit could never have passed.** V1.1 reads the latest `infra-up` run's
   conclusion, which is `null` from inside that same run. Moved to `workflow_run`.
3. **`data-api` was not in the Bicep at all.** Both dashboards would have deployed and
   rendered empty against a service nothing provisioned.
4. **`/api` returned HTML.** Both providers default to a same-origin `/api`; each
   frontend's nginx had only an asset rule and an SPA fallback.
5. **The Verifier's SQL helper passed a null access token.** Against Entra-only auth on a
   Linux runner, V5.3 and V8.2 could only ever fail — for a reason unrelated to the estate.
6. **npm hoisting silently patched the seeded CVEs**, so only 2 of 3 existed.
7. **An AVM default of `minReplicas: 3`** — checked against compiled ARM, not source;
   our override holds, but the "scale-to-zero everywhere" promise was one default away.
8. **A test passed only because a module happened to be installed** — and in failing,
   called Microsoft Graph for real, in a suite whose defining rule is zero live calls.
9. **`sbom.yml` still scanned a deleted package**, failing every future L9 run.
10. **`dependabot.yml` declared a deleted directory** and covered none of the four
    services added since.

Agents also caught these inside their own work, which is worth recording: OTel spans
dropped on `shutdown()` (on a scale-to-zero app almost every batch dies in a SIGTERM —
the Ops tab would have been empty), `LOCAL_DATA=1` silently ignored in production
builds, chart buckets a day early west of Greenwich, a PowerShell `$item`/`$Item`
collision that would have loaded every SQL column as NULL, and a batch splitter that
did not split CRLF.

## 4. Two decisions worth re-reading later

**The SQL dialect follows the backend; the agent's SQL is never rewritten.** Translating
would have made the model's errors unattributable and the Verifier's re-derivation
unauditable. `DATEFIRST` is pinned *and probed* against a known Saturday, because the
docs are contradictory about whether the setting is even in the endpoint's surface area.

**The vulnerable lab is not deployed; a witness carries the evidence.** Containerising
`vuln-lab` would have failed the same L9 Trivy CRITICAL gate that every heal PR must
pass green — the Autofix track would have gone red every time. The audit was made
*stronger* rather than weaker: a revision appearing after the merge no longer counts;
it must carry `MLS_HEAL_COMMIT` equal to that PR's merge commit.

## 5. What remains for tenant day

**Human-only:** the G0 checklist (`docs/runbooks/g0-bootstrap.md`), populating the `demo`
environment variables and secrets, and the one unavoidable manual step — authoring the
Copilot Studio agent in the portal once and exporting it, after which it is
repo-managed like everything else.

**Parked sponsor decisions:** MCP server auth (API key interim vs OAuth 2.0/Entra
target — never None); `SELF_HEAL_TOKEN`, without which `GITHUB_TOKEN`-authored PRs land
approval-required and auto-merge-on-green cannot fire unattended; and whether to buy a
paid F2 so the Fabric connected agent is available (the tools-only MCP path demos the
same questions without it).

**Cannot be proven locally:** the Dockerfiles (no Docker on this host), the witness app's
ARM acceptance, V9.1's admin-scoped GHAS reads, and anything needing a live staging URL.

Then: `scripts/up.ps1`.

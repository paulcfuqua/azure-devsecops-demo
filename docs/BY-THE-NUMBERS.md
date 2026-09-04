# By the Numbers

What this estate is, measured on **2026-09-03**. Repository counts come from
`git ls-files` and real test runs; estate counts come from live Azure, Graph, Fabric and
GitHub APIs.

Nothing here is an estimate, and nothing is rounded in the flattering direction.

## Headline

| | |
|---|---|
| **Automated tests** | **2,719 passing, 0 failing** |
| **Tracked files** | **639** |
| **Authored lines** | **148,199** |
| **Verification criteria** | **57**, each run read-only by a separate identity |
| **Azure resources** | **30**, across 4 resource groups in 1 region |
| **Resources after a destroy and rebuild** | **30** — identical, twice over |
| **Workflows** | **24** |
| **NIST SP 800-171 requirements rendered** | **110** — of which **0 are machine-verified**, and that is the honest answer |

## Tests: 2,719

| Runner | Scope | Tests |
|---|---|---|
| Pester (PowerShell 7) | bootstrap, Entra, Purview, Fabric, seed, Defender, the fuse, the 12 Verifier audits, and the compliance catalog / collectors / derivation / emitter | **1,652** |
| Vitest | mcp-tools, data-api, control-tower, compliance, launch-ops, spec-renderer | **927** |
| `node --test` | cost-ingest, directline-token | **110** |
| pytest | data generators, determinism and schema parity | **30** |

Every cloud call in all of them is mocked; the suite has never contacted Azure, Graph,
Fabric or GitHub. Two gates sit alongside and are not counted as tests, because they are
not test cases: **PSScriptAnalyzer** at Error + Warning across `scripts`, `infra`,
`verification`, `data`, `compliance` and `.github` (**0 findings**), and **actionlint**
across all 24 workflows (**clean**).

## The rebuild, measured

The claim this repository exists to make, with a stopwatch on it.

| | |
|---|---|
| Teardown | **~14 minutes**, twice, identical |
| Rebuild | **87 minutes** for the full layer-ordered run |
| — deploy work inside that | **~30 minutes** |
| — verification inside that | **~84 minutes** |
| Resources before / after | **30 / 30**, same names, same ingress shape |
| Container Apps domain | regenerates on every rebuild, so no stored FQDN survives one |
| Managed identities | all recreated with **new principal ids** — so anything keyed on one must be re-derived, never remembered |

**The estate deploys in about half an hour and takes three times that to verify.** That
ratio is the point rather than an embarrassment: the deploys are Bicep and they are fast;
the audits wait on real propagation, real scale-in cycles and real cost-export windows,
because a criterion that does not wait is a criterion that guesses.

## Lines by area

| Area | Files | Lines | |
|---|---|---|---|
| `apps/` | 263 | 43,765 | 8 packages: 3 frontends, MCP server, data API, 2 Functions, shared renderer (+ the vulnerable lab) |
| `docs/` | 43 | 30,711 | brief, specs, 12 layer playbooks, runbooks, the finding register |
| `compliance/` | 96 | 28,574 | the NIST catalog, the assessment register, 5 collectors, the derivation, the emitter, the committed state |
| `verification/` | 48 | 21,325 | the audit engine and 12 layer audits |
| `infra/` | 83 | 16,383 | Bicep, Entra manifest, Purview labels, Fabric REST, Copilot Studio ALM |
| `.github/` | 32 | 13,474 | layer deploys, per-app CI, the DevSecOps chain, self-healing, compliance collection |
| `data/` | 42 | 6,445 | generators, SQL schema, lakehouse loaders |
| `scripts/` | 15 | 5,917 | bootstrap, the `up`/`down` fuse, the Defender toggle |

## What the counts do not show

Line totals are a weak proxy for whether a demo survives contact with a stage. Four
numbers say more.

**57 verification criteria**, each with a named expected value, a declared waiting window,
and an audit script that runs read-only under a separate identity. A layer is done when an
independent auditor says so, not when a deploy exits zero.

**0 of 110 NIST requirements are machine-verified**, and 94 are `NOT_ASSESSED`. Sixteen
carry a human assertion and render as `asserted`. The platform is built so that a human's
strongest written claim *cannot* derive to `COMPLIANT`, and so that no blended percentage
exists anywhere to paper over the difference — CI greps the emitted bytes to keep it that
way.

**Three criteria are currently red or unproven, stated here rather than discovered later.**
V6.2 (a KQL query as the read-only identity) and V8.4 (every visual answer an Adaptive
Card) fail on the current estate. V8.2 records SKIP because the Verifier cannot
independently re-derive the agent's numbers without a Fabric role it deliberately does not
hold. Three honest reds among fifty-seven, visible in the same table as the greens.

**The self-healing chain completed end to end on 2026-09-04, for the first time.** A
seeded CodeQL flaw in `apps/vuln-lab` → Copilot Autofix wrote the patch → PR #226 → an
18-check gauntlet → auto-merge → a new container app revision stamped with that merge
commit → the alert closed. Seven stages, each read from a different API, 74 seconds from
merge to closed alert.

It had never run before because it *could not*: the workflow's lane picker had no
`schedule` arm, so on every scheduled run since the repository was created the Autofix job
was skipped and V10.1 was structurally unreachable rather than failing. Three more defects
were stacked behind it, each hidden by the one in front. Nothing was red — a skipped job is
not a failed one — and the runs went green on the lane they did take. What surfaced it was
a human reading a notification and asking why the job named after the product said
"Skipped". That is the honest version of how this repository's hardest bugs get found, and
it belongs beside the counts.

**Azure spend is $14.74 month-to-date, and one idle database is 99% of it.** Not the
container apps, not the Functions, not the lakehouse — the serverless SQL instance, which
auto-pauses after an hour and wakes on the next query. The number a planner should carry is
that the compute is effectively free and the database is the bill.

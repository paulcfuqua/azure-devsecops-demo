# By the Numbers

What this estate is. **Repository counts were re-measured on 2026-09-22** from `git ls-files`
and real test runs; **estate counts date from the 2026-09-03 rebuild** unless a row says
otherwise, and come from live Azure, Graph, Fabric and GitHub APIs.

Nothing here is an estimate, and nothing is rounded in the flattering direction.

## Headline

| | |
|---|---|
| **Automated tests** | **3,097 passing, 0 failing** |
| **Tracked files** | **691** |
| **Committed lines** | **239,831** — see the note under "Lines by area"; 97,221 of them are machine-written compliance state |
| **Verification criteria** | **65**, each run read-only by a separate identity |
| **Azure resources** | **30**, across 4 resource groups in 1 region |
| **Resources after a destroy and rebuild** | **30** — identical, twice over |
| **Workflows** | **23** |
| **NIST SP 800-171 requirements rendered** | **110** — of which **0 are machine-verified**, and that is the honest answer |

## Tests: 3,097

| Runner | Scope | Tests |
|---|---|---|
| Pester (PowerShell 7) | bootstrap, Entra, Purview, Fabric, seed, Defender, the fuse, the 12 Verifier audits, and the compliance catalog / collectors / derivation / emitter | **1,908** |
| Vitest | mcp-tools (442), data-api (309), control-tower (140), spec-renderer (59), compliance (50), launch-ops (34) | **1,034** |
| `node --test` | cost-ingest (84), directline-token (26) | **110** |
| pytest | data generators, determinism and schema parity | **45** |

*Counted 2026-09-22.* Pester comes from the last green `lint-ci` run on `main`
(1,908 passed / 0 failed / 1 skipped); the rest from `npm test` and `python -m pytest -q`
locally, which is the same per-workspace invocation CI uses. **Do not count them with a
bare `npx vitest run` from the repository root** — that pulls `cost-ingest` and
`directline-token`, which are `node --test` packages, into vitest and resolves every
package-relative fixture path against the wrong root. It reports two dozen failures that
belong to the invocation rather than the code.

Every cloud call in all of them is mocked; the suite has never contacted Azure, Graph,
Fabric or GitHub. Two gates sit alongside and are not counted as tests, because they are
not test cases: **PSScriptAnalyzer** at Error + Warning across `scripts`, `infra`,
`verification`, `data`, `compliance` and `.github` (**0 findings**), and **actionlint**
across all 23 workflows (**clean**). *Corrected 2026-09-22: this read 24 until `vuln-lab-witness.yml` was found to have been deleted on 2026-09-07 while three documents still listed it.*

## The rebuild, measured

The claim this repository exists to make, with a stopwatch on it.

| | |
|---|---|
| Teardown | **~14 minutes** (2026-09-03), **~31 minutes** (2026-09-21) |
| Rebuild | **87 minutes** (2026-09-03), **152 minutes** (2026-09-21) |
| — longest single job in the 152 | **L7's verify, at 96.7 minutes** — 64% of the whole rebuild |
| — all deploy jobs in the 152, summed | **~49 minutes** |
| — all verify jobs in the 152, summed | **~100 minutes** |
| Budget gate (V11.4) | **180 minutes** since 2026-09-22 — the measurement plus ~18% |
| Resources before / after | **30 / 30**, same names, same ingress shape |
| Container Apps domain | regenerates on every rebuild, so no stored FQDN survives one |
| Managed identities | all recreated with **new principal ids** — so anything keyed on one must be re-derived, never remembered |

**The estate deploys in well under an hour and takes twice that to verify.** That ratio is
the point rather than an embarrassment: the deploys are Bicep and they are fast; the audits
wait on real propagation, real scale-in cycles and real cost-export windows, because a
criterion that does not wait is a criterion that guesses.

**It is not the test suites.** All 3,097 of those run in CI on pull requests, in about
94 seconds for the Pester half, and none of them runs during a rebuild — they never contact
a cloud API at all. The rebuild's time is spent *waiting on Azure*, and overwhelmingly inside
one job: **L7's verify, 96.7 of the 152 minutes.** Its dominant criterion is **V7.5, which
drives a container app to zero replicas, generates load, confirms it scaled back up, and then
waits out a real scale-in cycle** — a 15-minute poll against a 30-minute deadline, for each of
two apps. The audit's own parameter block puts a full L7 run at ~55 minutes for that reason.
Shortening it means asserting that the platform *can* scale to zero rather than observing that
it *did*, which is the substitution this repository exists to refuse.

## Lines by area

| Area | Files | Lines | |
|---|---|---|---|
| `compliance/` | 114 | 97,221 | the NIST catalog, the assessment register, 5 collectors, the derivation, the emitter — **and the nightly committed state, which is the bulk of it and is machine-written** |
| `apps/` | 269 | 40,394 | 8 packages: 3 frontends, MCP server, data API, 2 Functions, shared renderer (+ the vulnerable lab) |
| `verification/` | 50 | 28,052 | the audit engine and 12 layer audits |
| `docs/` | 47 | 24,869 | brief, specs, 12 layer playbooks, runbooks, the finding register |
| `infra/` | 90 | 18,768 | Bicep, Entra manifest, Purview labels, Fabric REST, Copilot Studio ALM |
| `.github/` | 33 | 14,244 | layer deploys, per-app CI, the DevSecOps chain, self-healing, compliance collection |
| `data/` | 46 | 7,659 | generators, SQL schema, lakehouse loaders |
| `scripts/` | 20 | 7,062 | bootstrap, the `up`/`down` fuse, the Defender toggle |
| root and other | 16 | 1,562 | `CLAUDE.md`, the root README, configs |

**Method, because a number nobody can reproduce is not a measurement.** `git ls-files`,
excluding lockfiles and binaries (`.pdf .png .jpg .svg .ico .woff .woff2 .zip .gz`),
counting newlines. That totals **239,831 across 685 files** and the rows above sum to it.

An earlier revision of this page reported **148,199** with no method recorded, and the
rows under it summed to 166,594 — neither figure is reachable from the repository today and
neither can be checked, which is the entire reason the method now sits next to the number.
Most of the growth since is `compliance/`: the nightly collection commits its state, so that
row is a record of how long the estate has been running rather than of anything anyone wrote.

## What the counts do not show

Line totals are a weak proxy for whether a demo survives contact with a stage. Four
numbers say more.

**65 verification criteria**, each with a named expected value, a declared waiting window,
and an audit script that runs read-only under a separate identity. A layer is done when an
independent auditor says so, not when a deploy exits zero.

**0 of 110 NIST requirements are machine-verified**, and 94 are `NOT_ASSESSED`. Sixteen
carry a human assertion and render as `asserted`. The platform is built so that a human's
strongest written claim *cannot* derive to `COMPLIANT`, and so that no blended percentage
exists anywhere to paper over the difference — CI greps the emitted bytes to keep it that
way.

**Criteria that are red or unproven are stated here rather than discovered later**, and
the live list is `docs/DEMO-READINESS.md`, not this page. As of **2026-09-22** all three
that this section used to name have moved, and none of the three moved because the estate
changed — each was a *check* that was wrong:

- **V6.2** (a KQL query as the read-only identity) executed and **passed**. The text
  claiming its fix had never run was itself stale.
- **V8.4** (every visual answer an Adaptive Card) was reading the wrong transport. The
  agent does emit cards; they arrive embedded in the message **text** rather than as
  Direct Line attachments, so the eval recorded none — and the probe written to check
  the eval counted attachments too, and agreed with it. Both now read text-borne cards,
  and the schema pin moved 1.5 → 1.6 to match what the agent actually emits.
- **V8.2** asked for evidence the eval could not produce. Each golden question now carries
  the T-SQL that answers it, so the Verifier can re-derive the number independently instead
  of accepting the agent's own word for it.

That is the pattern worth carrying away from this whole page: **of the last ten findings,
seven were green checks that were confidently wrong rather than broken infrastructure.**
A count of criteria says less than whether the criteria can be fooled.

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

**Azure spend was $14.74 month-to-date on 2026-09-03, and one idle database was 99% of it.**
Not the container apps, not the Functions, not the lakehouse — the serverless SQL instance,
which auto-pauses after an hour and wakes on the next query. The number a planner should
carry is that the compute is effectively free and the database is the bill.

*Not re-measured on 2026-09-22, and the reason is itself a finding.* `az consumption usage
list` returns 967 line items for the period with `pretaxCost` **null on every one**, which is
the same unreadable cost data V11.5 reports. The figure above is left dated rather than
refreshed, because the honest options were a stale number labelled stale and a fresh number
that does not exist.

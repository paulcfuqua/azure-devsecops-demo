# Meridian Launch Systems — Azure DevSecOps Demo

An agent-team-built, fully code-defined enterprise Azure environment themed for the space
launch industry. The **repo is the product; the Azure environment is a build artifact** —
it can be destroyed and rebuilt from nothing via pipelines to keep idle cost near zero.

*Meridian Launch Systems* is a fictional company. All data is synthetic.

> ### Current state — read this before you spend an evening on it
>
> **[docs/DEMO-READINESS.md](docs/DEMO-READINESS.md) is the live scorecard** of what is
> verified, what is blocked, and what the audits cannot see. The short version, as of
> **2026-09-03**, when the estate was torn down and rebuilt:
>
> - **The destroy-and-rebuild claim is demonstrated.** Teardown took 14 minutes; the
>   rebuild came back with the same 30 resources across the same four resource groups.
>   L2, L3, L5, L6 and L7 all signed off on the rebuilt estate — L7 at 7 of 7, including
>   the criterion asserting the data API returns **rows**, not merely a status code.
> - **It failed twice before it passed**, and that is the useful part. The rebuild
>   surfaced eleven findings, of which the three most valuable were not broken
>   infrastructure but **green checks that were verifying nothing**: L4's audit had never
>   once executed, V11.2 had never had evidence on any teardown ever run, and a step whose
>   only job is to announce a failed grant was reporting success.
> - **L4 is blocked on a human.** The Purview labels are applied and real; the independent
>   audit of them cannot run, because `mls-verifier` was never granted Security &
>   Compliance access. That is a tenant change, so no agent may do it — the steps are in
>   `docs/runbooks/g0-bootstrap.md` step 11d. Until someone runs it, L4 has no verdict.
> - **Two showpieces are qualified, not green.** The copilot survives a rebuild but three
>   of its criteria skip on a missing eval artifact; the compliance board's state is five
>   days stale because its nightly PR cannot merge (F120).
>
> None of that is hidden by a red pipeline, which is the point worth understanding before
> trusting any green check here: layer criteria verify that the plumbing exists, and a
> criterion asserting that water comes out of the tap is younger than the plumbing. If you
> are evaluating this repo as an example, the interesting reading is the failure classes in
> `verification/tests/failure-classes.Tests.ps1` and the
> [finding register](docs/findings/2026-09-03-finding-register.md), not the badges.

## Before you deploy this anywhere

> ### Use a dedicated, empty Azure subscription.
>
> This is a requirement, not a suggestion. The landing zone (`infra/bicep/landing-zone/`)
> assigns **subscription-wide DENY policy**: six `require-<tag>` deny rules on resource
> groups and an `allowed-locations` deny on every resource. Deployed into a subscription
> that already has workloads, those policies apply to **everything in it**, and the next
> deployment anyone makes without the six required tags — or into a location outside the
> allowlist — is refused. The demo also assigns a NIST SP 800-53 R5 initiative and a
> budget at subscription scope, and `infra-down.yml` deletes four resource groups by name.
>
> Two more reasons to keep it separate: the L9 Defender round-trip touches a
> **subscription-scoped** pricing plan (it now refuses to run if you already have
> Defender for Containers on — see F31), and `data-api`'s identity is granted **Security
> Reader across the whole subscription**, so it can read the posture of everything else
> living there.
>
> ### The three dashboards require an Entra sign-in.
>
> `launch-ops`, `control-tower` and the compliance board are gated by Container Apps
> Easy Auth. That is not incidental polish: both frontends proxy `/api/` straight through
> to `data-api`, so an open dashboard is an open door to that Security Reader grant
> (finding F25).
>
> **You do not have to configure anything for this.** L3 creates the four Entra app
> registrations from `infra/entra/manifest.json`; L7 looks each application (client) ID up
> by name, and registers each app's Easy Auth redirect URI once its ingress FQDN exists.
> `MLS_LAUNCH_OPS_CLIENT_ID`, `MLS_CONTROL_TOWER_CLIENT_ID` and `MLS_COMPLIANCE_CLIENT_ID`
> remain as *overrides* for bringing your own registrations. An app whose client ID cannot
> be resolved still deploys, but **internal to the Container Apps environment** and
> unreachable from the internet — never open (finding F36). See
> [docs/runbooks/g0-bootstrap.md](docs/runbooks/g0-bootstrap.md) § C9.

## Status

> ## The estate is deployed, and it has been destroyed and rebuilt.
>
> Thirty resources across four resource groups in one region. The last full cycle ran on
> **2026-09-03**: teardown in 14 minutes, rebuild in 87, same resource count on the other
> side. Figures below marked *measured* came from an API answering for that live estate;
> figures about the repository itself came from `git ls-files` and real test runs.
>
> Read the compliance board further down with that in mind. It is the one place where the
> distinction between *asserted* and *machine-verified* is load-bearing rather than a
> disclaimer — and after all of the above, **0 of 110 requirements are machine-verified**.

**Turn-key, and self-auditing.** Everything is tenant-independent: the company prefix,
environment segment and every derived name resolve from `infra/bicep/naming.bicep` or the
`demo` GitHub environment, so this deploys into someone else's tenant under someone else's
name without editing a template. The estate is assessed against NIST SP 800-171 by
showpiece #4 below, on a board built so that it cannot overclaim.

What exists: data generators and seeding, the SQL schema, the Fabric lakehouse loaders,
the renderer library, three frontends, the data API, the MCP tool server with real cloud
adapters and six tools, the Copilot Studio agent definition and ALM, OpenTelemetry
throughout, the full DevSecOps chain, **all 11 Verifier audit scripts wired into their
layer workflows**, the compliance catalog/collectors/board, and the `up.ps1` / `down.ps1`
fuse.

Gates, measured 2026-09-03 rather than remembered:

| Gate | Result |
|---|---|
| Pester (PowerShell 7) over `scripts infra data verification compliance` | **1,598 passed, 0 failed, 1 skipped** |
| `npm test` across 8 workspaces | **1,035 passed, 0 failed** |
| pytest (`data/generators`) | **30 passed** |
| **Total** | **2,663 automated tests** |
| PSScriptAnalyzer, Error + Warning, over `scripts infra verification data compliance .github` | **0 findings** |
| actionlint | **clean across all 24 workflows** |
| `az bicep build` / `build-params` | **3 templates + 3 parameter files, clean** |

Those are repository gates and they are reproducible from a checkout. **They are not
evidence the estate works** — that distinction is the entire subject of
[docs/DEMO-READINESS.md](docs/DEMO-READINESS.md), and the 2026-09-03 rebuild found three
places where a green job had verified nothing at all.

**Architecture amendment, 2026-08-24 (sponsor-directed):** all runtime LLM work moves
inside the Microsoft landscape.
[The amendment](docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md) replaces
the self-hosted copilot service with a **custom Microsoft Copilot Studio agent**, and the
authored triage script with **GitHub Copilot Autofix**. There is now **no LLM API key
anywhere in the system** — CI authenticates only by OIDC/workload identity federation.
Decisions in force: monorepo, dual E5 trials, Fabric trial capacity first; the
2026-08-22 LLM-provider decision is void.

| Gate | Meaning | Status |
|------|---------|--------|
| G0 | Human bootstrap (tenant, OIDC root, Fabric capacity, licensing, Power Platform environment + Copilot Studio meter) | **Done**, and agents may now run the bootstrap scripts themselves (sponsor amendment 2026-08-29). **One step is outstanding**: 11d, the Security & Compliance grant `mls-verifier` needs before L4 can be independently audited |
| G1 | One-time master plan approval | **Approved.** Agent-created and agent-managed infrastructure is now the demo rather than something the demo describes |
| G2 | Spend-profile changes (per occurrence) | **Still binds, and nothing has triggered it.** The estate runs on the Fabric trial capacity; moving to the paid F2 that showpiece #1's Fabric data agent needs is a G2, and the tools-only MCP path is the trial-phase default. See BLOCKER-E in the scorecard — a paid capacity is currently created into a resource group that teardown deletes |
| G3 | Tenant-level destructive ops (per occurrence) | **Still binds, and it held on 2026-09-03.** The teardown deleted four resource groups and reached no Entra object, Purview label, Fabric workspace shell or OIDC federation. The three tenant-level teardown scripts still refuse to run unattended in CI |
| G4 | Exception escalation (event-driven) | Not triggered during the 2026-09-03 rebuild; two layers failed verification once each and were fixed on the first attempt |

## Key documents

- [By the numbers](docs/BY-THE-NUMBERS.md) — what it took: files, lines, 2,663 tests
- [Project brief (decision record)](docs/BRIEF.md)
- [Design spec + pressure-test findings](docs/superpowers/specs/2026-08-22-azure-devsecops-demo-design.md)
- [Copilot Studio amendment (in force)](docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md)
- [G1 master plan](docs/superpowers/plans/2026-08-22-g1-master-plan.md)
- [Compliance platform design](docs/superpowers/specs/2026-08-26-compliance-platform-design.md)
  and [`compliance/README.md`](compliance/README.md) — showpiece #4's vocabulary, and the
  rules that stop it overclaiming
- [Tenant bootstrap (G0)](docs/runbooks/g0-bootstrap.md) — the accounts, trials and portal
  steps you do by hand before anything deploys. **Start here if you are cloning this.**
- [Lifecycle and shutdown](docs/runbooks/lifecycle-and-shutdown.md) — what expires when,
  what bills outside the Azure spending limit, and what `down.ps1` deliberately does not
  touch. Read it before the credit lapses, not after
- [Layer playbooks L01–L12](docs/runbooks/layers/) · [demo script](docs/runbooks/demo-script.md)
- [Working agreements for all agents](CLAUDE.md)

## Run locally

The apps and the MCP tool layer run pre-tenant in **local data mode** — no Azure, no
credentials. Requires Node 20+ and Python 3.11+.

```sh
# 1. Generate the synthetic dataset (deterministic, seed 20260822; gitignored output)
cd data && python -m generators build && cd ..

# 2. Install the npm workspaces (root manifest covers apps/* and apps/shared/*)
npm install

# 3. Run an app — http://localhost:5173 and http://localhost:5174
npm run dev:launch-ops
npm run dev:control-tower

# 4. Run the MCP tool server and exercise its six tools against local data
npm run dev:mcp-tools

# 5. Collect the compliance state and run the board (http://localhost:5175)
pwsh compliance/Invoke-MlsCompliance.ps1
npm run dev --workspace apps/compliance
```

`launch-ops` reads `data/generated/*.json`; `control-tower` reads committed feed
fixtures for its Dev/Sec tabs and `data/generated/` for Ops. Dev mode defaults to
local data; set `LOCAL_DATA=1` to force it for a production build, or
`VITE_DATA_MODE=api` to point at the live backends wired at L7.

`npm run build` and `npm test` at the root run across all workspaces.

**What you cannot run locally, stated plainly.** Since the 2026-08-24 amendment,
showpiece #1's *agent* is **cloud-only**: Microsoft Copilot Studio has no local runtime,
so the agent cannot be started, tested, or demoed on a laptop. It requires the tenant, a
Power Platform environment, and a published agent. What remains locally runnable is
everything around it — all three frontends (including the compliance board), the shared
renderer, and the **MCP tool layer**
with its six tools and their tests, which is where the copilot's data access actually
lives. The golden-question eval suite runs locally against the MCP tools, and against the
deployed agent over Direct Line in CI. This is a real capability the previous design had
and this one does not — a deliberate trade made when the 2026-08-24 amendment moved all
runtime LLM work inside the Microsoft landscape, and worth knowing before you plan an
afternoon around iterating on the agent.

## The four showpieces

1. **Copilot — a custom Microsoft Copilot Studio agent** answering cross-domain
   natural-language questions, embedded in the control tower's **Ask** tab over Direct
   Line and replying in **Adaptive Cards** (declarative JSON UI, never generated code).
   Its knowledge is a **Fabric data agent** over the lakehouse (preview integration, and
   it needs a paid F2 capacity — there is a documented tools-only fallback); its tools are
   the five ops/sec/cost tools re-hosted as an **MCP server** on Container Apps, plus a
   sixth, `query_compliance`, that reads showpiece #4's artifact. The agent is a Power
   Platform solution that lives in this repo and deploys by pipeline — edit it in a
   browser and the auditor fails the layer.
2. **Control tower** — Dev / Sec / Ops posture on Well-Architected pillars, fed by live
   Azure, GitHub, and Defender APIs plus cost exports in the lakehouse. Now also the host
   for showpiece #1.
3. **Self-healing pipeline** — vulnerability finding → **GitHub Copilot Autofix** writes
   the code fix (Dependabot writes the dependency ones) → patch PR → CI gauntlet →
   auto-merge on green → deploy → finding closed. Both healers are GitHub platform
   features, free on a public repo; we wrote neither. The PR trail is the demo.
4. **Self-auditing compliance platform** — the whole estate assessed against **NIST SP
   800-171 Rev 2**, and through published mappings against **800-53 Rev 5**, **CMMC 2.0**
   and **FAR 52.204-21**, on a board that is deliberately, verifiably not green. See
   below; it displaces nothing — showpieces 1–3 are unchanged, and the design spec's own
   case for building it was that
   [most of it was already paid for](docs/superpowers/specs/2026-08-26-compliance-platform-design.md):
   the `verification/` suite was already a control-assessment engine missing one field.

### Showpiece #4 in detail — why an honest board is the product

Showpiece #3 proves this repo can *fix* a vulnerability. Showpiece #4 proves it can
*govern an estate against a standard* — the question the audience has to answer to their
own auditors.

**What the board says, from the last state that reached `main` — collected 2026-08-29:**

| | COMPLIANT | PARTIAL | GAP | INCONCLUSIVE | NOT_APPLICABLE | NOT_ASSESSED |
|---|---|---|---|---|---|---|
| **of 110 requirements** | **0** | 15 | 1 | 0 | 0 | **94** |

Plus four out-of-catalog rows keyed on 800-53 control ids the 800-171 catalog has no
requirement for, counted separately so the 110 stays arithmetic.

**That state is five days stale, and the reason is itself a finding.** The nightly
collection runs and opens a pull request; that PR cannot merge, because a `GITHUB_TOKEN`
push triggers no workflow runs, so no required check ever reports (**F120**, still open —
PR #147 has been sitting with zero checks since 2026-09-01). `compliance/state/` therefore
holds two snapshots when it should hold a dozen. A board whose selling point is *"the
history is a git history"* is exactly the wrong place to have a broken history, and saying
so here is cheaper than being asked.

**A compliance dashboard that showed green would be worthless.** The estate has since been
deployed, destroyed and rebuilt — and the number that matters has not moved: of 110
requirements, **0 are machine-verified**. Sixteen carry a human assertion and render as
`asserted`. That is the whole product:

- **`COMPLIANT` is unreachable from a human claim.** The register's strongest word is
  `CLOSED`, meaning *no known open finding stands against this control* — weaker than
  *the control is met*. `Get-MlsControlStatus` maps it to `PARTIAL`, because deriving
  `COMPLIANT` from it would launder the weaker claim into the stronger one. Both halves
  of that invariant are property-tested; neither can be broken without a test going red.
- **Provenance is set by which code path fired**, never read from an input field, so no
  record can ask to be called machine-verified.
- **There is no percentage anywhere.** No score, no ratio, no "% compliant". Counts by
  status, counts by provenance, and the cross-tabulation of the two — because a figure
  blending verified and asserted controls is exactly the number someone would quote to
  an auditor and exactly the number that would be wrong. CI greps the emitted bytes to
  keep it that way.
- **The board says what it could not see.** Each of the five collectors renders its own
  limitation verbatim rather than letting an absent input read as a clean result. That
  discipline is the single most-repeated lesson in the finding register: three separate
  subsystems once reported a control as *missing* when the truth was that the auditor had
  been refused permission to look (F102, F103, F105), and each produced a confident,
  specific, wrong answer a reader would have acted on.
- **The history is a git history** — when it can merge. `.github/workflows/compliance.yml`
  commits a dated snapshot on every run, so `git log compliance/state/` answers when the
  estate became compliant and when it regressed. There are **two** snapshots today and the
  trend view says so in those words rather than drawing a flat line. See F120 above for
  why there are not more.

Read [`compliance/README.md`](compliance/README.md) for the two vocabularies — what a
human may assert, and what the platform will derive from it — and
[`docs/runbooks/layers/L12.md`](docs/runbooks/layers/L12.md) for the layer playbook,
including a plain statement of which leg of its deploy/teardown/audit triplet is missing.

## Security and license

Some of the vulnerabilities in this repository are **deliberate**. Everything under
[`apps/vuln-lab/`](apps/vuln-lab/) carries real, deliberately unpatched CVEs and two
CodeQL-detectable flaws — they are the fixtures showpiece #3 heals, they are never
imported by any deployed app, and Dependabot or CodeQL alerts against them are the demo
working rather than a defect. Read [SECURITY.md](SECURITY.md) before reporting anything
found there; it also explains how to privately report a genuine issue found anywhere else.

"Meridian Launch Systems" is a fictional company. Every person, credential and business
record here is synthetic — see [NOTICE](NOTICE).

Licensed under the **[Apache License 2.0](LICENSE)**. This is demonstration software,
provided as is and without warranty, that provisions billable cloud resources; read
[docs/runbooks/g0-bootstrap.md](docs/runbooks/g0-bootstrap.md) — including its cost model
and spending guardrails — before deploying it anywhere.

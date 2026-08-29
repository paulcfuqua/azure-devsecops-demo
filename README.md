# Meridian Launch Systems — Azure DevSecOps Demo

An agent-team-built, fully code-defined enterprise Azure environment themed for the space
launch industry. The **repo is the product; the Azure environment is a build artifact** —
it can be destroyed and rebuilt from nothing via pipelines to keep idle cost near zero.

*Meridian Launch Systems* is a fictional company. All data is synthetic.

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

> ## Nothing here has ever been deployed.
>
> No `az login` has ever run on the machine that built this. There is no tenant, no
> subscription, no resource group, no running container. Every number in this repository
> was produced by code reading files on a laptop — never by an API answering for a live
> estate. Read the compliance board below with that in mind: it is the one place where
> that fact is *load-bearing* rather than a disclaimer.

**Turn-key, and self-auditing.** Phase Q (2026-08-25) made everything tenant-independent
authored, tested and wired —
[completion report](verification/reports/phase-q-completion.md), preceded by
[Phase P](verification/reports/phase-p-completion.md). Two plans have landed since, on
this branch: a pre-publication security review that closed 24 findings — the register
has since grown to **44** as later passes, and the repository's own CI, found more — and the
**compliance platform** (showpiece #4 below) that renders them against NIST SP 800-171.

What exists: data generators and seeding, the SQL schema, the Fabric lakehouse loaders,
the renderer library, three frontends, the data API, the MCP tool server with real cloud
adapters and six tools, the Copilot Studio agent definition and ALM, OpenTelemetry
throughout, the full DevSecOps chain, **all 11 Verifier audit scripts wired into their
layer workflows**, the compliance catalog/collectors/board, and the `up.ps1` / `down.ps1`
fuse.

Gates, measured 2026-08-28 rather than remembered:

| Gate | Result |
|---|---|
| Pester (PowerShell 7) over `scripts infra data verification compliance` | **1,352 passed, 0 failed** |
| `npm test` across 8 workspaces | **960 passed, 0 failed** |
| `npm run typecheck` across 7 workspaces | **exit 0** |
| pytest (`data/generators`) | **30 passed** |
| PSScriptAnalyzer, Error + Warning, over `scripts infra verification data compliance .github` | **0 findings** |
| actionlint | **clean across all 24 workflows** |
| `az bicep build` / `build-params` | **3 templates + 3 parameter files, clean** |
| Golden-question MCP eval (`npm run eval`) | **10/10, tool surface matches the allowlist** |

**Nothing has been written to Azure**, and the public repo has not been published. Both
await sponsor go-ahead.

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
| G0 | Human bootstrap (tenant, OIDC root, Fabric capacity, licensing, Power Platform environment + Copilot Studio meter) | Deferred by sponsor — trial-rate strategy in `docs/runbooks/g0-bootstrap.md` |
| G1 | One-time master plan approval | **Amended 2026-08-22:** scaffold phase approved (Phase P); Azure deploy authorization (G1b) awaits tenant activation. **Amended 2026-08-24:** L8 and L10 rebuilt on Copilot Studio / Copilot Autofix |
| G2 | Spend-profile changes (per occurrence) | n/a — but note: the Fabric data agent needs a **paid F2**, so showpiece #1's knowledge source will require a G2 (or runs on its documented tools-only fallback) |
| G3 | Tenant-level destructive ops (per occurrence) | n/a — now also covers the Power Platform environment, the agent and its solution |
| G4 | Exception escalation (event-driven) | n/a |

## Key documents

- [By the numbers](docs/BY-THE-NUMBERS.md) — what it took: files, lines, 2,342 tests
- [Project brief (decision record)](docs/BRIEF.md)
- [Design spec + pressure-test findings](docs/superpowers/specs/2026-08-22-azure-devsecops-demo-design.md)
- [Copilot Studio amendment (in force)](docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md)
- [G1 master plan](docs/superpowers/plans/2026-08-22-g1-master-plan.md)
- [Compliance platform design](docs/superpowers/specs/2026-08-26-compliance-platform-design.md)
  and [`compliance/README.md`](compliance/README.md) — showpiece #4's vocabulary, and the
  rules that stop it overclaiming
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
lives. The golden-question eval suite runs locally against the MCP tools and only against
the deployed agent once it exists. This is a real capability the previous design had and
this one does not; it is recorded as open item P-8 in the
[Phase P plan](docs/superpowers/plans/2026-08-22-phase-p-pre-tenant-scaffold.md).

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

**What the board says right now, on an estate that has never been deployed:**

| | COMPLIANT | PARTIAL | GAP | INCONCLUSIVE | NOT_APPLICABLE | NOT_ASSESSED |
|---|---|---|---|---|---|---|
| **of 110 requirements** | **0** | 12 | 3 | 0 | 0 | **95** |

Plus four out-of-catalog rows keyed on 800-53 control ids the 800-171 catalog has no
requirement for, counted separately so the 110 stays arithmetic.

**A compliance dashboard that showed green here would be worthless.** Nothing has been
deployed, so nothing could have been observed; the only controls with any status at all
are the fifteen of those 110 a human wrote an assertion about, and every one of those renders as
`asserted`, never `machine-verified`. That is the whole product:

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
  limitation verbatim, including the one that matters most: *"Nothing in this estate has
  been deployed, so there are no reports to read."*
- **The history is a git history.** `.github/workflows/compliance.yml` commits a dated
  snapshot on every run, so `git log compliance/state/` answers when the estate became
  compliant and when it regressed. There is exactly **one** snapshot today, and the trend
  view says so in those words rather than drawing a flat line.

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

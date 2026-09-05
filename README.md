# Meridian Launch Systems — Azure DevSecOps Demo

An agent-team-built, fully code-defined enterprise Azure environment themed for the space
launch industry. The **repo is the product; the Azure environment is a build artifact** —
it can be destroyed and rebuilt from nothing via pipelines to keep idle cost near zero.

*Meridian Launch Systems* is a fictional company. All data is synthetic.

> ### What this is, and what is unusual about it
>
> An enterprise Azure estate — landing zone, identity, data platform, three applications,
> a copilot, a DevSecOps chain and a compliance board — defined entirely in this
> repository and built by pipelines. It can be **destroyed and rebuilt on demand**, which
> it has been, and it comes back with the same thirty resources.
>
> The unusual part is not the estate. It is that **the estate audits itself, independently,
> and is built so that it cannot overstate the result.** Every layer ships three things —
> a deploy path, a teardown, and a verification script that runs read-only under a
> different identity. A layer is done when that auditor says so, not when a deploy exits
> zero. Fifty-seven criteria work that way, and four of them are red today; they are in
> the same table as the greens.
>
> The compliance board makes the same argument in a form an auditor recognises: 110 NIST
> SP 800-171 requirements, **0 of them machine-verified**, no percentage anywhere, and a
> derivation that cannot promote a human's written claim to `COMPLIANT`.
>
> **Where to look:** [docs/DEMO-READINESS.md](docs/DEMO-READINESS.md) is the live
> scorecard — what is verified, what is blocked, and what the audits cannot see. If you
> are evaluating this repository as an example, the interesting reading is that file, the
> failure classes in `verification/tests/failure-classes.Tests.ps1`, and the
> [finding register](docs/findings/2026-09-03-finding-register.md) — not the badges.

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

## What this needs from Microsoft

Every SKU below was read from the running estate on **2026-09-03** — Azure Resource
Manager, Microsoft Graph, the Fabric API and the Power Platform admin API — rather than
recalled from a design document. **The whole estate runs on trial and free tiers**: total
licence cost is **$0**, and measured Azure spend is **$14.74 month-to-date**, of which the
serverless SQL database is 99%.

### Azure — one subscription, thirty resources

| What | SKU as deployed | Count |
|---|---|---|
| Container Apps environment | Consumption (no workload profile) | 1 |
| Container apps | Consumption, scale-to-zero, 15-minute cooldown | 6 |
| Azure SQL Database | `GP_S_Gen5` — General Purpose **serverless**, 0.5–2 vCore, 60-minute auto-pause | 1 |
| Azure SQL logical server | no charge; billing sits on the database | 1 |
| Function App plans | `FC1` — **Flex Consumption** | 2 |
| Function Apps | on the plans above | 2 |
| Storage accounts | `Standard_LRS` | 3 |
| Key Vault | `standard` (not Premium — no HSM key in the design) | 1 |
| Log Analytics workspace | `PerGB2018` | 1 |
| Application Insights | workspace-based | 1 |
| Event Grid system topic | no SKU tier | 1 |
| Log search alert rules + action group | 2 rules, 1 group | 3 |
| User-assigned managed identities | no charge | 5 |

Subscription-scope objects — the NIST SP 800-53 R5 policy initiative, the six
`require-<tag>` deny policies, the `allowed-locations` deny and the budget — are **Azure
Policy and Cost Management, both free**.

Two things this estate deliberately does **not** need: there is **no Azure Container
Registry** (the six images are hosted on GHCR, free for a public repository) and **no
Microsoft Purview account resource** — the sensitivity labels are Microsoft 365 Purview,
covered by the E5 service plans below.

### Microsoft Defender for Cloud — subscription-scoped plans

Seven plans read as `Standard` on this subscription: `FoundationalCspm`, `CloudPosture`,
`Discovery`, `SqlServers`, `StorageAccounts` (`DefenderForStorageV2`), `KeyVaults`
(`PerKeyVault`) and `Containers`. Only the last has a rate this repository pins —
**~USD 0.29/day** — and `scripts/defender/toggle-containers-plan.ps1` treats enabling it as
a **G2 spend gate**, prints that delta on every run, and expects it left **Off** between
demos. Defender is the one line item here that will grow a bill if forgotten.

### Microsoft 365 and Entra ID

| SKU | Seats | What the estate consumes from it |
|---|---|---|
| **`SPE_E5`** — Microsoft 365 E5 (25-seat, 30-day trial) | 25 enabled, 7 assigned | `AAD_PREMIUM_P2` (Entra ID P2 — sign-in risk, Identity Protection, risk-based CA), `RMS_S_PREMIUM` (AIP P1 — sensitivity label management), `MFA_PREMIUM` (the enforced dashboard policy) |

`scripts/bootstrap/verify-g0.ps1` asserts those three **service plans**, not a SKU part
number, and that distinction is load-bearing. Two SKUs an earlier plan called for are
**not** required: `EMSPREMIUM` (Enterprise Mobility + Security E5 is purchase-only at
$18/user/month and Microsoft 365 E5 is a strict superset — finding F46) and
`RMS_S_PREMIUM2` (AIP P2 auto-labeling, documented as optional).

### Microsoft Fabric

The `mls-operations` workspace runs on **`FTL4`** — a **Fabric 60-day trial capacity**,
4 CU, East US. There is **no `Microsoft.Fabric/capacities` resource in the subscription**,
which is how you can tell the trial rather than a paid capacity is carrying it.

The one thing the trial cannot do is **AI experiences, including Fabric data agents**.
Layer 8's Fabric knowledge source therefore needs a **paid F2 or higher** (~USD 0.36/hr
while resumed, ~USD 260/month if left running) — a **G2 gate**, requested per resume, and
never taken automatically. Everything else, layer 5 included, is covered by the trial.

### Power Platform and Copilot Studio

| SKU | What it provides |
|---|---|
| **`POWERAPPS_DEV`** — Power Apps Developer Plan | the `mls-authoring` Dataverse environment, type **Developer**, at $0 |
| **`FLOW_FREE`** — Power Automate Free | the flows behind the solution |
| **Copilot Studio pay-as-you-go meter** | billed to this Azure subscription, plus the *Copilot Studio authors* security role for the maker — **no licence purchase** |

`POWERAPPS_PER_USER` exists in the tenant with **0 seats assigned**; it is not required and
nothing here consumes it.

### GitHub

A **public repository** on a free account. Actions minutes, CodeQL, Dependabot, secret
scanning with push protection, Copilot Autofix and GHCR image hosting are all free at that
visibility — **GitHub Advanced Security is not purchased**, and showpiece #3 depends on
Autofix being GA and free on public repositories.

## Status

**Deployed and running.** Thirty Azure resources across four resource groups in one
region. Teardown takes about fourteen minutes and a full rebuild about ninety, ending with
the same resource count.

**Turn-key.** Everything is tenant-independent: the company prefix, environment segment
and every derived name resolve from `infra/bicep/naming.bicep` or the `demo` GitHub
environment, so this deploys into someone else's tenant under someone else's name without
editing a template.

**All runtime LLM work stays inside the Microsoft landscape.** The copilot is a custom
Microsoft Copilot Studio agent over an MCP tool server; the code-healing half is GitHub
Copilot Autofix. **There is no LLM API key anywhere in the system**, and CI authenticates
to Azure only by OIDC / workload identity federation.

What is here: data generators and seeding, the SQL schema, the Fabric lakehouse loaders,
the shared renderer library, three frontends, the data API, the MCP tool server with six
real cloud-backed tools, the Copilot Studio agent and its ALM, OpenTelemetry throughout,
the DevSecOps chain, **12 Verifier audit scripts wired into their layer workflows**, the
compliance catalog / collectors / board, and the `up.ps1` / `down.ps1` fuse.

### Repository gates

| Gate | Result |
|---|---|
| Pester (PowerShell 7) over `scripts infra data verification compliance` | **1,652 passed, 0 failed, 1 skipped** |
| `npm test` across 8 workspaces | **1,037 passed, 0 failed** |
| pytest (`data/generators`) | **30 passed** |
| **Total** | **2,719 automated tests** |
| PSScriptAnalyzer, Error + Warning, over `scripts infra verification data compliance .github` | **0 findings** |
| actionlint | **clean across all 24 workflows** |
| `az bicep build` / `build-params` | **3 templates + 3 parameter files, clean** |

These are reproducible from a checkout and they are **not evidence the estate works** —
that distinction is the entire subject of [docs/DEMO-READINESS.md](docs/DEMO-READINESS.md),
which is where the deployed-state verdicts live.

### Governance gates

Four things an agent working in this repository may not decide for itself. They are
enforced in the workflows and the scripts, not just written down.

| Gate | Meaning | Status |
|------|---------|--------|
| G0 | Human bootstrap: tenant, OIDC root, Fabric capacity, licensing, Power Platform environment | **Complete**, except one step — the Security & Compliance grant `mls-verifier` needs before L4's labels can be independently audited (`docs/runbooks/g0-bootstrap.md` step 11d) |
| G1 | One-time plan approval | **Approved.** Agent-created and agent-managed infrastructure is the demo, not something the demo describes |
| G2 | Any spend-profile increase, per occurrence | **Binds, and has not been triggered.** The estate runs on the Fabric trial capacity; moving to a paid F2 is a G2 and the tools-only MCP path is the default without it |
| G3 | Tenant-level deletion, per occurrence | **Binds.** Teardown deletes four resource groups and can reach no Entra object, Purview label, Fabric workspace shell or OIDC federation. The three tenant-level teardown scripts refuse to run unattended in CI |

## Key documents

- **[Demo readiness](docs/DEMO-READINESS.md)** — the live scorecard: what is verified,
  what is blocked, and what the audits cannot see. **Start here.**
- [By the numbers](docs/BY-THE-NUMBERS.md) — files, lines, 2,719 tests, and what the
  counts do not show
- [Project brief](docs/BRIEF.md) — what this is for and the decisions behind it
- [Design spec](docs/superpowers/specs/2026-08-22-azure-devsecops-demo-design.md) and the
  [compliance platform design](docs/superpowers/specs/2026-08-26-compliance-platform-design.md)
- [`compliance/README.md`](compliance/README.md) — the two vocabularies: what a human may
  assert, and what the platform will derive from it
- [Tenant bootstrap](docs/runbooks/g0-bootstrap.md) — the accounts, trials and portal steps
  done by hand before anything deploys. **Start here if you are cloning this.**
- [Kill and rebuild](docs/runbooks/kill-rebuild.md) — the destroy/rebuild cycle, its
  semantics and its measured timings
- [Lifecycle and shutdown](docs/runbooks/lifecycle-and-shutdown.md) — what expires when,
  what bills outside the Azure spending limit, and what teardown deliberately leaves alone
- [Layer playbooks L01–L12](docs/runbooks/layers/) · [demo script](docs/runbooks/demo-script.md)
- Finding register — [2026-08-22 → 09-03](docs/findings/2026-09-03-finding-register.md) ·
  [2026-09-04](docs/findings/2026-09-04-finding-register.md). A dated archive of every
  defect found while building this, including the diagnoses that turned out to be wrong
  and the ones still open. Kept because a register that edits its own history is not
  evidence
- [Working agreements for all agents](CLAUDE.md)
## Run locally

The apps and the MCP tool layer run in **local data mode** — no Azure, no credentials, no
tenant. Requires Node 20+ and Python 3.11+.

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

**What you cannot run locally, stated plainly.** The *agent* is **cloud-only**: Microsoft
Copilot Studio has no local runtime, so it cannot be started, tested or demoed on a laptop.
It needs the tenant, a Power Platform environment and a published agent.

Everything around it runs locally — all three frontends including the compliance board, the
shared renderer, and the **MCP tool layer** with its six tools and their tests, which is
where the copilot's data access actually lives. The golden-question eval runs locally
against those tools, and in CI against the deployed agent over Direct Line. That is the
cost of keeping all runtime LLM work inside the Microsoft landscape, and it is worth
knowing before you plan an afternoon around iterating on the agent.

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

**What the board says, collected 2026-09-04:**

| | COMPLIANT | PARTIAL | GAP | INCONCLUSIVE | NOT_APPLICABLE | NOT_ASSESSED |
|---|---|---|---|---|---|---|
| **of 110 requirements** | **0** | 15 | 1 | 0 | 0 | **94** |

Plus four out-of-catalog rows keyed on 800-53 control ids the 800-171 catalog has no
requirement for, counted separately so the 110 stays arithmetic.

**One caveat, because omitting it would be the exact failure this board exists to
prevent.** The nightly collection runs and opens a pull request, and that pull request
cannot merge on its own: a `GITHUB_TOKEN` push triggers no workflow runs, so no required
check ever reports. State therefore reaches `main` when someone collects it deliberately,
which is how the snapshot above got here. The automation is real and the merge step is
not, and a board whose selling point is *"the history is a git history"* is the wrong
place to be quiet about that.

**A compliance dashboard that showed green would be worthless.** This estate is deployed,
audited and rebuildable, and the number that matters is still zero: of 110 requirements,
**0 are machine-verified**. Sixteen carry a human assertion and render as `asserted`. That
is the whole product:

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
  trend view says so in those words rather than drawing a flat line.

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

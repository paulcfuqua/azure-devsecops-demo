# G1 Master Plan — Meridian Launch Systems Demo

> **For agentic workers:** This is the program-level plan the human approves once at G1.
> Each layer below is decomposed into a full task-level implementation plan (superpowers
> writing-plans format, TDD granularity) by its workstream lead **when the layer
> unblocks**, saved as `docs/superpowers/plans/L<NN>-<name>.md`, and executed via
> superpowers:subagent-driven-development inside that lead's worktree. Do not begin a
> layer without Orchestrator unblock + Verifier sign-off on the previous layer.

**Goal:** Instantiate, verify, and tear down an enterprise-grade, launch-industry-themed
Azure environment entirely from this repo, with three demoable showpieces (copilot,
control tower, self-healing pipeline) and <$5/month idle cost.

**Architecture:** GitHub Actions (OIDC) drives Bicep/AVM, Graph PowerShell, S&C
PowerShell, and Fabric REST against one demo subscription; every layer ships
deploy + teardown + independent verification; tenant-level objects persist across the
standard kill/rebuild cycle (spec F6).

**Tech stack:** Bicep + Azure Verified Modules, GitHub Actions, Microsoft Graph
PowerShell, ExchangeOnlineManagement, Fabric REST API, Python 3.14 (data generators),
Node 24 + React + Fluent UI v9 + TypeScript (apps), Anthropic API (pending G1 decision),
Trivy, ZAP, Syft/sbom-tool, OpenTelemetry.

**Spec:** `docs/superpowers/specs/2026-08-22-azure-devsecops-demo-design.md`
**Decision record:** `docs/BRIEF.md`

## Global constraints

- No Azure/Entra/Fabric/GitHub-org writes before G1 approval; per-layer unblock rules in
  `CLAUDE.md` apply thereafter.
- Idle run-rate < $5/month; active demo ≤ ~$1.20/hour + LLM tokens; any spend-profile
  increase is G2-gated. Budget backstop: $75/month with alerts (G0 item B6).
- Standard kill/rebuild path: delete RGs `mls-rg-{platform,apps,data,ops}` + Fabric
  workspace items; tenant objects persist; rebuild < 60 minutes wall-clock (proven L11).
- Every resource name from `infra/bicep/naming.bicep`; required tags `env`, `app`,
  `costCenter`, `owner`, `dataClassification`, `managedBy=iac` (deny-enforced on RGs).
- Synthetic data only; deterministic generator seed `20260822` so Verifier expectations
  are exact.
- CI on `ubuntu-latest` bash; local orchestration PowerShell 7; no Windows PowerShell
  5.1 assumptions.

---

## Repo structure (approved shape — monorepo, pending G1 Q1)

```
azure-devsecops/
├── CLAUDE.md                      # working agreements (all agents load this)
├── README.md
├── .claude/
│   ├── settings.json              # agent-teams env (committed)
│   └── agents/                    # team charters: verifier, 4 leads
├── .github/workflows/
│   ├── infra-up.yml               # layer-ordered full instantiation (workflow_dispatch)
│   ├── infra-down.yml             # RG-scoped teardown (frictionless by design)
│   ├── layer-<nn>-*.yml           # per-layer deploy, called by infra-up
│   ├── app-<name>-ci.yml          # path-filtered per-app build/test/scan/deploy
│   ├── codeql.yml, sbom.yml, zap.yml
│   └── self-heal.yml              # showpiece #3
├── docs/
│   ├── BRIEF.md                   # decision record
│   ├── runbooks/                  # g0-bootstrap, demo-script, kill-rebuild
│   └── superpowers/{specs,plans}/ # this plan + per-layer plans
├── infra/
│   ├── bicep/                     # naming.bicep + layers: landing-zone/, platform/, apps/
│   ├── entra/                     # manifest JSON + Graph PS apply scripts
│   ├── purview/                   # label taxonomy + S&C PS apply scripts
│   ├── fabric/                    # workspace/lakehouse REST scripts
│   └── policy/                    # tag enforcement, guardrails, NIST assignment
├── scripts/
│   ├── bootstrap/                 # G0: 01-root-oidc, 02-fabric-capacity, 03-budget, verify-g0
│   ├── up.ps1 / down.ps1          # local wrappers over the two infra workflows
│   └── defender/                  # toggle-containers-plan.ps1 (G2-gated)
├── data/
│   ├── generators/                # python: launches, scrubs, telemetry, parts, suppliers
│   └── seed/                      # SQL + lakehouse loaders (deterministic seed 20260822)
├── apps/
│   ├── shared/spec-renderer/      # JSON spec → Fluent UI v9 (8–10 components) + schema
│   ├── launch-ops/                # showpiece data app
│   ├── control-tower/             # Dev/Sec/Ops tabs
│   ├── copilot-svc/               # LLM tool-use service (Node/TS)
│   └── vuln-lab/                  # seeded vulnerable deps for self-healing (F5)
└── verification/
    ├── layer-<nn>-audit.ps1       # Verifier-only, runs as mls-verifier (Reader)
    └── reports/                   # committed audit outputs
```

## Team topology → Claude Code mapping

| Brief role | Implementation |
|---|---|
| Orchestrator | Main session (this one, post-restart with agent teams active) |
| Verifier | Persistent teammate from `.claude/agents/verifier.md`; own worktree; runs only `verification/` as `mls-verifier` |
| 4 workstream leads | Persistent teammates from `.claude/agents/*-lead.md`; own worktrees; merge via PR |
| ICs (2–5 per lead) | Disposable subagents spawned by leads; **no SendMessage access**; author-only |

Escalation and gate rules as in `CLAUDE.md`. Restarting stalled teammates: Orchestrator
watches lead idle state; Verifier watches the Orchestrator (G4 on deadlock).

---

## Layer plan

Legend per layer: **Lead** → deliverables → **Verify** (independent audit criteria, run
by Verifier as `mls-verifier`) → **Teardown** artifact → **Cost delta**.

### L0 — Toolchain + G0 authoring (Platform; local only, no cloud writes)

Install az CLI + Bicep, PowerShell 7, Microsoft.Graph, ExchangeOnlineManagement via
winget/PSGallery; author `scripts/bootstrap/01-03 + verify-g0.ps1`; author
`.claude/agents/` charters (done pre-G1); hand the human the G0 runbook.
**Verify:** `verify-g0.ps1` passes end-to-end under the human's login: CLI authenticated;
`mls-github-deployer` federated + Owner + consented Graph scopes; `mls-verifier` present;
Fabric capacity visible with SP API enabled; licenses assigned; $75 budget exists.
**Teardown:** n/a (local). **Cost:** $0.

### L1 — Repo skeleton, OIDC wiring, up/down pipelines (Platform)

Public GitHub repo created and pushed; naming module + tag taxonomy; `infra-up.yml` /
`infra-down.yml` skeletons with OIDC login job; GitHub environments (`demo`) holding
tenant/sub IDs as variables; secret scanning + push protection on; branch protection
with required checks; gitleaks in CI.
**Verify:** Actions run using OIDC succeeds (`az account show` inside the runner matches
the demo sub); `gh api repos/{repo}` shows secret scanning + push protection enabled; no
committed IDs (grep audit); federated credential subject matches `repo:<owner>/<repo>`.
**Teardown:** repo persists (it IS the product). **Cost:** $0 (public repo, free
minutes).

### L2 — Landing zone: management groups, policies, NIST (Identity & Governance)

MG `mls` under tenant root; demo subscription moved under it; policy assignments: tag
deny on RGs + tag-inherit modify on resources; allowed-locations; NIST 800-53 R5
initiative (audit mode) at subscription scope.
**Verify:** `az account management-group show mls` shows the sub; creating an untagged
canary RG **fails** with policy denial (then cleaned up); `az policy state summarize`
returns NIST compliance data within 30 min of assignment.
**Teardown:** `infra/policy/teardown.ps1` removes assignments + MG (G3 — tenant-level;
standard cycle leaves them).
**Cost:** $0.

### L3 — Entra layer: users, groups, CA, app registrations (Identity & Governance)

Manifest-driven (`infra/entra/manifest.json`): 5 fictional users (flight ops, security
analyst, SRE, finance, exec), 4 groups, app registrations for the three apps, CA
policies (require MFA for admins; block legacy auth) **created in report-only mode**;
EMS E5 licenses assigned via group licensing.
**Verify:** Graph queries (as `mls-verifier`, read-only) confirm object counts, group
memberships, CA policy state == `enabledForReportingButNotEnforced`, license assignment
state == success for all 5.
**Teardown:** `infra/entra/teardown.ps1` (G3); standard cycle: idempotent
create-if-absent replay, no-ops in seconds.
**Cost:** $0 (trial licenses).

### L4 — Purview sensitivity labels (Identity & Governance)

Taxonomy Public / Internal / Confidential / Export-Controlled via S&C PowerShell;
auto-label policy for the lakehouse workspace documented (applied where licensing
allows).
**Verify:** `Get-Label` returns the 4 labels with expected GUIDs recorded to
`verification/reports/`; labels survive a kill/rebuild cycle (checked again at L11).
**Teardown:** G3-gated script; standard cycle: persist (brief requirement).
**Cost:** $0.

### L5 — Fabric workspace, lakehouse, generators, seeding (Data & Copilot)

Workspace `mls-operations` on the F2 capacity (resumed for deploy — **G2 each resume**);
lakehouse with the 10 Delta tables from the spec; Python generators (seed `20260822`,
realistic messiness: scrub cascades, weekday launch bias, supplier lead-time
outliers); seed run; capacity re-paused.
**Verify:** Fabric REST: workspace + lakehouse exist; table list matches manifest; SQL
analytics endpoint returns expected row counts (e.g. `launches` = 1,200 ± 0 — seed is
deterministic); capacity state == `Paused` after layer completes.
**Teardown:** workspace-item delete script (standard cycle) — labels/capacity persist.
**Cost:** ~$0.36/hr only while resumed (~2 hr for seed ≈ $0.75/run).

### L6 — Core platform: ACA env, SQL, observability, cost exports (Platform)

Bicep/AVM: Container Apps environment + workspace-based App Insights + Log Analytics;
Azure SQL serverless (auto-pause 60 min, min 0.5 vCore) per app DB; storage for cost
exports; Cost Management daily export → storage → Function (consumption) → lakehouse
`cost_daily`; Key Vault (LLM key reference).
**Verify:** ARM GET on each resource: SKU/serverless/auto-pause/minReplicas values match
manifest exactly; KQL query against LAW succeeds as verifier; first cost export file
lands within 24 h (async check L7 window); SQL auto-pauses (checked after 75 min idle).
**Teardown:** in `mls-rg-platform` — RG delete, gate-free.
**Cost:** idle ≈ $2–4/month (SQL storage + LAW retention); active SQL ~$0.10–0.50/hr.

### L7 — Apps: spec-renderer, launch-ops, control tower, per-app CI (Data & Copilot + Platform)

`spec-renderer` library with JSON schema + 8–10 Fluent components + Storybook + unit
tests; `launch-ops` (SQL-backed CRUD + lakehouse-backed analytics views); `control-tower`
Dev/Sec/Ops tabs on live APIs; OTel wiring; path-filtered CI per app (build, test,
Trivy image scan, deploy to ACA via OIDC).
**Verify:** public endpoints return 200 with correct content hash markers; renderer
schema validation passes on golden specs; OTel spans from a synthetic request visible in
App Insights via KQL; per-app CI green on a canary PR; replicas scale 0→N→0.
**Teardown:** in `mls-rg-apps` — RG delete.
**Cost:** ~$0.10–0.30/hr while serving; $0 idle.

### L8 — Copilot service (Data & Copilot)

Tool-use loop (provider per G1 Q2) with the 5 tools from the spec; JSON component-spec
output validated against renderer schema before return; golden-question eval suite
(≥10 questions with exact expected answers derivable from the deterministic seed, e.g.
"which day of the week has the most launches" → Saturday per generator bias).
**Verify:** eval suite passes ≥ 9/10 with valid schema output and SQL that the Verifier
re-executes against the lakehouse to confirm the numbers; no tool call outside the
allowlist; p95 latency < 20 s.
**Teardown:** in `mls-rg-apps`.
**Cost:** LLM tokens only (~$1–5/demo day).

### L9 — DevSecOps chain (DevSecOps)

CodeQL (JS/TS + Python), Dependabot config, secret scanning confirmed, SBOM (SPDX via
Syft) attached to releases, Trivy gate (fail on CRITICAL), ZAP baseline vs staging URL,
Defender toggle scripts (`Containers` plan — G2 on enable), control-tower feeds wired to
GitHub Security + Defender APIs.
**Verify:** GitHub API shows all GHAS features enabled; a seeded CRITICAL image fails CI
(negative test) then passes after pin; SBOM artifact present + SPDX-valid; ZAP report
artifact exists with 0 High; Defender plan toggles on→off leaving state `Off`.
**Teardown:** config-as-code; Defender left Off; nothing billable persists.
**Cost:** $0 idle; Defender ~$0.29/day only while toggled on (G2 each time).

### L10 — Self-healing pipeline (DevSecOps)

`vuln-lab` seeded with 3 known-vulnerable dependency pins (real CVEs, patch available);
`self-heal.yml`: Dependabot/CodeQL alert → Claude triage (explanation comment) → patch
PR → CI gauntlet (CodeQL, tests, Trivy, ZAP) → auto-merge on green → deploy → alert
closed.
**Verify:** full chain observed via API trail for at least 2 of 3 seeded vulns: alert
created → PR with triage comment → checks green → merged by automation → new ACA
revision → alert state `fixed`. Human sees the PR trail only (per brief).
**Teardown:** re-seed script restores vulnerable pins for the next demo.
**Cost:** LLM tokens (~$0.50/heal) + CI minutes ($0 public).

### L11 — Kill/reinstantiate proof (Platform, Verifier-audited)

`down.ps1` (deletes 4 RGs + Fabric workspace items, pauses capacity) → Verifier
confirms empty + idle cost profile → `up.ps1` (replays L2–L10 pipelines + seed) →
Verifier re-runs **every** layer audit → wall-clock report committed to
`verification/reports/rebuild-proof.md`.
**Verify:** all RGs absent post-down; tenant objects intact (L3/L4 audits still pass);
post-up: all layer audits green; wall-clock < 60 min; run-rate returns to idle profile.
**Teardown:** is the deliverable.
**Cost:** ~$1–2/cycle.

---

## Projected cost envelope

| State | Run-rate | Composition |
|---|---|---|
| Torn down (steady idle) | **< $5/month** | OneLake storage (¢), LAW retention, Key Vault, budget/export plumbing |
| Built but parked | < $15/month | + SQL storage ~$2, storage accounts ~$1, LAW ~$5 |
| Active demo | **~$0.60–1.20/hour** | Fabric F2 $0.36/hr + SQL serverless $0.10–0.50/hr + ACA $0.10–0.30/hr (+ Defender ~$0.01/hr if toggled) |
| LLM usage | $1–5/demo day | copilot + self-heal triage (Anthropic API, pending Q2) |
| Build/rebuild cycle | ~$1–2 each | Fabric resume window + CI (free on public repo) |
| Licensing | $0 for 90 days | EMS E5 trial; after trial: ~$9/user/mo × 6 if kept, or descope per spec F1 |
| **Worst-case monthly** (4 demo days + weekly rebuilds, in-trial) | **≈ $40–60** | backstopped by $75 budget + alerts (G0 B6) |

## Risk register (top 5)

1. **Licensing not activated** → L3/L4 partially blocked → degrade path pre-agreed (spec F1); G1 Q3 decides.
2. **Entra/policy propagation lag** → layer audits include bounded retry (30 min) before G4; standard rebuild avoids tenant-object churn (spec F6).
3. **Fabric SP API toggle missed at G0** → L5 fails fast at `verify-g0.ps1`, before any spend.
4. **Cost anomaly** (runaway SQL wake, capacity left resumed) → budget alerts + Verifier checks capacity state at every layer close → G4.
5. **Agent-team deadlock/stall** → Orchestrator restarts leads; Verifier restarts Orchestrator; G4 to human on repeat.

## Execution protocol after G1

1. Human completes G0 checklist items B1–B6 (`docs/runbooks/g0-bootstrap.md`); restarts
   the Claude Code session (activates agent teams).
2. Orchestrator spawns Verifier + 4 leads from `.claude/agents/`; L0 runs immediately
   (local toolchain, no cloud writes).
3. Per layer: lead authors `docs/superpowers/plans/L<NN>-<name>.md` (full task-level TDD
   plan) → ICs execute in worktrees → PR to main → deploy workflow → Verifier audit →
   Orchestrator unblocks next layer. Two consecutive audit failures on one layer = G4.
4. G2/G3 prompts flow through the Orchestrator with cost/scope stated each time.

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
Node 24 + React + Fluent UI v9 + TypeScript (apps), Microsoft Copilot Studio + Fabric
data agent + MCP (Streamable HTTP) for showpiece #1, GitHub Copilot Autofix for
showpiece #3, Trivy, ZAP, Syft/sbom-tool, OpenTelemetry.

**Spec:** `docs/superpowers/specs/2026-08-22-azure-devsecops-demo-design.md`
**Decision record:** `docs/BRIEF.md`
**Amendment in force:** `docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md`

> **G1 status (2026-08-22):** sponsor approved the plan's shape and locked the three
> open decisions (monorepo / Anthropic API / dual E5 trials), and amended execution:
> **Phase P** (pre-tenant scaffold — see
> `2026-08-22-phase-p-pre-tenant-scaffold.md`) runs first with zero cloud writes;
> layers L1+ deploy only after the sponsor activates the tenant (G1b) and G0
> completes. Fabric plan updated: 60-day trial capacity first; paid F2 via G2 later.
>
> **Amended 2026-08-24 (sponsor-directed):** the LLM-provider decision is **void**.
> All runtime LLM work moves inside the Microsoft landscape — L8 is rebuilt as a
> custom **Copilot Studio** agent, L10 on **GitHub Copilot Autofix**, and no Anthropic
> API key exists anywhere in the system. L8's and L10's entries, the cost envelope and
> the risk register below are rewritten accordingly; every other layer is unchanged.

## Global constraints

- No Azure/Entra/Fabric/GitHub-org writes before G1 approval; per-layer unblock rules in
  `CLAUDE.md` apply thereafter.
- Idle run-rate < $5/month; active demo ≤ ~$1.20/hour + Copilot Credits consumed; any
  spend-profile increase is G2-gated. Budget backstop: $75/month with alerts (G0 item
  C8) — Copilot Studio pay-as-you-go bills to the same Azure subscription, so it sits
  inside that budget.
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
azure-devsecops-demo/
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
│   ├── fabric/                    # workspace/lakehouse + data-agent REST scripts
│   ├── copilot-studio/            # exported agent solution (unpacked) + ALM workflows
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
│   ├── mcp-tools/                 # 5 ops/sec/cost tools as an MCP server (Node/TS)
│   ├── directline-token/          # Function: Key Vault secret → short-lived chat token
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
`cost_daily`; Key Vault (holds the Direct Line secret the control tower's managed
identity reads at runtime to mint short-lived chat tokens — never a CI secret).
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

### L8 — Copilot: custom Copilot Studio agent (Data & Copilot)

Custom **Microsoft Copilot Studio agent**, authored as a Power Platform solution, held
unpacked in `infra/copilot-studio/` and deployed by pipeline on Microsoft's
[`copilot-alm-starter`](https://github.com/microsoft/copilot-alm-starter) Actions
pattern (export → unpack → PR → import; federated credentials, no stored CI secret) —
the repo stays source of truth. Four parts:

- **Knowledge — Fabric data agent** over the `mls_operations` lakehouse, attached to the
  Copilot Studio agent as a *connected agent* for native NL2SQL
  ([preview](https://learn.microsoft.com/en-us/fabric/data-science/data-agent-microsoft-copilot-studio);
  requires **paid F2 or higher** — Fabric trial capacity does not support data agents,
  see risk 6 and the L8 playbook's fallback).
- **Tools — MCP server** on the L6 Container Apps environment carrying the same five
  tools (`query_lakehouse_sql`, `query_log_analytics`, `get_github_security`,
  `get_defender_posture`, `get_cost_series`), attached over **Streamable HTTP**
  ([SSE is unsupported in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/mcp-add-existing-server-to-agent)),
  authenticated with Entra ID via OAuth 2.0.
- **Surface — Direct Line embed** in the control tower's **Ask** tab; a small
  consumption-plan Function (`apps/directline-token`) reads the Direct Line secret from
  Key Vault with its managed identity and exchanges it for short-lived,
  origin-pinned chat tokens. The browser holds no credential.
- **Answer format — Adaptive Cards** (declarative JSON, [derived] pinned to schema
  **1.5** and `Action.Submit` only so one card renders identically in the Direct Line
  Web Chat embed and in Teams). Never generated UI code. `@mls/spec-renderer` remains
  the contract for the apps' own dashboards.

Plus the golden-question eval suite (≥ 10 questions with exact expected answers derived
from the deterministic seed `20260822`, e.g. "which day of the week has the most
launches" → Saturday per generator bias), re-pointed at the deployed agent over Direct
Line.

**Verify:** deployed agent's solution unique name + version + component list match the
committed solution exactly, and its published state is current; eval suite passes ≥ 9/10
against the deployed agent, with each answer's number independently re-derived by the
Verifier from the lakehouse; no tool invoked outside the five-tool allowlist and the
agent declares exactly those five; every visual answer is an Adaptive Card payload that
validates against the pinned Adaptive Cards schema (zero HTML/JS/JSX in any response);
p95 latency < 20 s.
**Teardown:** MCP server lives in `mls-rg-apps` (RG delete, gate-free). The Power
Platform **environment, its pay-as-you-go billing link, the agent and its solution are
not RG-scoped — deleting any of them is G3** and the standard kill/rebuild cycle leaves
them in place, exactly as it leaves Entra objects and the Fabric workspace shell.
**Cost:** Copilot Credits on the pay-as-you-go meter, **$0.01/credit** billed to the
same Azure subscription and drawing on the same $200 credit; **no idle charge** — an
unused agent consumes nothing. [derived] At the published rates (generative answer 2
credits, agent action 5) a tool-backed question costs ≈ 7 credits ≈ $0.07, so an eval
run ≈ $0.70 and a demo day ≈ $1–3.

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

### L10 — Self-healing pipeline on GitHub Copilot Autofix (DevSecOps)

No authored triage script: GitHub's own AI generates the fix. Two tracks, because the
two finding types are healed by two different GitHub mechanisms — Copilot Autofix
[covers CodeQL code-scanning alerts, not Dependabot alerts](https://docs.github.com/en/code-security/code-scanning/managing-code-scanning-alerts/responsible-use-autofix-code-scanning):

- **Code track.** `vuln-lab` seeds one CodeQL-detectable JS/TS flaw. `self-heal.yml`
  fires on `code_scanning_alert`, calls the Autofix REST API (`POST …/autofix` → poll
  `GET …/autofix` until `success` → `POST …/autofix/commits` onto a heal branch), opens
  the PR carrying Autofix's own explanation, and flags it for auto-merge.
- **Dependency track.** `vuln-lab` keeps its 3 known-vulnerable pins (real CVEs, patch
  available);
  [Dependabot security updates](https://docs.github.com/en/code-security/dependabot/dependabot-security-updates/about-dependabot-security-updates)
  raise the patch PRs unassisted and the alert closes when the PR merges.

Both tracks then run the identical L9 gauntlet (CodeQL, tests, Trivy, ZAP) → auto-merge
on green → deploy → alert closed. Auto-merge on green inside the demo environment stays
intentional; the human sees the PR trail, not an approval prompt.

**Verify:** for the seeded CodeQL alert, the full Autofix trail holds — alert created →
autofix status `success` → PR whose head commit is the Autofix commit and whose body
carries Autofix's explanation → gauntlet checks all green → merged by automation (no
human merger) → new ACA revision → alert state `fixed`, timestamps monotonic; and for at
least 2 of the 3 seeded dependency pins, the Dependabot trail holds — alert created →
Dependabot patch PR → gauntlet green → merged by automation → new ACA revision → alert
state `fixed`.
**Teardown:** re-seed script restores the vulnerable pins and the seeded code flaw for
the next demo.
**Cost:** $0 — [Copilot Autofix is GA and free on all public repositories](https://github.blog/changelog/2024-09-17-now-available-for-free-on-all-public-repositories-copilot-autofix-for-codeql-code-scanning-alerts/)
and needs no Copilot subscription; CI minutes are free on a public repo.

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
| Copilot Studio | **$0 idle; ≈ $1–3/demo day** | Copilot Credits, pay-as-you-go at **$0.01/credit** billed through the **same Azure subscription** (so it draws on the same $200 credit and sits inside the $75 budget). No licence commitment, no reservation, **zero idle cost** — an agent nobody talks to consumes nothing. [derived] day estimate from the published rates: generative answer 2 credits, agent action 5, so a tool-backed question ≈ 7 credits ≈ $0.07; a 10-question eval ≈ $0.70 |
| Self-healing | **$0** | Copilot Autofix is free on public repos and needs no Copilot subscription; Dependabot and CI minutes free on public repos |
| Build/rebuild cycle | ~$1–2 each | Fabric resume window + CI (free on public repo) |
| Licensing | $0 during trials | M365 E5 (30 d) + EMS E5 (90 d); after trials: EMS E3 ≈ $11/user/mo or E5 ≈ $16/user/mo × 6 if kept, or descope per spec F1. Copilot Studio authoring adds **$0**: the *Copilot Studio authors* role in the Power Platform admin center grants authoring with no licence purchase, and the pay-as-you-go meter covers runtime (G0 § B) |
| **Worst-case monthly** (4 demo days + weekly rebuilds, in-trial) | **≈ $40–60** | backstopped by $75 budget + alerts (G0 C8) |

**One envelope change the amendment forces:** the Fabric data agent requires a **paid F2
or higher** capacity — the 60-day trial capacity explicitly does not support data agents.
The trial-first plan therefore covers L5 but *not* L8's Fabric knowledge source. Either
the G2 move to paid F2 happens before the L8 demo (≈ $0.36/hr while resumed, pause
unchanged), or L8 runs in its documented tools-only fallback (MCP over the lakehouse SQL
analytics endpoint), which costs nothing extra and works on the trial capacity.

## Risk register (top 7)

1. **Licensing not activated** → L3/L4 partially blocked → degrade path pre-agreed (spec F1); G1 Q3 decides.
2. **Entra/policy propagation lag** → layer audits include bounded retry (30 min) before G4; standard rebuild avoids tenant-object churn (spec F6).
3. **Fabric SP API toggle missed at G0** → L5 fails fast at `verify-g0.ps1`, before any spend.
4. **Cost anomaly** (runaway SQL wake, capacity left resumed) → budget alerts + Verifier checks capacity state at every layer close → G4.
5. **Agent-team deadlock/stall** → Orchestrator restarts leads; Verifier restarts Orchestrator; G4 to human on repeat.
6. **Preview dependency: Fabric data agent → Copilot Studio** (new, 2026-08-24). The
   integration is explicitly
   [preview](https://learn.microsoft.com/en-us/fabric/data-science/data-agent-microsoft-copilot-studio):
   it can change, be region-limited, or be withdrawn, its responses may leave Fabric's
   compliance boundary/region, it needs the *cross-geo processing and storing for AI*
   tenant settings on, and Microsoft states the connected-Fabric-data-agent combination
   is **only validated for Microsoft Teams** — "other channels may also work but haven't
   been formally tested", which includes this demo's Direct Line embed. Compounding it,
   [data agents need paid F2+ and are not supported on trial capacity](https://learn.microsoft.com/en-us/fabric/fundamentals/fabric-trial).
   **Mitigation, carried in the L5 and L8 playbooks:** the agent keeps working without
   the Fabric knowledge source — drop the connected data agent and answer lakehouse
   questions through the MCP server's `query_lakehouse_sql` tool against the SQL
   analytics endpoint. The eval suite is written so both paths must produce the same
   golden answers, so the fallback is a configuration switch, not a rebuild. Second
   fallback if Direct Line proves unreliable specifically with the connected data agent:
   demo the agent in Teams (the validated channel) and keep the Ask tab on the
   tools-only path.
7. **Agent surface drifts from the repo** (new, 2026-08-24). A Copilot Studio agent is
   editable in a browser, which is exactly the "manual portal configuration" principle 1
   forbids. Mitigation: the solution is exported and imported by pipeline only, and V8.1
   fails the layer if the deployed solution version or component list differs from the
   committed one — portal edits are detected, not trusted.

## Execution protocol after G1

1. Human completes G0 checklist items C1–C8 (`docs/runbooks/g0-bootstrap.md`); restarts
   the Claude Code session (activates agent teams).
2. Orchestrator spawns Verifier + 4 leads from `.claude/agents/`; L0 runs immediately
   (local toolchain, no cloud writes).
3. Per layer: lead authors `docs/superpowers/plans/L<NN>-<name>.md` (full task-level TDD
   plan) → ICs execute in worktrees → PR to main → deploy workflow → Verifier audit →
   Orchestrator unblocks next layer. Two consecutive audit failures on one layer = G4.
4. G2/G3 prompts flow through the Orchestrator with cost/scope stated each time.

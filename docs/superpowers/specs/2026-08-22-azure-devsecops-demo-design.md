# Design Spec: Agent-Team-Built Azure DevSecOps Demo

**Date:** 2026-08-22
**Status:** Presented at G1 (pending sponsor approval)
**Decision record:** [docs/BRIEF.md](../../BRIEF.md) — the brief is authoritative; this
spec records the pressure-test of that brief, the resolutions adopted, and the small set
of decisions left open for G1.

## 1. What we are building (one paragraph)

A monorepo that instantiates a fictional launch company's ("Meridian Launch Systems",
prefix `mls`, renameable via one naming variable) enterprise Azure estate: a mini landing
zone with NIST 800-53 governance, an Entra identity layer, Purview sensitivity labels, a
Fabric lakehouse fed by synthetic launch-industry data, a Container Apps platform running
two Fluent UI apps and an LLM copilot service, a full DevSecOps chain (GHAS, SBOM, Trivy,
ZAP, Defender toggles), and a self-healing pipeline. Everything deploys through GitHub
Actions via OIDC, verifies through an independent Verifier agent, and tears down to
near-zero idle cost in one command.

## 2. Pressure-test findings and resolutions

The brief was pressure-tested before planning. Findings, in order of consequence:

### F1 — Licensing is a hidden G0 dependency (HIGH)

The brief's G0 lists tenant, subscription, OIDC root, and Fabric F2 — but three planned
features have licensing prerequisites the brief does not name:

| Feature | Requires | Without it |
|---|---|---|
| Conditional Access policies (Layer 3) | Entra ID P1 | CA policy creation fails |
| Entra sign-in risk feed (control tower Sec tab) | Entra ID P2 (Identity Protection) | Panel has no data source |
| Purview sensitivity labels via S&C PowerShell (Layer 4) | Purview Information Protection (M365 E3/E5, EMS E3/E5, or Business Premium) | `New-Label` unavailable; S&C endpoint needs an Exchange-backed tenant |

**Resolution adopted:** add one item to G0 — activate an **EMS E5 trial** (free, covers
Entra P2 + Information Protection P2 in a single SKU) or equivalent. If the sponsor
declines, the degrade path is: CA policies authored but marked `notDeployable` (shown as
code in the demo narrative), sign-in-risk panel replaced by sign-in *activity* (free
Graph API), and Purview layer descoped to a documented design. Degrade choice is a G1
question.

### F2 — Fabric service-principal API access is a tenant toggle (HIGH)

Fabric REST APIs reject service principals unless the Fabric admin portal tenant setting
"Service principals can use Fabric APIs" is enabled, and the SP must be a capacity/
workspace admin. **Resolution:** added to the G0 checklist (one-time portal toggle,
human-only, ~2 minutes). All Fabric automation is written against SP auth from day one.

### F3 — Monorepo vs multi-repo (G1 DECISION)

The brief says "the repo is the product" (singular) but also "GitHub repos" (plural).
**Recommendation: single public monorepo.** Rationale: atomic kill/rebuild (principle 2),
one PR trail for the self-healing showpiece, one source of truth (principle 1), per-app
CI achieved with path-filtered workflows. Multi-repo is more enterprise-real but puts the
<1 hr rebuild and the demo narrative at risk for zero functional gain. GHAS features used
(CodeQL, Dependabot, secret scanning + push protection) are free on public repos and are
enabled per-repo either way.

### F4 — LLM provider for copilot + self-healing (G1 DECISION)

**Recommendation: Anthropic API direct** (claude-sonnet-5 for the copilot tools loop;
the self-healing workflow already assumes Claude API per the brief). One key serves both.
Azure AI Foundry remains the alternative if "everything on Azure" matters more to the
demo story than model quality; it adds a Foundry resource, quota requests, and a second
SKU to manage. The key is a stored secret (GitHub Actions secret + Key Vault reference) —
a documented, deliberate exception to "no stored cloud secrets in CI": OIDC covers all
*Azure* auth; a third-party SaaS key has no OIDC path.

### F5 — Public repo hygiene (MEDIUM)

Public monorepo means: tenant ID, subscription ID, and capacity IDs are kept in GitHub
environment variables (not committed — they are not secrets, but committing them invites
clone-and-probe noise); secret scanning + push protection enabled in Layer 1 before any
cloud code lands; the intentionally-vulnerable dependencies for the self-healing demo are
isolated in `apps/vuln-lab/` with a README stating their purpose (standard practice for
security demos; they are vulnerable *dependencies*, not exploit code).

### F6 — "Under an hour" rebuild vs Entra/label propagation (MEDIUM)

Entra object creation, CA policy propagation, and label replication can each lag 15–45
minutes — a from-absolute-zero rebuild cannot promise <60 min. **Resolution (consistent
with the brief's own teardown definition):** the standard kill/rebuild path deletes demo
RGs + Fabric workspace items only; tenant-level objects (Entra users/groups/CA, labels,
OIDC federation) persist and their scripts are idempotent create-if-absent, so replay
skips them in seconds. The <60 min SLA applies to this path (Layer 11 proves it). Full
tenant-object teardown remains available behind G3 with an honest 2–3 hr rebuild SLA.

### F7 — "Human-only G0" refined to "agent-authored, human-executed" (LOW)

To keep principle 1 (repo as source of truth), agents author `scripts/bootstrap/*` for
every G0 step that can be scripted (root app registration + federation + role grant +
admin consent URL, Fabric capacity create, budget alert). The human runs them under their
own login. Agents never execute G0 steps; the runbook says exactly what to run.

### F8 — Verifier independence needs its own credential (LOW)

"Never trusts a teammate's self-report" is hollow if the Verifier authenticates with the
same Owner SP the deployers use. **Resolution:** Layer 1 creates a second app
registration `mls-verifier` with Reader on the subscription + `Directory.Read.All` +
GitHub read token, used exclusively by the Verifier. Audit scripts live in
`verification/` and are the only code the Verifier runs.

### F9 — Windows dev host vs CI runners (LOW)

CI runs on `ubuntu-latest` (bash); local orchestration scripts target PowerShell 7
(`pwsh`), installed in Layer 0 alongside az CLI, Bicep, Graph + ExchangeOnlineManagement
modules. No script may assume Windows PowerShell 5.1.

### F10 — Defender for Containers on ACA (LOW)

Defender coverage for Container Apps is via the subscription-level Defender for Cloud
plans (agentless posture + registry scanning), not the AKS-style agent. Toggle scripts
enable/disable the `Containers` plan at subscription scope; each enable states cost delta
at G2 (~$0.29/day prorated while on). Foundational CSPM stays on (free).

### F11 — Agent Teams requires a session restart (PROCESS)

`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is now set in `.claude/settings.json` but env
vars are read at session launch. Sequence: G1 approval → human restarts the session →
Orchestrator + Verifier + leads spawn as persistent teammates per the charters in
`.claude/agents/`. Team charters are code, committed like everything else.

## 3. Architecture summary

Per the brief's stack decisions (final, restated for one-page reference):

- **Control plane:** GitHub Actions (public monorepo) → Azure via OIDC. Bicep + AVM for
  ARM resources; Graph PowerShell for Entra; S&C PowerShell for labels; Fabric REST for
  workspace/lakehouse. Every layer: `deploy/` + `teardown/` + `verification/` triplet.
- **Governance:** management group `mls` → demo subscription; policy assignments: tag
  enforcement (deny RGs missing required tags; modify-inherit on resources), NIST 800-53
  R5 initiative (audit mode), guardrails (allowed locations, no public IPs outside ACA).
- **Data plane:** Fabric F2 (paused idle) → OneLake lakehouse `mls_operations` with
  Delta tables (launches, scrubs, vehicles, pads, telemetry_summary, parts, suppliers,
  work_orders, cost_daily, findings_history); Azure SQL serverless (auto-pause 60 min)
  per app for operational writes; nightly + on-demand sync app DB → lakehouse.
- **Compute:** one Container Apps environment; apps `launch-ops`, `control-tower`,
  `copilot-svc`, all minReplicas=0; Functions (consumption) for cost-export ingestion.
- **Copilot:** tool-use loop with tools `query_lakehouse_sql`, `query_log_analytics`,
  `get_github_security`, `get_defender_posture`, `get_cost_series`; output contract is a
  JSON component spec validated against the shared renderer schema (never generated UI
  code).
- **Observability:** OpenTelemetry SDKs → App Insights (workspace-based) → same Log
  Analytics workspace the control tower queries.

## 4. Open decisions for G1

1. **Repo shape:** monorepo (recommended, F3) vs multi-repo.
2. **LLM provider:** Anthropic API direct (recommended, F4) vs Azure AI Foundry.
3. **Licensing path:** EMS E5 trial at G0 (recommended, F1) vs degrade-gracefully scope.

## 5. Success criteria

1. All three showpieces demoable end-to-end from a cold (torn-down) start.
2. `scripts/down.ps1` → idle run-rate < $5/month; `scripts/up.ps1` → all Verifier layer
   audits green in < 60 minutes (Layer 11 proves it, wall-clock measured).
3. Every layer's deployed state matches its manifest per independent Verifier audit —
   zero manual portal actions after G0.
4. Projected spend stays inside the envelope in the master plan; any excursion trips G4.

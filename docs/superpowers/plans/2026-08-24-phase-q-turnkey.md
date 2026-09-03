# Phase Q — Turn-Key Plan (pre-tenant, cloud-path complete)

> **HISTORY — this plan was executed. It is kept as the record of what was done and why,
> not as a description of current state or of work still to do.**
>
> For what is true now, read [docs/DEMO-READINESS.md](../../DEMO-READINESS.md). For how
> each thing came to be true — including the diagnoses that turned out to be wrong — read
> [docs/findings/2026-09-03-finding-register.md](../../findings/2026-09-03-finding-register.md).
>
> Checkboxes below are left in the state they were in. An unticked box here does **not**
> mean outstanding work; it means the plan moved on. Nothing is deleted, because a plan
> that edits its own premises after the fact stops being evidence of anything.

> **Sponsor directive, 2026-08-24:** *"I don't plan on demo'ing locally, only on the
> Azure tenant… get us to the turn-key level when tenant is provisioned and we can just
> light the fuse and let it build."*

**Goal:** Finish every piece of code, script and runbook that does not strictly require a
live tenant, so that tenant activation is **configuration + execution**, never
development.

**Spec:** `../specs/2026-08-22-azure-devsecops-demo-design.md`
**Amendment in force:** `../specs/2026-08-24-amendment-copilot-studio.md`
**Predecessor:** `2026-08-22-phase-p-pre-tenant-scaffold.md` (complete)

## What changed in priority

The sponsor will not demo locally. Local mode is therefore a **test harness, not a
deliverable**. Effort moves to the cloud path: real adapters, real seeding, real
verification. We do not invest further in local polish.

## The gap Phase P left (survey, 2026-08-24)

| # | Gap | Needs tenant? |
|---|---|---|
| Q-1 | `verification/` holds **zero** audit scripts. All 11 `layer-NN-audit.ps1` are unwritten; every layer workflow calls them defensively and skips. "Verifier sign-off" is currently unenforceable. | No |
| Q-2 | The five MCP tools' **cloud adapters are typed stubs**. Includes a real SQLite→T-SQL dialect port (the shipped tool description tells the agent to use `strftime()`, which does not exist in T-SQL). | No |
| Q-3 | **`data/seed/` does not exist**; there is not one `.sql` file in the repo. No Azure SQL schema, no lakehouse Delta table creation, no loaders. | No |
| Q-4 | Both apps' `ApiProvider` fetches `/tables/…` and `/feeds/…` — **nothing serves those endpoints.** | No |
| Q-5 | **No OpenTelemetry anywhere**, though principle #5 names it and L6/L7 promise App Insights spans. | No |
| Q-6 | **Cost-export ingestion Function** unwritten; the FinOps visual has no data path. | No |
| Q-7 | `infra/fabric/teardown-items.ps1` missing → lakehouse items survive teardown. `scripts/up.ps1` / `down.ps1` documented but absent. | No |
| Q-8 | `vuln-lab` seeds only dependency CVEs → the **Copilot Autofix track has nothing to act on**. | No |
| Q-9 | `eval:agent` is a placeholder → L8 has no audit instrument. | No |
| Q-10 | `infra/copilot-studio/solution/` is empty. The Power Platform solution only exists after a first portal authoring pass. | **Yes — the only one** |

## Tracks (all parallel, clean file ownership)

- **Track V — Verifier toolkit.** `verification/`: `MlsAudit.psm1` (criterion runner,
  bounded interruptible retry per the playbooks' propagation windows, exception
  containment, Markdown + JSON reports, nonzero exit on FAIL) and the 11 layer audit
  scripts. Read-only as `mls-verifier`. Must cover exactly the 43 traceability criteria,
  verified by set comparison. Fully mock-tested.
- **Track A — MCP cloud path.** `apps/mcp-tools/`: five cloud adapters with managed
  identity, pagination, 429 backoff, shape parity with the local adapters; the T-SQL
  dialect port with `DATEFIRST` pinned; OTel spans per tool call (never SQL text or
  parameters); the real `eval:agent` Direct Line driver.
- **Track D — Data plane.** `data/seed/`: T-SQL DDL matching the generator schema
  exactly, lakehouse Delta creation + load via Fabric REST, one idempotent `seed.ps1`
  entry point; plus `infra/fabric/teardown-items.ps1`. Row counts must match the
  deterministic seed the Verifier asserts.
- **Track B — Serving layer.** New `apps/data-api/` satisfying both `ApiProvider`
  contracts verbatim, local + cloud backends, allowlisted table/feed names, plus OTel in
  data-api and both frontends, and its CI workflow.
- **Track C — Fuse and FinOps.** `apps/cost-ingest/` Function; `scripts/up.ps1` /
  `down.ps1` (the literal fuse, with wall-clock reporting for L11's <60-minute proof);
  a CodeQL-detectable flaw in `vuln-lab` so Autofix has work; and `infra-up` / `infra-down`
  reconciled to call every new piece in dependency order.

## Definition of done

1. Every gap Q-1…Q-9 closed and independently re-verified by the Orchestrator — a
   subagent's "green" is never sufficient.
2. Repo-wide gates hold: PSScriptAnalyzer **0 findings at every severity**; Pester green
   with no count regression; all npm workspaces green; actionlint 0 across every
   workflow with shellcheck active; every Bicep layer building clean.
3. **Zero cloud writes during Phase Q.** There is no tenant and no `az login`; every
   cloud interaction is mocked. This is the same discipline that held through Phase P.
4. The only work remaining at tenant time is: G0 human bootstrap, secrets/config
   population, the one-time Copilot Studio portal authoring + export (Q-10), and
   `scripts/up.ps1`.

## Known residue for tenant day

- **Q-10** — first Copilot Studio solution export. Unavoidable; documented as the single
  point where "no manual portal configuration" bends.
- **Sponsor decisions parked:** MCP server auth (API key interim vs OAuth 2.0/Entra
  target — never None); `SELF_HEAL_TOKEN`, without which `GITHUB_TOKEN`-authored PRs land
  approval-required and auto-merge-on-green cannot fire unattended.
- **Fabric connected agent needs paid F2** (trial capacity cannot host AI experiences),
  so showpiece #1 runs the tools-only MCP path until a G2 upgrade.

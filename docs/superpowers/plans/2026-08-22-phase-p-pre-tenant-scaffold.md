# Phase P — Pre-Tenant Scaffold Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.
> Track owners dispatch IC subagents per track; ICs author and test but **never commit**
> (the Orchestrator reviews and commits per track) and **never touch Azure, Entra,
> Fabric, or Microsoft Graph** — Phase P is 100% local + GitHub.

**Goal:** Author and locally validate everything that does not require the Azure tenant,
so that tenant activation is followed by configuration-and-deploy, not development.

**Approved:** sponsor, 2026-08-22 (G1 amendment). Decisions in force: monorepo,
Anthropic API, dual E5 trials, Fabric trial capacity first.

**Spec:** `docs/superpowers/specs/2026-08-22-azure-devsecops-demo-design.md`
**Master plan:** `2026-08-22-g1-master-plan.md` (layer criteria are unchanged; Phase P
pre-builds their artifacts)

## Global constraints

- Zero cloud writes. GitHub (public repo on paulcfuqua's account) is the only external
  system touched, per the locked monorepo decision.
- Every track ships with a **local validation cycle** that runs green on this machine
  (pytest / vitest / Pester / PSScriptAnalyzer / `bicep build` / actionlint). "Authored
  but unvalidated" is not done.
- Deterministic generator seed `20260822`; naming/tags per `CLAUDE.md`.
- Anything that can only be validated against a live tenant gets an explicit
  `## Deferred validation` note in its playbook naming the layer audit that will cover
  it (traceability for the Verifier later).

## Tracks

### Track A — Synthetic data platform (maps to L5) — fully local
`data/generators/` Python package: the 10 tables (launches, scrubs, vehicles, pads,
telemetry_summary, parts, suppliers, work_orders, cost_daily, findings_history) with
realistic messiness (Saturday launch bias, scrub cascades, supplier lead-time outliers,
dirty strings/nulls); writers to CSV + JSON under `data/generated/` (gitignored);
`python -m generators build` entry point. **Validate:** pytest — determinism (identical
hash for same seed), exact row counts (launches = 1,200), distribution assertions
(weekday argmax = Saturday), referential integrity.

### Track B — spec-renderer library (maps to L7/L8) — fully local
`apps/shared/spec-renderer/`: JSON Schema for component specs (bar/line/area chart,
stat card, KPI row, data table, timeline, donut, markdown block ≈ 9 components), ajv
validation util, React + Fluent UI v9 components rendering from spec. **Validate:**
vitest + testing-library green; `npm run build` clean; golden spec fixtures validate
against the schema.

### Track C — Bootstrap + governance scripts (maps to G0, L2–L5) — author + mock-test
`scripts/bootstrap/01-root-oidc.ps1`, `02-fabric-capacity.ps1` (`-Mode Trial|F2`),
`03-budget.ps1`, `verify-g0.ps1`; `infra/entra/manifest.json` + idempotent
`apply-entra.ps1` (`-WhatIf` support); `infra/purview/labels.ps1`;
`infra/fabric/*.ps1` REST wrappers. **Validate:** Pester with mocked Az/Graph/REST
calls (idempotency branches, manifest schema, error paths); PSScriptAnalyzer clean.
**Deferred validation:** live runs happen at G0/L2–L5 under the human's login.

### Track D — Runbooks + playbooks — fully local
`docs/runbooks/demo-script.md` (stage flow for the three showpieces),
`docs/runbooks/kill-rebuild.md`, and `docs/runbooks/layers/L01.md … L11.md` — each:
purpose, preconditions, deploy procedure, **validation cycle** (exact Verifier queries
+ expected values from the master plan), teardown, rollback, failure modes. No
placeholders. **Validate:** every master-plan Verify criterion appears in exactly one
layer playbook (cross-reference check).

### Track E — Bicep tree (maps to L2, L6) — author + compile locally
`infra/bicep/naming.bicep` + landing-zone, platform, and apps templates on AVM.
**Validate:** `bicep build` clean on every file; `bicep lint` no errors. **Deferred
validation:** `what-if`/deploy at L2/L6.

### Track F — Apps in local mode (maps to L7/L8) — author + run locally
`launch-ops` and `control-tower` with a `LOCAL_DATA=1` mode reading Track A's generated
JSON — browsable on localhost pre-tenant; `copilot-svc` with the 5-tool interface,
mocked tool tests, and the golden-question eval harness (live LLM runs the moment
`ANTHROPIC_API_KEY` exists — before tenant activation if the sponsor provides it);
`apps/vuln-lab` with its 3 seeded CVE pins + README. **Validate:** unit tests green;
local browse of both apps against generated data; eval harness runs in mock mode.

### Track G — GitHub + CI (maps to L1, L9) — live on GitHub, no Azure
Create public monorepo `paulcfuqua/azure-devsecops`, push, branch protection, secret
scanning + push protection, Dependabot config, CodeQL workflow, path-filtered app CI
(build/test/scan jobs live now; deploy jobs guarded behind the existence of the `demo`
environment variables so they no-op until G0). **Validate:** actionlint clean; Actions
runs green on push; GHAS features confirmed via `gh api`.

### Track H — Local toolchain (maps to L0)
winget: Bicep, PowerShell 7 (az CLI attempted; may need one UAC approval from the
sponsor); PSGallery (CurrentUser): Graph submodules, ExchangeOnlineManagement, Pester,
PSScriptAnalyzer. **Validate:** version checks recorded in
`verification/reports/toolchain.md`.

## Execution order

Wave 1 (parallel, no interdependencies): A, B, C, D, H.
Wave 2 (needs A/B/H): E, F.
Wave 3 (needs everything lintable): G.

## Open items carried out of Phase P

| # | Item | Raised by | Closes at |
|---|---|---|---|
| P-1 | `infra/bicep/apps/demo.bicepparam` target ports default to **80** (matching the `containerapps-helloworld` placeholder image). Must be repointed to each app's real container port once Track F images publish to GHCR. | Track E | L7 image wiring |
| P-2 | L2's NIST initiative assignment carries a system-assigned identity with Contributor — the built-in initiative contains deployIfNotExists/modify members that ARM rejects without an identity, even in `DoNotEnforce` mode. Verify this survives the Verifier's least-privilege review. | Track E | L2 audit |
| P-3 | Key Vault purge protection is **off** and `createMode` is parameterized so G3 teardown can purge and kill/rebuild can `recover`. Confirm this matches the L6 rollback note in practice. | Track E | L6 audit |
| P-4 | **PSScriptAnalyzer resolves from the Windows PowerShell 5.1 module path** on this host (`~/OneDrive/Documents/WindowsPowerShell/Modules`), not a pwsh 7 path. It works locally by accident of `PSModulePath`; on an `ubuntu-latest` runner it will not exist. Track G must install it explicitly in CI or the lint step silently no-ops. | Track F2 | Track G (CI) |
| P-5 | **Spec validation is implemented twice**: `@mls/spec-renderer`'s `validateSpec` cannot load in a plain Node process (the bundle imports React/Fluent at module scope), so `copilot-svc` re-implements it against the same `spec.schema.json`. Single source of truth for the copilot's output contract wants a UI-free subpath export (`@mls/spec-renderer/validate`), collapsing the duplicate to one import. | Track F2 | Phase P cleanup |
| P-6 | **Root workspace hoisting defeated the vuln-lab CVE seed** (`json5` resolved to patched 2.2.3 over the pinned 2.2.0; only 2 of 3 advisories surfaced), plus an extraneous `qs@6.5.2`. Fix in flight: narrow `workspaces` to an explicit list excluding `apps/vuln-lab` and regenerate the root lockfile. **Re-verify `npm audit` reports exactly 3 advisories before L10 is considered seeded.** | Orchestrator verification | Track F1 completion |

## What Phase P cannot cover (waits for tenant)

Real Graph/Fabric/ARM calls, OIDC federation, policy/NIST state, CA/label creation,
sign-in data, cost exports, Defender, ZAP against a live staging URL, the self-healing
loop end-to-end, and all Verifier layer audits L1–L11. Each is named in its layer
playbook's Deferred validation section.

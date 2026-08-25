# Phase P — Pre-Tenant Scaffold Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.
> Track owners dispatch IC subagents per track; ICs author and test but **never commit**
> (the Orchestrator reviews and commits per track) and **never touch Azure, Entra,
> Fabric, or Microsoft Graph** — Phase P is 100% local + GitHub.

**Goal:** Author and locally validate everything that does not require the Azure tenant,
so that tenant activation is followed by configuration-and-deploy, not development.

**Approved:** sponsor, 2026-08-22 (G1 amendment). Decisions in force: monorepo,
dual E5 trials, Fabric trial capacity first. **The LLM-provider decision was voided on
2026-08-24** by `docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md`: showpiece
#1 becomes a Copilot Studio agent, showpiece #3 runs on GitHub Copilot Autofix, and no
LLM API key exists in the system. Track F's copilot half is reworked accordingly (see
open item P-8).

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
JSON — browsable on localhost pre-tenant, control tower now including the **Ask** tab
shipped dark; `apps/mcp-tools` (replacing `copilot-svc`) serving the same 5 tools as an
**MCP server over Streamable HTTP**, with mocked tool tests and the golden-question eval
harness pointed at the local MCP endpoint; the Adaptive Card builders validated against
the pinned schema; `apps/vuln-lab` with its 3 seeded CVE pins **and** one seeded
CodeQL-detectable code flaw + README. **Validate:** unit tests green; local browse of
both apps against generated data; a real local MCP handshake
(`initialize`/`tools/list`/`tools/call`); eval harness green against the local tools.
**Deferred validation:** the Copilot Studio agent itself — cloud-only, see P-8.

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
| ~~P-5~~ | ~~Spec validation is implemented twice: `@mls/spec-renderer`'s `validateSpec` cannot load in a plain Node process, so `copilot-svc` re-implements it against the same `spec.schema.json`.~~ **CLOSED 2026-08-24:** added the UI-free `@mls/spec-renderer/validate` subpath export (import graph proven to reach only `ajv` + the schema — asserted by a test with a control group, plus a bundle grep and a real-Node-process load); `copilot-svc/src/validation.ts` now re-exports it and the duplicate is deleted. Unused direct `ajv` dep and a root-path type import cleaned up. Re-verified: 121 tests green, subpath loads with 0 DOM globals, eval 10/10. | Track F2 | ✅ closed |
| ~~P-6~~ | ~~Root workspace hoisting defeated the vuln-lab CVE seed (`json5` resolved to patched 2.2.3 over the pinned 2.2.0; only 2 of 3 advisories surfaced), plus an extraneous `qs@6.5.2`.~~ **CLOSED 2026-08-24:** `workspaces` narrowed to an explicit list excluding `apps/vuln-lab`; root lockfile regenerated. Re-verified: `npm ls` clean, `npm audit` in vuln-lab reports exactly 3 (json5 high, minimist critical, semver high). | Orchestrator verification | ✅ closed |
| P-7 | **CI must set the Docker build context to the repo root**, not the app directory — both app Dockerfiles need the workspace lockfile and `@mls/spec-renderer` in context. Images were never built locally (no Docker on this host), so the Dockerfiles are unproven until CI runs them. | Track F1 | Track G (CI) |
| P-8 | **Pre-tenant local demoability of showpiece #1 is lost** (2026-08-24 amendment). Before the amendment, `copilot-svc` ran on a laptop with no tenant and no cloud credentials, so the copilot could be proven — and demoed — before a dollar was spent; that was a deliberate property of the sponsor's scaffold-before-spend posture. Microsoft Copilot Studio is cloud-only: there is no local runtime, no emulator, and a Copilot Studio *trial* licence [cannot publish an agent](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-licensing-subscriptions), so even a free trial does not restore it. The agent now requires the tenant, a production-or-sandbox Power Platform environment on the pay-as-you-go meter, and (for the Fabric knowledge source) a paid F2 capacity. **Consequence for the evals:** the golden-question suite splits — it runs **locally against `apps/mcp-tools`**, proving the five tools, the SQL, and the golden answers themselves against Track A's generated data before any spend; and it runs **against the agent only once deployed**, over Direct Line, at L8. So the *answers* stay provable pre-tenant; the *agent* does not. No mitigation is proposed because none exists — this is recorded as an accepted cost of the amendment, not a defect to fix. | Amendment 2026-08-24 | L8 audit (V8.2) |

## What Phase P cannot cover (waits for tenant)

Real Graph/Fabric/ARM calls, OIDC federation, policy/NIST state, CA/label creation,
sign-in data, cost exports, Defender, ZAP against a live staging URL, the tail of the
self-healing loop (its alert and Autofix-generation stages *are* exercisable pre-tenant
on the public repo — see `L10.md` § Deferred validation), **the entire Copilot Studio
agent** (P-8), and all Verifier layer audits L1–L11. Each is named in its layer
playbook's Deferred validation section.

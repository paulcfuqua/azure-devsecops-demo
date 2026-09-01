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
Create public monorepo `paulcfuqua/azure-devsecops-demo`, push, branch protection, secret
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
| P-9 | **The estate is renameable on the deploy side only.** F90 made `MLS_COMPANY_PREFIX` drive Bicep, the naming action, the Entra manifest and Fabric. It did not reach the **audit** side: roughly 44 parameter defaults (`[string]$LakehouseName = 'mls_operations'`, `$ResourceGroupName = 'mls-rg-apps'`) and ~40 criterion `-Expected`/`-Command` strings still carry the literal prefix across `verification/layer-01..11-audit.ps1`, `data/seed/*` and a few workflows. **Nothing is broken today** - every consumer defaults to the same literal, so they agree - but a deployment that sets the prefix creates `acme-rg-apps` and then audits `mls-rg-apps`. Each audit should take its names from `Get-MlsEstateNaming` rather than a literal default. Deliberately deferred on 2026-08-31: an 84-site refactor of the verification layer is not something to attempt while the estate is mid-bring-up, and the gap costs nothing until somebody renames. A sweep written for it flagged 84 sites, then 40 after narrowing, and was **not shipped** - a gate that fails on correct code is as dishonest as one that passes on broken code, and the class needs a sharper definition than "contains the prefix". | F94 review of L2-L11 | after the first full end-to-end up/down cycle |
| P-10 | **Layers and criteria are not independently re-runnable, and bring-up pays for it every time.** A layer is all-or-nothing: to re-test one criterion you re-run the whole audit, and to re-apply one part of a deploy you re-run the whole layer. On 2026-08-31 L7's audit ran **five times at ~55 minutes** - about four and a half hours - almost entirely to answer one question about V7.3, with V7.5's two 15-minute scale-in waits dominating each run. That is CLAUDE.md's *"a run is an expensive, rate-limited observation"* aimed at the estate's own tooling. **Audit half delivered (2026-08-31).** `-OnlyCriterion` runs a named subset of an audit's criteria and reports the rest as SKIP, guarded by exit code 3 so a filtered run can never read as a sign-off. It is on **all eleven** layer audits and every workflow that runs one - shipping it only on L7, the layer that happened to hurt, would have been the F90 shape exactly - and a total sweep in `failure-classes.Tests.ps1` keeps it that way. First use paid for it: V7.3 verified in **92 seconds** against a 55-minute full audit. **Still open:** range syntax (`V7.3-V7.5`); selection spanning layers; and the deploy-side equivalent - re-applying one part of a layer whose earlier parts are known good, which today means a full redeploy. The deploy half is the harder and more valuable one, and it needs the same guard the audit half has: a partial apply must never be able to report a layer as complete. | Bring-up experience, 2026-08-31 | not scheduled - raise it before the next full bring-up, not during one |
| P-11 | **The `verify` GitHub environment is a second source of truth for values the `demo` environment owns, and it has already drifted.** Every layer's verify job declares `environment: verify`, so `vars.*` it reads resolve against THAT environment - and `verify` holds only a hand-copied subset of `demo`. A variable added to `demo` and not mirrored is silently empty in the audit, the layer-audit action drops the resulting blank line, and PowerShell refuses to bind the orphaned parameter: **the audit cannot start**, so the layer produces no criterion table at all. This is not hypothetical - it killed L5's audit on 2026-08-30 (`Missing an argument for parameter 'FabricCapacityId'`, because `FABRIC_CAPACITY_ID` reached `verify` 30 minutes after that run) and L8's on 2026-09-01 (`-EnvironmentUrl`). A sweep found six workflows affected; L4 and L10 were next in line. The environments had also diverged on VALUE, not just presence: `AZURE_LOCATION` was `eastus` in `verify` and `centralus` in `demo`, directly under a comment calling it *"the single source of truth for the estate's region"* - harmless only because no verify job happens to read it. **Mitigated 2026-09-01** by copying the missing variables across and aligning `AZURE_LOCATION`; that is a patch, not a fix, and the next variable anyone adds re-opens it. **The fix** is that a verify job takes these values from job OUTPUTS of the `demo`-scoped preflight rather than reading `vars.*` itself, leaving `verify` to hold only what is genuinely the Verifier's own (its client id, its token). Then CLAUDE.md's *"every value has one source"* is true of the estate's own pipeline, which is currently the one place it is not. Enforceable afterwards by a sweep: no `environment: verify` job reads a `vars.*` that the demo environment owns. | F99, 2026-09-01 | before the next bring-up - a silent audit-cannot-start is the most expensive failure shape here, because it looks like a layer that was never run |
| P-12 | **None of the six long-lived credentials exist, and the layers that need them degrade quietly enough to look finished.** `gh api .../actions/secrets` returns `total_count: 0`; the `demo` environment holds none either. Consequences, found while watching a full `infra-up` on 2026-09-01: L4 cannot APPLY the label taxonomy (`PURVIEW_CERT_BASE64`) and cannot be AUDITED (`MLS_VERIFIER_CERT_BASE64`) - so **L4 has never been independently verified in CI**, though earlier notes recorded it as signed off; L10's Dependabot half stalls without `SELF_HEAL_TOKEN`, because a `GITHUB_TOKEN` push does not trigger workflows; and the Verifier reads GitHub as the workflow's `GITHUB_TOKEN` rather than `MLS_VERIFIER_GH_TOKEN`, which means L9's stated design - *"GitHub is read with the Verifier's own read token (spec F8)"* - is **not currently true**, and was the real root of F103 one level below the diagnosis. **The degrade paths themselves are honest** - L4's says *"Nothing was verified and nothing was faked"* and self-heal names which half is stalled - so this is not a correctness bug. It is that a job which verified NOTHING exits `success`, while a filtered audit exits **3** precisely so it cannot read as a sign-off (P-10). The same principle, applied in one place and not the other; a dashboard shows the green tick, not the notice. **Fix:** create the two certificates and two tokens (a documented G0 step, not a new secret - CLAUDE.md already inventories all six), and give "ran but judged nothing" an exit code that cannot be mistaken for a pass. | Full infra-up observation, 2026-09-01 | before any sign-off is quoted to a third party |

## What Phase P cannot cover (waits for tenant)

Real Graph/Fabric/ARM calls, OIDC federation, policy/NIST state, CA/label creation,
sign-in data, cost exports, Defender, ZAP against a live staging URL, the tail of the
self-healing loop (its alert and Autofix-generation stages *are* exercisable pre-tenant
on the public repo — see `L10.md` § Deferred validation), **the entire Copilot Studio
agent** (P-8), and all Verifier layer audits L1–L11. Each is named in its layer
playbook's Deferred validation section.

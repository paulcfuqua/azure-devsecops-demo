# Working Agreements — Meridian Launch Systems Demo

Rules for every agent (Orchestrator, Verifier, leads, ICs) working in this repo. The
authoritative brief is [docs/BRIEF.md](docs/BRIEF.md); the current plan is
[docs/superpowers/plans/2026-08-22-g1-master-plan.md](docs/superpowers/plans/2026-08-22-g1-master-plan.md).

## Hard rules

1. **No Azure/Entra/Fabric/GitHub-org writes** unless (a) G1 is approved, (b) your layer
   is unblocked by the Orchestrator, and (c) the previous layer has Verifier sign-off.
   Authoring code is always allowed; executing deployments is not.
2. **Gates:** G0 human bootstrap; G1 one-time plan approval; G2 any spend-profile
   increase (state cost delta + duration, wait for human); G3 tenant-level deletions
   (Entra objects, labels, Fabric workspace, OIDC federation); G4 exception escalation
   (layer fails verification twice, cost anomaly, credential failure, lead deadlock).
   RG-scoped teardown of demo resources is gate-free by design.
3. **Escalation chain:** IC → workstream lead → Orchestrator → human. Only the
   Orchestrator messages the human; the Verifier may bypass it only when the Orchestrator
   itself is the problem.
4. **Synthetic data only.** Public facts (vehicle names, launch sites) are fine. Nothing
   proprietary from any employer. No real person's PII — demo users are fictional.
5. **No secrets in the repo, and none in CI.** Tenant/subscription IDs live in GitHub
   environment variables. Everything Azure authenticates via OIDC / workload identity
   federation. Since the 2026-08-24 amendment there is **no LLM API key anywhere** — the
   only stored secret in the system is the **Direct Line secret in Key Vault**, which is
   exchanged server-side for a short-lived token and must never reach a browser.

## How we work

- Each teammate works in its own git worktree; merge to `main` via PR. ICs never push to
  `main` directly.
- Every layer ships a triplet: `deploy` path, `teardown` script, `verification/` audit
  script. A layer without all three is not done.
- Teardown scripts for tenant-level objects are idempotent create-if-absent on replay;
  the standard kill/rebuild path never touches tenant objects (see spec F6).
- The Verifier runs only code in `verification/`, authenticated as `mls-verifier`
  (Reader), never as the deployer SP. Audit output is written to
  `verification/reports/` and committed.
- CI targets `ubuntu-latest` (bash). Local orchestration targets PowerShell 7 (`pwsh`).
  Never assume Windows PowerShell 5.1.

## Naming and tagging

- Resource names: `mls-<app|role>-<env>-<type>` (e.g. `mls-copilot-demo-ca`,
  `mls-ops-demo-sql`). Company name and prefix are set once in
  `infra/bicep/naming.bicep` — do not hardcode `mls` elsewhere.
- Required tags on every RG (policy-enforced): `env`, `app`, `costCenter`, `owner`,
  `dataClassification`, `managedBy=iac`. Resources inherit via modify policy.
- Demo RGs: `mls-rg-platform`, `mls-rg-apps`, `mls-rg-data`, `mls-rg-ops`. Teardown =
  delete these four.

## Commit conventions

- Conventional commits (`feat:`, `fix:`, `infra:`, `docs:`, `verify:`).
- Layer work references its layer, e.g. `infra(L6): container apps environment`.
- Never commit generated data (`data/generated/`), local settings, or `.env`.

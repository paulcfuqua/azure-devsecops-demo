# Working Agreements — Meridian Launch Systems Demo

Rules for every agent (Orchestrator, Verifier, leads, ICs) working in this repo. The
authoritative brief is [docs/BRIEF.md](docs/BRIEF.md); the current plan is
[docs/superpowers/plans/2026-08-22-g1-master-plan.md](docs/superpowers/plans/2026-08-22-g1-master-plan.md).

## Hard rules

1. **Agents execute the estate. Two things still stop them: money and deletion.**
   *(Sponsor amendment 2026-08-29 — supersedes the original rule, which read "No
   Azure/Entra/Fabric/GitHub-org writes …  Authoring code is always allowed; executing
   deployments is not." G0 was human-run and every bootstrap script said "Agents author
   this file; they never execute it.")*

   **Agent-created and agent-managed infrastructure is now the demo**, not a thing the
   demo describes. Azure, Entra, Fabric and GitHub writes are allowed once (a) G1 is
   approved, (b) your layer is unblocked by the Orchestrator, and (c) the previous layer
   has Verifier sign-off — including the G0 bootstrap scripts under
   `scripts/bootstrap/`, which agents may now run.

   The two carve-outs are not caution, they are the point. An agent that can spend a
   sponsor's money without asking, or delete tenant objects it cannot recreate, is
   demonstrating something nobody wants to buy:
   - **G2 still binds.** Any spend-profile increase waits for a human, with the cost
     delta and duration stated first. Resuming a paid Fabric capacity is G2 *per resume*.
   - **G3 still binds.** The three tenant-level teardown scripts
     (`infra/{entra,policy,purview}/teardown.ps1`) keep refusing to run unattended in CI
     without `-AllowAutomation`, and no workflow passes it.

   The Verifier's independence is unchanged: it runs only code in `verification/`, as
   `mls-verifier`, never as the deployer.
2. **Gates:** G0 bootstrap (agent-run since 2026-08-29; previously human-only); G1
   one-time plan approval; G2 any spend-profile increase (state cost delta + duration,
   wait for human); G3 tenant-level deletions (Entra objects, labels, Fabric workspace,
   OIDC federation); G4 exception escalation (layer fails verification twice, cost
   anomaly, credential failure, lead deadlock). RG-scoped teardown of demo resources is
   gate-free by design.
3. **Escalation chain:** IC → workstream lead → Orchestrator → human. Only the
   Orchestrator messages the human; the Verifier may bypass it only when the Orchestrator
   itself is the problem.
4. **Synthetic data only.** Public facts (vehicle names, launch sites) are fine. Nothing
   proprietary from any employer. No real person's PII — demo users are fictional.
5. **No secrets in the repo. In CI, only the six that have no federated alternative.**
   Tenant/subscription IDs live in GitHub environment *variables*. Everything **Azure**
   authenticates via OIDC / workload identity federation, and since the 2026-08-24
   amendment there is **no LLM API key anywhere**. CI is not secret-free, and claiming it
   was is finding F28 — the complete list of long-lived credentials is:
   `PURVIEW_CERT_BASE64`/`_PASSWORD` and `MLS_VERIFIER_CERT_BASE64`/`_PASSWORD` (two Entra
   app X.509 certificates — Security & Compliance PowerShell has no federated path),
   `SELF_HEAL_TOKEN` (a PAT with `repo` write, because a `GITHUB_TOKEN` push does not
   trigger workflows) and `MLS_VERIFIER_GH_TOKEN`. Two more live in **Key Vault**: the
   **Direct Line secret**, exchanged server-side for a short-lived token and never
   reaching a browser, and `mcp-auth-token`. Adding a seventh needs a written reason;
   `.github/workflows/gitleaks.yml`'s incident text is the rotation list and must stay
   in sync with this one.

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
- **A constant that names something in another system is verified against that system, not
  written from memory.** Policy and role GUIDs, Graph app-role ids, SKU strings, OIDC subject
  formats: resolve them, and put the resolution in the deploy path so it fails in seconds
  rather than inside a nested ARM error. Twenty-three such constants are pinned here and
  exactly one was ever wrong, which is precisely why it survived - see the register's
  "What this register has learned about verification".
- **Every value has one source.** Estate-wide settings live in the `demo` GitHub environment
  (`AZURE_LOCATION` and friends); a default elsewhere silently outranks them, because a
  workflow input beats an environment variable. When a value looks wrong, ask where it comes
  from before asking whether it is correct.
- **A test harness runs in the language mode of the script it tests.** No
  `Set-StrictMode -Off` in `*.Tests.ps1`, and no test that supplies the answer it is
  checking - a wrapper, a helper default, or a fixture that re-wraps a return value is not a
  test, it is a mirror.

## Naming and tagging

- Resource names: `mls-<app|role>-<env>-<type>` (e.g. `mls-mcp-demo-ca`,
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

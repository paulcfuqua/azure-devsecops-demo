# `.github/` — the GitHub Actions layer

Everything the demo deploys through. Authored in Phase P Track G against the
[master plan](../docs/superpowers/plans/2026-08-22-g1-master-plan.md) and the layer
playbooks in [`docs/runbooks/layers/`](../docs/runbooks/layers/).

Nothing here has ever run against a tenant. Every Azure-facing job is guarded so the
repository is pushable and green **before G0** — see [Pre-G0 guards](#pre-g0-guards).

## Layout

```
.github/
├── README.md                         # this file
├── dependabot.yml                    # npm x6 + pip + github-actions
├── pull_request_template.md
├── actions/                          # local composite actions (not published)
│   ├── demo-env-guard/               # the pre-G0 guard, in one place
│   ├── naming/                       # resolves names from infra/bicep/naming.bicep
│   └── layer-audit/                  # runs verification/layer-NN-audit.ps1 defensively
├── scripts/
│   └── self-heal-triage.mjs          # Claude triage: prompt + response handling
└── workflows/
    ├── infra-up.yml                  # layer-ordered instantiation (workflow_dispatch)
    ├── infra-down.yml                # RG-scoped teardown (gate-free by design)
    ├── layer-02-landing-zone.yml     # ┐
    ├── layer-03-entra.yml            # │ callable per-layer deploys
    ├── layer-04-purview.yml          # │ (workflow_call + workflow_dispatch)
    ├── layer-05-fabric.yml           # │
    ├── layer-06-platform.yml         # │
    ├── layer-07-apps.yml             # ┘
    ├── app-launch-ops-ci.yml         # ┐
    ├── app-control-tower-ci.yml      # │ path-filtered per-app CI
    ├── app-copilot-svc-ci.yml        # ┘
    ├── codeql.yml                    # ┐
    ├── sbom.yml                      # │ DevSecOps chain (L9)
    ├── zap.yml                       # │
    ├── gitleaks.yml                  # ┘
    ├── self-heal.yml                 # showpiece #3 (L10)
    └── lint-ci.yml                   # the single green-check entry point
```

## Which workflow belongs to which layer

| Workflow | Layer | What it does | Guarded pre-G0? |
|---|---|---|---|
| `lint-ci.yml` | — | actionlint, PSScriptAnalyzer + Pester, pytest, vitest | **No** — runs today, and must be green |
| `codeql.yml` | L9 | CodeQL matrix: `javascript-typescript`, `python` | **No** — runs today |
| `gitleaks.yml` | L1 / L9 | Full-history secret scan | **No** — runs today |
| `sbom.yml` | L9 | SPDX SBOMs (Syft) per app; attached to published releases | **No** — runs today |
| `app-launch-ops-ci.yml` | L7 | build → test → image → Trivy → GHCR | **Deploy job only** |
| `app-control-tower-ci.yml` | L7 | build → test → image → Trivy → GHCR | **Deploy job only** |
| `app-copilot-svc-ci.yml` | L8 | build → test → mock eval → image → Trivy → GHCR | **Deploy job only** |
| `self-heal.yml` | L10 | alert → Claude triage → patch PR → gauntlet → auto-merge | Runs today in mock triage mode; opens real PRs |
| `zap.yml` | L9 | ZAP baseline vs the staging URL | **Yes** — skips with a notice until a staging URL exists |
| `infra-up.yml` | L1–L7 | Layer-ordered instantiation, L5 ∥ L6 | **Yes** — every deploy job |
| `infra-down.yml` | L11 | 4 RG deletes + Fabric items + capacity pause | **Yes** — every job |
| `layer-02-landing-zone.yml` | L2 | MG, tag/location policies, NIST (audit mode), tag-deny canary | **Yes** |
| `layer-03-entra.yml` | L3 | `infra/entra/apply-entra.ps1` — plan then apply | **Yes** |
| `layer-04-purview.yml` | L4 | `infra/purview/labels.ps1` — 4-label taxonomy | **Yes**, plus an S&C credential guard |
| `layer-05-fabric.yml` | L5 | Capacity resume → workspace/lakehouse → generators → seed → pause | **Yes** |
| `layer-06-platform.yml` | L6 | `infra/bicep/platform` (sub scope), Key Vault secret, cost export | **Yes** |
| `layer-07-apps.yml` | L7 | `infra/bicep/apps` (RG scope) — the three container apps | **Yes** |

L1 has no workflow of its own: it *is* the repo, the `demo` environment, and the OIDC
job inside `infra-up.yml` (the job named `oidc-login`, which `layer-01-audit.ps1`
selects by name for V1.1). L11 is proven by running `infra-down.yml` then
`infra-up.yml` on a clock.

## Pre-G0 guards

The repository exists before the Azure tenant does. Phase P Track G requires deploy
jobs to be "guarded behind the existence of the `demo` environment variables so they
no-op until G0" — so:

1. Each Azure-facing workflow opens with a `preflight` job that declares
   `environment: demo` (the only way `vars.*` resolves to *environment* variables) and
   calls [`.github/actions/demo-env-guard`](actions/demo-env-guard/action.yml).
2. The guard reports `configured=true` only when `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`
   and `AZURE_SUBSCRIPTION_ID` are all non-empty — plus any layer-specific extras
   (`FABRIC_CAPACITY_ID` for L5 and for `infra-up`). It logs only variable **names**,
   never values.
3. Every deploy job carries `needs: preflight` and
   `if: needs.preflight.outputs.configured == 'true'`. Before G0 they are **skipped**,
   the run concludes **success**, and the job summary explains exactly which variables
   are missing and which runbook writes them.
4. `layer-04-purview.yml` adds a second guard for Security & Compliance PowerShell
   credentials (there is no OIDC path for `Connect-IPPSSession`); without them the
   label apply skips with a notice and stays a human-run step.
5. `zap.yml` guards on a staging URL instead of on identity — no L7, no target.
6. `self-heal.yml` needs no Azure at all. With no `ANTHROPIC_API_KEY` the triage
   script emits a deterministic verdict from the alert payload, so the whole chain is
   exercisable before the key exists.

Arming the guards is exactly the L1 deploy procedure
([`docs/runbooks/layers/L01.md`](../docs/runbooks/layers/L01.md) step 1).

## Variables and secrets this layer reads

All of these live in the **`demo` GitHub environment**. None is committed
(CLAUDE.md hard rule 5).

| Name | Kind | Used by | Notes |
|---|---|---|---|
| `AZURE_CLIENT_ID` | variable | every Azure job | `mls-github-deployer` app ID |
| `AZURE_TENANT_ID` | variable | every Azure job | also the tenant-root MG id for L2 |
| `AZURE_SUBSCRIPTION_ID` | variable | every Azure job | asserted by the `oidc-login` job |
| `FABRIC_CAPACITY_ID` | variable | L5, `infra-up` | trial capacity today, paid F2 later |
| `AZURE_VERIFIER_CLIENT_ID` | variable | every `verify` job | `mls-verifier`; audits never run as the deployer |
| `SQL_AAD_ADMIN_LOGIN` / `SQL_AAD_ADMIN_OBJECT_ID` | variables | L6 | Entra-only SQL auth; no SQL password exists |
| `KEY_VAULT_CREATE_MODE` | variable | L6 | set to `recover` when replaying onto a soft-deleted vault |
| `LAUNCH_OPS_PORT` / `CONTROL_TOWER_PORT` / `COPILOT_SVC_PORT` | variables | L7, app CI | **open item P-1** — set all three to `8080` when real images publish |
| `COPILOT_EXTERNAL_INGRESS` | variable | L7 | `false` keeps copilot-svc internal |
| `STAGING_URL` | variable | `zap.yml` | the L7 `launch-ops` FQDN |
| `ENTRA_DOMAIN` | variable | L3 | verified tenant domain for UPNs |
| `PURVIEW_APP_ID` / `PURVIEW_ORGANIZATION` | variables | L4 | S&C app-only auth (optional) |
| `ANTHROPIC_API_KEY` | secret | L6, `self-heal.yml` | the only stored secret in the system |
| `PURVIEW_CERT_BASE64` / `PURVIEW_CERT_PASSWORD` | secrets | L4 | optional; enables unattended label apply |
| `SELF_HEAL_TOKEN` | secret | `self-heal.yml` | optional PAT with `security_events` read |

## Repository settings this layer assumes

Set once by the human; the workflows do not (and must not) change them.

- **Secret scanning + push protection: on** (L1 V1.2).
- **Dependabot alerts: on** — they come from the dependency graph, not from
  `dependabot.yml`, and they are the trigger the self-healing showpiece rides.
- **Dependabot *security updates*: off.** If GitHub opens its own patch PRs for the
  three `apps/vuln-lab` pins, it races `self-heal.yml` for them and there is no
  showpiece left to demo. `dependabot.yml` already sets
  `open-pull-requests-limit: 0` for that directory for the same reason.
- **Allow auto-merge: on** — `self-heal.yml` arms `gh pr merge --auto`.
- **Branch protection on `main`:** required checks must match the gauntlet's job names
  *exactly*, or auto-merge silently never fires (L10 failure mode 2).
- **CodeQL default setup: not configured** — it conflicts with the advanced
  `codeql.yml` workflow (L9 failure mode 1).

## Handoff — audit scripts these workflows expect

Every layer workflow ends with a `verify` job that authenticates as `mls-verifier`
and calls [`.github/actions/layer-audit`](actions/layer-audit/action.yml). **None of
these scripts exists yet** — they are the Verifier's deliverable. A missing script is
a NOTICE, never a failure: the layer deploys, and the summary says plainly that
nothing independently audited it.

| Expected script | Called by | Criteria it must cover |
|---|---|---|
| `verification/layer-01-audit.ps1` | (Verifier, out of band) | V1.1–V1.4 — the `oidc-login` job name is the hook |
| `verification/layer-02-audit.ps1` | `layer-02-landing-zone.yml` | V2.1–V2.3 |
| `verification/layer-03-audit.ps1` | `layer-03-entra.yml` | V3.1–V3.4 |
| `verification/layer-04-audit.ps1` | `layer-04-purview.yml` | V4.1–V4.2 |
| `verification/layer-05-audit.ps1` | `layer-05-fabric.yml` | V5.x incl. capacity `Paused` |
| `verification/layer-06-audit.ps1` | `layer-06-platform.yml` | V6.1–V6.4 |
| `verification/layer-07-audit.ps1` | `layer-07-apps.yml` | V7.1–V7.5 |
| `verification/layer-09-audit.ps1` | (Verifier, out of band) | V9.1–V9.5 |
| `verification/layer-10-audit.ps1` | (Verifier, out of band) | V10.1's six-stage trail |
| `verification/layer-11-audit.ps1` | (Verifier, out of band) | V11.1–V11.5, incl. the down-state half |

Two more scripts are referenced defensively by the deploy paths and also do not exist:

| Expected script | Called by | Effect while absent |
|---|---|---|
| `infra/fabric/teardown-items.ps1` | `infra-down.yml` | Lakehouse items survive teardown (OneLake pennies); notice emitted |
| `data/seed/*.ps1` | `layer-05-fabric.yml` | Lakehouse is provisioned but not seeded; notice emitted |

## Open items carried in this layer

| # | Where it shows up |
|---|---|
| **P-1** | Target ports default to the placeholder `80`. `layer-07-apps.yml` reads `*_PORT` variables with an `80` fallback and flags it in the run summary; each app CI deploy job emits a **warning** if ingress is still on 80 and deliberately does not mutate ingress itself. Set the three variables to `8080` to close it. |
| **P-4** | `lint-ci.yml` installs PSScriptAnalyzer explicitly and then *asserts* `Invoke-ScriptAnalyzer` exists, so the lint step can never silently no-op on a runner that lacks the module. |
| **P-7** | Every app image builds with `context: .` (the repo root) and `file: apps/<app>/Dockerfile`. `app-copilot-svc-ci.yml` additionally runs `npm run build:renderer` before `docker build`, because that Dockerfile copies `apps/shared/spec-renderer/dist`, which is gitignored build output. |

## Deviations from the playbooks

- **`self-heal.yml` triggers.** L10 names `dependabot_alert` / `code_scanning_alert`
  (itself marked `[derived]`). Neither is a valid GitHub Actions event — actionlint
  1.7.12 rejects both as unknown webhook events. Replaced with `schedule` (6-hourly
  poll), `repository_dispatch` (a real webhook bridge, for true alert-driven firing),
  and `workflow_dispatch`. The workflow header spells this out.
- **L4 has no unattended path by default.** Security & Compliance PowerShell has no
  OIDC login, so `layer-04-purview.yml` runs `labels.ps1` only when certificate-based
  app-only credentials are configured; otherwise it skips with a notice.
- **`infra-up.yml` does not call the app CI workflows.** L7's playbook derives that
  wiring, but images live in GHCR, which does **not** die with the Azure resource
  groups — so a rebuild only needs the declarative `layer-07-apps.yml` plus an
  `image_tag`. Rebuilding an image is a `workflow_dispatch` away when it is actually
  needed.

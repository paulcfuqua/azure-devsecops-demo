# Security Policy

## Read this first: some vulnerabilities here are deliberate

This repository is a **demonstration of a DevSecOps pipeline**, and one of the things it
demonstrates is a pipeline healing itself. That requires something broken to heal.

Everything under **`apps/vuln-lab/`** is intentionally vulnerable:

| Kind | What is seeded | Healed by |
|---|---|---|
| Vulnerable dependency pins | `json5@2.2.0` (CVE-2022-46175), `minimist@1.2.5` (CVE-2021-44906), `semver@7.5.1` (CVE-2022-25883) | Dependabot security updates |
| Unsafe code paths | 2 CodeQL-detectable flaws under `seeds/` | GitHub Copilot Autofix |

These are real CVEs with real advisories, chosen precisely because scanners detect them.
**Dependabot and CodeQL alerts against `apps/vuln-lab/` are the demo working, not a
defect.** Please do not open reports for them.

Three properties keep this safe, and all three are enforced rather than asserted:

- `@mls/vuln-lab` is **never imported** by `launch-ops`, `control-tower`, `mcp-tools`,
  `directline-token`, `data-api` or `cost-ingest`.
- It is **never built into any container image** and never deployed.
- An import of it — or of anything under `seeds/` — from an application is itself a bug.
  See `apps/vuln-lab/README.md` and `docs/runbooks/layers/L10.md`.

If you find `vuln-lab` reachable from a deployed application, that **is** a real finding
and I want to hear about it. That is the invariant, and a break in it is the interesting
case.

## Reporting a real vulnerability

For anything outside `apps/vuln-lab/` — or for a reachability break as described above —
please use **[GitHub Private Vulnerability Reporting](https://github.com/paulcfuqua/azure-devsecops-demo/security/advisories/new)**
rather than a public issue. That keeps the report private until there is something to
disclose.

Useful things to include: what you were looking at, why you believe it is exploitable, and
the smallest reproduction you have. A concrete path matters more than a scanner's output —
this repository deliberately contains findings that scanners flag correctly and that are
not defects.

I maintain this in my own time, so expect an initial response in days rather than hours.

## Scope

**In scope** — the infrastructure-as-code under `infra/`, the applications under `apps/`
(excluding `vuln-lab`), the verification scripts under `verification/`, the bootstrap and
orchestration scripts under `scripts/`, and the GitHub Actions workflows.

Two areas are worth extra scrutiny if you are looking:

- **Credential handling.** The design intent is that CI holds no **cloud** credential —
  every Azure interaction authenticates by OIDC / workload identity federation. CI is
  **not** credential-free, and any document here that says otherwise is a bug (that was
  finding F28). Six long-lived credentials exist, each because no federated path does the
  job: `PURVIEW_CERT_BASE64`/`_PASSWORD` and `MLS_VERIFIER_CERT_BASE64`/`_PASSWORD` (Entra
  app X.509 certificates for Security & Compliance PowerShell), `SELF_HEAL_TOKEN` (a PAT
  with `repo` write) and `MLS_VERIFIER_GH_TOKEN`; plus two Key Vault secrets, the Direct
  Line secret and `mcp-auth-token`. The Direct Line secret is exchanged server-side for
  short-lived, origin-pinned tokens and **must never reach a browser**. A path that leaks
  any of the six, or a hardcoded credential anywhere, is a real finding.
- **The verifier identity.** `mls-verifier` is meant to be strictly read-only. Anything
  that lets it mutate state is a real finding.

**Out of scope** — `apps/vuln-lab/` and its seeded CVEs, the fictional demo personas and
synthetic data, and the deliberately report-only Conditional Access policies (they are
`enabledForReportingButNotEnforced` on purpose, so a demo tenant cannot lock itself out).

## Deploy this into a dedicated, empty subscription

A requirement, not a suggestion, and the single most likely way to hurt yourself with this
repository. The landing zone assigns **subscription-wide DENY policy** — six
`require-<tag>` deny rules on resource groups plus an `allowed-locations` deny on every
resource — and those apply to **everything already in that subscription**, not just to what
this demo creates. It also assigns a NIST SP 800-53 R5 initiative and a budget at
subscription scope, grants `data-api`'s identity **Security Reader across the whole
subscription**, and (before F31) would have disabled a Defender for Containers plan it
found already enabled. `infra-down.yml` deletes four resource groups by name.

## No warranty

This is demonstration software provided under the Apache License 2.0, **as is and without
warranty of any kind**. It provisions billable cloud resources and ships deliberately
vulnerable code. Do not deploy it into a production tenant or into a subscription that
holds anything you care about, and read `docs/runbooks/g0-bootstrap.md` — including its
cost model and spending guardrails — before deploying it anywhere.

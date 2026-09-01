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

### The four showpieces — 2 working, 1 ready but unobserved, 1 blocked on one manual action

| # | Showpiece | Status | Evidence |
|---|---|---|---|
| **2** | **Control tower** — Dev/Sec/Ops on Well-Architected pillars | ✅ **working** | All three tabs render live data: 2,587 workflow runs, 76 open code-scanning alerts, 4 Dependabot alerts, 4,515 cost rows, 1,200 telemetry rows. Screenshots with provenance in `docs/evidence/` |
| **4** | **Compliance platform** — NIST 800-171 | ✅ **working** | **Independently audited for the first time, 2026-09-01.** `verification/layer-12-audit.ps1` runs as `mls-verifier` and reports **4 PASS + 2 SKIP**: the shipped artifact is complete against the catalog and carries no score, the honesty invariant holds in the file rather than only in the derivation, Easy Auth refuses anonymous callers, and the collection history is a git history. The two SKIPs name their owners rather than being gaps |
| **1** | **Copilot service** — Ask tab over Direct Line | 🟡 **ready, unobserved** | Every link verified against the running system: agent **published**, secret in Key Vault, Key Vault reference `Resolved` (F122 fixed, V6.8 confirms), token endpoint returns **HTTP 200 with a real token**, and the deployed bundle now carries the endpoint (F124 fixed — confirmed by grepping the GHCR image layers). **Not yet seen answering:** Control Tower is behind Easy Auth, so a human must sign in and open the tab. Ready to demonstrate, not demonstrated |
| **3** | **Self-healing code** | ❌ **never demonstrated** | `self-heal.yml` runs green on schedule and skips every healing lane. The reason is **not** "no alerts" — four are open, one critical. The selector gets **HTTP 403** and reports it as `found=false`, indistinguishable from an empty surface (**F123**). One manual action away: `SELF_HEAL_TOKEN` must be a **repository** secret, not a `demo` environment one |

### The twelve layers — 7 verified, 3 partial, 2 not done

| Layer | Status | Note |
|---|---|---|
| L1 repo / IaC / OIDC / up-down | ✅ verified | The pipelines are the product and they run |
| L2 landing zone | ✅ verified | V2.1, V2.2 PASS |
| L3 Entra | ✅ verified | V3.1–V3.4 PASS |
| L7 apps | ✅ verified | 5/5, **and** now serving real rows rather than plumbing |
| L11 teardown | ✅ verified (down half) | V11.1 PASS. Rebuild proven once; V11.2 blocked by **BLOCKER-1** |
| L5 Fabric | 🟡 partial | Deployed and seeded (10 tables, `launches`=1,200). Its audit has not passed cleanly since F104/F105/F114 were fixed — **re-run it** |
| L6 platform | 🟡 partial | Deploys green and both Function Apps hold code (V6.7 confirms it). **F122** found its Key Vault reference resolving to nothing while all six criteria passed; V6.8 now asserts references actually resolve |
| L9 DevSecOps chain | 🟡 partial | 4/5. GHAS, SBOM, Trivy and ZAP all run |
| L12 compliance | ✅ verified | **The last layer to get an audit, 2026-09-01.** 4 PASS + 2 SKIP; wired into `compliance.yml` as a `verify` job after every collection. `MlsAudit` capped `Layer` at 11 until now - the module could not represent layer 12 even if someone had written the script |
| L4 Purview labels | ✅ verified | **DONE 2026-09-01, the first time ever.** `verify L4 (mls-verifier)` PASSED. Four sensitivity labels now exist in the tenant - `mls-public`, `mls-internal`, `mls-confidential`, `mls-export-controlled` - where there had been none. The label POLICY failed (F121, fixed, re-run in flight) and the audit has not signed off yet |
| L8 Copilot Studio | 🟡 partial | **Solution IMPORTED and agent PUBLISHED, 2026-09-01 — both firsts.** Publishing is a separate, human, Copilot Studio step (`import-agent.ps1`: "--publish-changes publishes solution CUSTOMIZATIONS. That is NOT the same thing as publishing the agent"), now done. V8.1 still fails on a Verifier Dataverse read permission; V8.2-V8.5 wait on F122's fix reaching the Function |
| L10 self-healing | ❌ chain never executed | Not for want of a subject: four Dependabot alerts are open. The chain cannot READ them (**F123**). V10.3 now fails on that rather than skipping quietly |

### The mission itself

*"Fully agent-instantiated … destroyed and rebuilt on demand … the repo is the product."*
**Substantially achieved.** The estate deploys from a cold dispatch in layer order with
independent sign-off at each step, and teardown and rebuild have both been demonstrated.
Spend to date is ~$1.40 against a $200 ceiling, so **money is not the constraint; the
30-day calendar is.**

---

## THE BLOCKER TREE — what actually stands between here and 4/4

*Ordered by how much each unblocks. Everything not-done above traces to one of these five.*

**BLOCKER-1 and BLOCKER-2 are both CLOSED as of 2026-09-01.** What is left:

- **BLOCKER-3 is CLOSED on every link that can be checked without a browser sign-in**
  (2026-09-01). Each was verified against the running system, not inferred from a green run:
  the agent is published; the secret is in Key Vault; the Key Vault reference reports
  `Resolved` (F122 fixed, and **V6.8 confirms it in CI**); the token endpoint returns
  **HTTP 200 with a real, origin-scoped Direct Line token**; and the deployed bundle -
  pulled from GHCR and grepped layer by layer - now contains
  `https://mls-directline-demo-func.azurewebsites.net/api/directline/token` (F124 fixed).
  Revision `--0000010` carries 100% of traffic.

  **What is NOT verified: nobody has watched the Ask tab render a conversation.** Control
  Tower sits behind Easy Auth, so that last step needs a human signed in. Every link in the
  chain is confirmed; the chain has not been observed end to end. Treat it as *ready to
  demonstrate*, not *demonstrated*, until someone opens it.
- **BLOCKER-4** was **misdiagnosed** and is now one manual action from closed. It is not
  "nothing to heal" - four Dependabot alerts are open, one critical, and the chain has been
  getting **HTTP 403** on every run because `SELF_HEAL_TOKEN` is an *environment* secret
  that no consuming job can see (**F123**). Re-create it as a **repository** secret and the
  chain has both a subject and a token.
- **BLOCKER-5 is CLOSED** (2026-09-01). `verification/layer-12-audit.ps1` exists, runs as
  `mls-verifier`, and is wired into `compliance.yml`. Four criteria are checked
  independently and two are explicit SKIPs naming where they *are* checked - V12.3 would
  have to defeat V12.4 to run, and V12.5 is L8's V8.3 against the same server.
- **One open sub-item, not a blocker:** V8.1 needs a Dataverse read role for
  `mls-verifier` - see BLOCKER-2's resolved entry for what has been tried.

### F124 — the Ask tab's endpoint never reached the bundle, and the image was newer than the variable *(fixed 2026-09-01)*

**Everything on the server side works.** The agent is published, the Direct Line secret is
in Key Vault, F122's identity fix landed, and the token endpoint mints real tokens:

    POST https://mls-directline-demo-func.azurewebsites.net/api/directline/token
    HTTP 200  {"token":"eyJ...","expires_in":3600,"conversationId":"Lh8SX4GBfTCJQGdSUsKiBh-us"}

The Ask tab still renders "not configured", because **the deployed bundle contains no token
URL.** Pulled the running image from GHCR and grepped its layers directly rather than
inferring: `usr/share/nginx/html/assets/index-CfaMGZ2F.js` matches `directline/token` — from
a *documentation string inside an error message* — and does **not** contain `azurewebsites`
anywhere.

**The image was NEWER than the variable, and still did not have it.** `MLS_DIRECTLINE_TOKEN_URL`
was set at 15:08; the running image was built at 16:13. The inference "the build is newer, so
it picked the value up" is exactly the reasoning this repository keeps paying for, and it is
wrong here:

    app-control-tower-ci.yml
      preflight   environment: demo     <- builds nothing
      image       (no environment)      <- BUILDS THE BUNDLE, reads vars.MLS_DIRECTLINE_TOKEN_URL
      deploy      environment: demo     <- builds nothing

`VITE_DIRECTLINE_TOKEN_URL` is a **Vite** variable: inlined into the bundle at `npm run
build`, which happens inside the `image` job's docker build. That job declared no
environment, so `vars.MLS_DIRECTLINE_TOKEN_URL` resolved to the empty string — silently,
because **an absent GitHub variable is the empty string, not an error**. The value was
reaching the two jobs that did not need it and missing the one that did, and a reviewer
asking "does this workflow use the demo environment?" would have seen *yes*.

**This is the THIRD instance of one shape in a single session**, which is why it is now a
test rather than three findings:

| | What was invisible | To what |
|---|---|---|
| **F122** | the identity that resolves a Key Vault reference | the site holding the reference |
| **F123** | `SELF_HEAL_TOKEN` (an environment secret) | every job that uses it — none declares an environment |
| **F124** | `MLS_DIRECTLINE_TOKEN_URL` (an environment variable) | the one job that builds the bundle |

Each is *"the value exists, is spelled correctly, and cannot be seen by the thing that needs
it"*, and each failed silently and green.

**Fixed** by declaring `environment: demo` on the `image` job.
`verification/tests/failure-classes.Tests.ps1` now fails any job that reads a `vars.MLS_*`
estate setting without declaring an environment — mutation-tested: with the fix reverted it
names `app-control-tower-ci.yml::image reads MLS_DIRECTLINE_TOKEN_URL`.

**Rebuilt and confirmed, 2026-09-01.** Image `sha-941f286`, revision `--0000010` at 100%
traffic; its `index-BCApny3-.js` now contains the real endpoint. A redeploy could not have
helped — the value is baked in at build time.

The `image` job also now says, in its own log, whether the image will carry an endpoint. It
is a **warning, never a failure**: this repository is meant to be cloned by strangers into
their own tenants, and building with no published agent is a supported path. What was
missing was never a gate — it was that `''` and "deliberately unset" looked identical.

### F123 — self-healing was never "nothing to heal"; it could not look *(fixed 2026-09-01)*

**BLOCKER-4's diagnosis was wrong, and this entry is the correction.** It read *"nothing to
heal — the alerts have to be live for the chain to have a subject."* The alerts have been
live all along. There are **four open Dependabot alerts** — `minimist` (critical), `semver`
(high), `json5` (high) in `apps/vuln-lab`, plus `esbuild` (low) at the root — which is
exactly the seeded set `apps/vuln-lab` pins on purpose. A dispatched run says what is
actually happening:

    notice  Could not read alerts
    gh: Resource not accessible by integration (HTTP 403)

**The cause is a credential SCOPE, not a permission grant.** `SELF_HEAL_TOKEN` was created
as a **`demo` environment secret**. Every job that consumes it — `self-heal.yml`'s `select`,
`autofix` and `dependency`; `compliance.yml`'s `commit`; `gitleaks.yml`'s `scan`;
`layer-09`'s `ghas` — declares **no `environment:`**, so `secrets.SELF_HEAL_TOKEN` is empty
in all of them and the `|| GITHUB_TOKEN` fallback takes over. `GITHUB_TOKEN` cannot read
`/dependabot/alerts`. The repo's own rotation table in `.github/workflows/gitleaks.yml` —
which CLAUDE.md designates as the source of truth — says plainly:

    | `SELF_HEAL_TOKEN` | repository secret — a PAT with `repo` write | ... |

Spec and live state disagreed, and **every consumer degraded silently.** This also means
F120's compliance fix has been inert for a different reason than recorded: not "the secret
does not exist", but "the secret cannot be seen".

**Why it survived: the chain reported a denial as an absence.** The select step set
`found=false` on a 403 — the identical output it sets when the repository genuinely has no
open alerts. Every lane then skipped and the run reported success. That is the
absence-vs-denial class this repository has now paid for **seven** times, occurring inside
the self-healing showpiece itself. Worse, the one state most needing an auditor was the one
that skipped it: `verify` was gated on `found == 'true'`.

**Fixed** in three places:

- `select` now emits a **`readable`** output distinct from `found`, and a denial raises a
  **warning** naming the environment-vs-repository scope trap. The run still succeeds — a
  self-healing chain must not be able to break the repository it heals.
- `verify` now also runs when `readable == 'false'`, so the unreadable case reaches its
  auditor instead of skipping it.
- **V10.3** fails on `readable=false` with the remedy in `Detail`, and fails as
  **UNOBSERVABLE** when the chain reported nothing — never "healthy by default".

**THE ONE MANUAL ACTION LEFT:** `SELF_HEAL_TOKEN` must be re-created as a **repository**
secret (Settings → Secrets and variables → Actions → *Repository secrets*), not an
environment secret. The PAT itself is fine — only its scope is wrong. Deleting the `demo`
copy afterwards keeps the rotation table honest. **This single change unblocks four
workflows at once**, and is all that stands between here and the first end-to-end
self-healing run.

### F122 — the Direct Line secret never reached the Function, and *nothing* said so *(fixed 2026-09-01)*

Everything about this one was correct except the part no tool showed. The agent was
published, the Direct Line secret was in Key Vault under the right name, the app setting on
`mls-directline-demo-func` was present and well-formed, the identity existed, the
`Key Vault Secrets User` grant was in place, the deploy was green, and **L6 signed off
green on all six criteria.** The Function received an empty string.

    az rest --url .../config/configreferences/appsettings
    status:  MSINotEnabled
    details: Reference was not able to be resolved because site Managed Identity not enabled.

A `@Microsoft.KeyVault(...)` app setting is resolved by the platform using the site's
**system**-assigned identity unless the site sets `keyVaultReferenceIdentity`
(`keyVaultAccessIdentityResourceId` on the AVM site module). This site has **only** a
user-assigned identity — because Flex Consumption needs an identity *resource id* at
site-creation time, which a system-assigned identity does not have until the site exists.
The two requirements are in direct tension and **satisfying the first silently breaks the
second**.

**Why it was invisible, which is the part worth keeping.** `az functionapp config
appsettings list` prints the reference back verbatim whether or not it resolves — the
artefact is perfect from every angle a person would check. And the downstream symptom was
the Ask tab reporting *"the channel is not configured"*, which is a state this estate
**deliberately supports and ships as the honest default** before an agent is published. So
the single visible signal was indistinguishable from correct behaviour. There was no error
anywhere, at any layer, at any time.

**Fixed** by naming the identity in `infra/bicep/platform/main.bicep`. Two checks now cover
the class, deliberately at different costs:

- **V6.8** (`verification/layer-06-audit.ps1`) asserts every Key Vault reference in every
  Function App reports `status == Resolved` — the capability (*the secret arrives*), not the
  artefact (*the setting is present and points somewhere real*). It reads
  `/config/configreferences/appsettings`, which returns names and statuses but never values
  — which is exactly why a Reader-authenticated Verifier can be the one asking. Unresolvable
  responses are `UNOBSERVABLE`, never "no references".
- **`verification/tests/failure-classes.Tests.ps1`** catches the class statically, in a
  second, with no estate: any Bicep site block containing `@Microsoft.KeyVault(` must name
  an identity. This is the one that matters going forward — the next Function App to want a
  secret will be copied from the one that has one.

### F121 — the label policy was published to recipients that cannot exist *(fixed 2026-09-01)*

L4's first real run created all four labels and then failed:

    New-LabelPolicy: ManagementObjectNotFoundException
    The specified recipient "mls-flight-operations" couldn't be found.

The group exists — L3 creates it. But `-ExchangeLocation` takes a **recipient**, and L3
creates pure **security** groups (`mailEnabled=False`, no mail address), which Security &
Compliance cannot resolve however correct the name is. Two layers disagreeing about what a
group is, invisible for the life of the project because **L4 had never run**: the
credential to run it did not exist until BLOCKER-1 closed.

Published to `All` instead. The alternatives — M365 groups (which provision a mailbox,
SharePoint site and Teams surface each, and are referenced by L3's CA policies) and
mail-enabled security groups (Exchange-side, not creatable via Graph) — are recorded in
`Get-LabelPolicyScope`. **What it costs:** the policy no longer expresses "these four
teams", so the *scoping* half of the segregation story is not demonstrated by this object.
The labels themselves are unaffected.

**Two test suites pinned the unachievable scope** and would have failed the fix for the bug
they encode — `verification/tests/layer-04-audit.Tests.ps1` and
`infra/purview/tests/labels.Tests.ps1`. That is the fourth occurrence of that shape in two
days.

### ~~BLOCKER-1 — No GitHub secrets exist. Not one.~~ **CLOSED 2026-09-01**

**All six of CLAUDE.md's permitted long-lived credentials now exist**, in the environments
the design calls for:

| `demo` | `verify` |
|---|---|
| `PURVIEW_CERT_BASE64` | `MLS_VERIFIER_CERT_BASE64` |
| `PURVIEW_CERT_PASSWORD` | `MLS_VERIFIER_CERT_PASSWORD` |
| `SELF_HEAL_TOKEN` | `MLS_VERIFIER_GH_TOKEN` |

The `mls-purview` app registration (`838332d8-16f9-4a83-82af-80a97502b6e6`) was created for
the Security & Compliance app-only identity, holds a certificate valid to 2027-09-01, has
**Exchange.ManageAsApp** granted and is a member of **Compliance Administrator**. Both
grants were verified by READING THEM BACK, which mattered — see the two notes below.

**Two things went wrong provisioning this, and both are the estate's own recurring class.**

1. **A silent failure.** The setup script's `az ad app permission admin-consent` exited 0
   and granted nothing: the permission was correctly *requested* on the app and no
   `appRoleAssignment` was ever created. It was caught only because the grant was read back
   rather than assumed from the exit code, and fixed with a direct Graph POST. A script
   that reports success while its work did not happen is the same shape as F119 and F120,
   committed while writing the fix for them.
2. **A false alarm, from a blind read.** The same script's Compliance Administrator
   assignment DID work, and was briefly reported as failed because
   `GET /v1.0/directoryRoles/{id}/members` **does not enumerate service principal
   members** — it returns `[]`. `GET /beta/directoryRoles/{id}/members` and
   `GET /servicePrincipals/{id}/memberOf` both show it. An empty list read as absence,
   which is the absence-vs-denial class, committed inside the verification of a fix for it.
   **Use `memberOf` to check a service principal's directory roles.**

What this unblocks, now actionable: L4 can apply the label taxonomy for the first time;
V11.2 and L4's audit can be signed off; L10's Dependabot lane can author and auto-merge;
F120's compliance fix is live rather than inert; and V9.1 can read `security_and_analysis`
if the verifier PAT carries **Administration: Read**.

*Original entry follows, kept because a register that quietly edits itself is not a
register.*

### BLOCKER-1 (original) — No GitHub secrets exist. Not one. *(P-12, confirmed 2026-09-01)*

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

### ~~BLOCKER-2 — The Copilot Studio environment cannot be reached~~ **RESOLVED 2026-09-01**

**The Copilot Studio solution imported successfully** - the first time in this project's life.

**IT IS NOT THE SAME AS THE AGENT BEING PUBLISHED, and I recorded it as if it were.**
`import-agent.ps1` says so in its own header - "--publish-changes publishes solution
CUSTOMIZATIONS. That is NOT the same thing as publishing the agent in Copilot Studio" -
and prints "PUBLISH the agent in Copilot Studio. Nothing works until you do." I wrote
"imported and deployed" into this register, two pull requests and the session memory
anyway. The import step passing is evidence of an import, and nothing more. Publishing
remains a human step in Copilot Studio and is the next action for showpiece 1.

**The cause was not what this entry predicted, and that is recorded rather than edited
away.** The text below reasoned toward the Developer environment type being the wall:
Developer environments are provisioned for one individual, so a service principal was
expected to be unable to access one. That was wrong. A Developer environment accepts
application users perfectly well.

The actual cause was simpler: **a service principal gets no Dataverse access from Entra
alone.** `mls-github-deployer` had to be registered as an APPLICATION USER inside
`mls-authoring` and given **System Administrator**, which a solution import requires
(System Customizer routinely fails partway through an import, which is worse than failing
at the start). Once added, L8's import step passed on the next run.

**A second app user is needed and is not yet solved.** `mls-verifier` must also be an
application user there for **V8.1** to read the deployed solution's metadata, and finding a
read-only role for it is genuinely hard:

**SOLVED, and the read-only property survived it.** The sequence:

| Roles held | V8.1 |
|---|---|
| `Basic User` | 403 |
| `Basic User` + `Export Customizations (Solution Checker)` | 403 |
| + `Service Reader` + `Solution Checker` (all four) | **reads the solution** |

The 403 is gone and V8.1 now fails on CONTENT rather than permission - a different and far
healthier failure, described below.

**None of those four is `System Customizer` or `System Administrator`**, so `mls-verifier`
still cannot write customizations to the environment it audits. That was the reason for
refusing System Customizer earlier, and the read was obtained without giving it up: the
stated design claim is intact rather than quietly compromised.

**The minimal role has NOT been isolated, and nobody should assume it was.** All four were
granted together. The enabling one is `Service Reader` or `Solution Checker` - almost
certainly the latter, since reading a solution's component list is its purpose - and
proving it means removing one, re-running L8, and watching whether V8.1 reverts to 403.
Three cycles would pin it. That is hygiene, not a fix, and it is left undone deliberately.

**What V8.1 now says, and the open question it raises:**

    components missing []  extra [Conversation Start, Conversational boosting,
    End of Conversation, Escalate, Fallback, Goodbye, Greeting,
    Meridian Launch Copilot, Meridian Ops Tools, ..., Sign in, Start Over, Thank you]

**Nothing is missing.** The deployed agent carries 16 components the committed solution
does not list, and most are Copilot Studio's DEFAULT SYSTEM TOPICS - Greeting, Goodbye,
Escalate, Fallback, Multiple Topics Matched - which the platform adds to every published
agent. So the criterion compares an exact set against a solution export that never
contained them.

That is a real judgement, not a bug to paper over: either the committed export is stale and
should be re-exported to include what a published agent actually contains, or V8.1 should
tolerate platform-generated topics while still failing on a missing or unexpected CUSTOM
component. The second is probably right - a criterion that breaks every time Microsoft adds
a default topic is measuring the wrong thing - but it must not become "ignore extras",
which would let a real stray component through.

Two cautions for whoever picks this up. **Dataverse role changes take minutes to
propagate**, and both failures above were tested immediately after the change - so neither
is a safe conclusion on its own; re-run unchanged before adding another role. And if no
read-only combination works, the honest resolution is **System Customizer recorded as a
deliberate compromise in L08.md**, stating that Dataverse offers no clean read-only grant
for solution metadata - because "the Verifier reads as a read-only identity" is a STATED
design claim, and it is about to be either true-with-effort or quietly false.

*Original entry follows, kept because a register that quietly edits itself is not a
register.*

### BLOCKER-2 (original) — The Copilot Studio environment cannot be reached

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

**NARROWED 2026-09-01 to a single question.** The three candidate causes above are
resolved: the environment **exists and is healthy**. It is `mls-authoring` — Developer
type, State Ready, **Dataverse: Yes**, region United States — and L8's configured URL
points at it. (The tenant's other environment, `Default Directory`, is in Canada and has
**Dataverse: No**, so it was never a candidate. Region is not the cause either: L8 passes
the environment URL explicitly rather than inferring it.)

What remains is that L8 authenticates as the SERVICE PRINCIPAL — `pac auth create
--managedIdentity`, i.e. `mls-github-deployer` over OIDC — and `pac` reports
`No Dataverse organization was found matching the specified criteria`. That message is what
`pac` returns when the authenticated principal cannot ENUMERATE the org, not necessarily
when the org is absent. A service principal gets no Dataverse access from Entra alone; it
must be registered as an **application user** inside the environment and given a role.

**THE ONE TEST THAT SETTLES IT:** `mls-authoring` → Settings → Users + permissions →
Application users → **+ New app user** → `mls-github-deployer` → **System Administrator**.

- If it is accepted, L8 is unblocked with no environment change and no spend.
- If the portal refuses, the **Developer environment type is the wall** — those are
  provisioned for one individual developer — and the fork is worth naming rather than
  grinding at:
  - a **Sandbox** environment would work but needs capacity, which is **paid**, a **G2
    gate**, and contradicts the recorded "$0 Developer Plan" decision for C5;
  - or accept **"a human publishes the agent once"** as a documented limitation.

The second is the better trade. The showpiece is *the agent answering from the lakehouse*,
not the mechanism that imported it, and buying capacity to automate a one-time import
spends real money on the least interesting part of the story. **But it must be written
down as a deliberate limitation, not left looking like something that never worked.**

Note also: `fabric@` owns the Fabric trial, and switching CI to authenticate as it was
considered and rejected — it needs a stored password, which breaks hard rule 5 and would
fail against MFA, and it turns an operator account into a shared automation credential.
The owner's job here is to GRANT access to the service principal, not to be it.

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

## IN FLIGHT AS OF 2026-09-01 19:20 UTC — check these first

Three things were running when this was written. **Check their outcome before starting
anything new**, because two of them change the scorecard above.

| What | Run | What it proves |
|---|---|---|
| **L6 re-run** | `33547680971` | Whether the F119 storage-firewall fix let the Function Apps finally receive code. **V6.7 answers this explicitly** — it asserts each Function App contains functions, and distinguishes "empty" from "could not look" |
| **L4 re-run** | `33548766843` | Whether the F121 fix publishes the label policy cleanly. The four labels already exist; this is the policy and then the audit |
| **compliance re-run** | `33548856920` | **Whether F120 is actually fixed.** PR #88 was closed and its branch deleted deliberately, so the repaired `SELF_HEAL_TOKEN` path recreates it. If the new PR has checks attached, F120 is proven; if it does not, F120 is not fixed and the entry should be reopened |

That last one is a deliberate test rather than a workaround. #88 could never merge because
its head commit was pushed by `GITHUB_TOKEN` and had **zero check runs attached** — nothing
retroactively attaches checks to a commit, so reopening the PR ran workflows against the
merge ref and left the head unchecked. The artifact is regenerable from the workflow, so
nothing was lost by deleting the branch.

**Do not assume any of the three succeeded.** Every one of them is a fix whose predecessor
looked fine and was not.

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
> that `mls-github-token` (**renamed `mls-data-api-github-token` later the same day** -
> three GitHub tokens now exist and the old name could not say which) is a NEW secret with
> no runbook step of its own, so anyone
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

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
on 2026-09-02, with the evidence beside it.

### The four showpieces — 3 working, 1 waiting on Dependabot

| # | Showpiece | Status | Evidence |
|---|---|---|---|
| **2** | **Control tower** — Dev/Sec/Ops on Well-Architected pillars | ✅ **working** | All three tabs render live data: 2,587 workflow runs, 76 open code-scanning alerts, 4 Dependabot alerts, 4,515 cost rows, 1,200 telemetry rows. Screenshots with provenance in `docs/evidence/` |
| **4** | **Compliance platform** — NIST 800-171 | ✅ **working** | **Independently audited for the first time, 2026-09-01.** `verification/layer-12-audit.ps1` runs as `mls-verifier` and reports **4 PASS + 2 SKIP**: the shipped artifact is complete against the catalog and carries no score, the honesty invariant holds in the file rather than only in the derivation, Easy Auth refuses anonymous callers, and the collection history is a git history. The two SKIPs name their owners rather than being gaps |
| **1** | **Copilot service** — Ask tab over Direct Line | ✅ **DEMONSTRATED** | **2026-09-02, observed in a browser by a signed-in human** — not inferred from a green run. Asked *"what day of the week had the most launches"* the tab answered **"Saturday had the most launches, with 309 launches recorded in the launches table"**, citing its source. The figure was **independently re-derived** through the MCP server (Saturday 309, Sunday 181, Tuesday 162 …), an exact match. Ten findings between "not configured" and this: F122, F124, F128, F129, F130, F131, F133, F134, F135, F136 — all fixed **in the repo**, so a rebuild reproduces the working state. **And it is not open**: the endpoint 401s an anonymous caller; the page forwards its Easy Auth token and the Function verifies signature, issuer, audience and expiry before the Direct Line secret is touched. That control shipped with a bug of its own (**F142**): the `id_token` expires after about an hour and nothing renewed it, so the tab worked and then locked its user out. Fixed - one refresh, one retry, and a sentence when that fails |
| **3** | **Self-healing code** | 🟡 **chain works, nothing to heal** | **The token half is DONE and proven** (2026-09-01): `SELF_HEAL_TOKEN` is a repository secret, the 403 is gone, the selector reads the alert surface, **V10.3 PASSES**, and the Dependabot lane runs instead of skipping. What is missing is a **subject**: Dependabot opens no security PR for the three seeded CVEs, so the lane has nothing to adopt (**F126**, cause unresolved, deferred). This is the ONLY showpiece with an open engineering blocker |

### The twelve layers — 8 verified, 2 partial, 2 not done

| Layer | Status | Note |
|---|---|---|
| L1 repo / IaC / OIDC / up-down | ✅ verified | The pipelines are the product and they run |
| L2 landing zone | ✅ verified | V2.1, V2.2 PASS |
| L3 Entra | ✅ verified | V3.1–V3.4 PASS |
| L7 apps | ✅ verified | **6/7 on 2026-09-01, and the layer has 7 criteria now, not 5.** V7.5, V7.6 and V7.7 had NEVER been evaluated on any run - every failure was F104's expired assertion, not the estate. With that fixed, V7.5 and V7.6 passed first time: **V7.6 independently confirms the data API returns real rows**, which is what section D was about. V7.7's failure was F127, a probe following a redirect into Microsoft's login page; fixed |
| L11 teardown | ✅ verified (down half) | V11.1 PASS. Rebuild proven once. V11.2's blocker (BLOCKER-1) is **closed** — the up-half has simply not been re-run since, and doing so is the sponsor's phase-1 item |
| L5 Fabric | 🟡 partial | Deployed and seeded (10 tables, `launches`=1,200). Its audit has not passed cleanly since F104/F105/F114 were fixed — **re-run it** |
| L6 platform | ✅ verified | **5 PASS + 2 PENDING on 2026-09-01**, and both PENDINGs sign off by design (V6.3's cost export has a 24 h window, V6.4's SQL auto-pause a 75 min one — L06.md V6.3). Both Function Apps hold code (V6.7) and **V6.8 confirms the Key Vault reference actually resolves**, which is what F122 broke silently |
| L9 DevSecOps chain | 🟡 partial | 4/5 — V9.2-V9.5 PASS (negative CVE test, SBOM, ZAP, Defender toggle). **V9.1 now PASSES** (re-run 2026-09-02 as a filtered diagnostic): F103's fix works, and the criterion reads *"GHAS features the Verifier can observe are enabled"* rather than reporting an admin-only field's absence as a disabled control. The same run turned up **F144** - ZAP has been scanning a hostname from an environment that no longer exists, caught by the empty-report gate rather than passed over. A full unfiltered L9 is still owed for a verdict |
| L12 compliance | ✅ verified | **The last layer to get an audit, 2026-09-01.** 4 PASS + 2 SKIP; wired into `compliance.yml` as a `verify` job after every collection. `MlsAudit` capped `Layer` at 11 until now - the module could not represent layer 12 even if someone had written the script |
| L4 Purview labels | ✅ verified | **DONE 2026-09-01, the first time ever.** `verify L4 (mls-verifier)` PASSED. Four sensitivity labels now exist in the tenant - `mls-public`, `mls-internal`, `mls-confidential`, `mls-export-controlled` - where there had been none. The label POLICY failed (F121, fixed, re-run in flight) and the audit has not signed off yet |
| L8 Copilot Studio | 🟡 partial | **Solution IMPORTED and agent PUBLISHED, 2026-09-01 — both firsts.** Publishing is a separate, human, Copilot Studio step (`import-agent.ps1`: "--publish-changes publishes solution CUSTOMIZATIONS. That is NOT the same thing as publishing the agent"), now done. **F132 is fixed** and proven end to end (2026-09-02): a plain dispatch imported 1.0.2.0 -> 1.0.3.0, the new preflight reported *"Package type Unmanaged matches the committed source"*, and the Direct Line golden-question eval passed afterwards. **F145 is fixed**: V8.1 had never been able to pass - it compared one committed component against the seventeen Dataverse reports - and the recorded cause (a Verifier permission) was wrong. V8.2-V8.5 still wait on an eval artifact and a resumed capacity |
| L10 self-healing | ❌ chain never executed | Not for want of a subject: four Dependabot alerts are open. The chain cannot READ them (**F123**). V10.3 now fails on that rather than skipping quietly |

### The mission itself

*"Fully agent-instantiated … destroyed and rebuilt on demand … the repo is the product."*
**Substantially achieved.** The estate deploys from a cold dispatch in layer order with
independent sign-off at each step, and teardown and rebuild have both been demonstrated.

**Money is closer to being a constraint than this section used to claim.** It said "~$1.40
against a $200 ceiling" and that figure is stale by roughly 5x: month-to-date is **$7.70**, of
which **Azure SQL is $7.65 - 99% of all spend** - on a run rate of roughly **$4/day, about $120
over the 30-day window**. Nothing is broken and no budget has been breached; the point is that
one idle database is most of the bill, and the number a planner reads should be the number.
See **F143**. The calendar is still the tighter constraint, but not by the margin claimed.

---

## THE BLOCKER TREE — what actually stands between here and 4/4

*Ordered by how much each unblocks. Everything not-done above traces to one of these five.*

**BLOCKER-1 and BLOCKER-2 are both CLOSED as of 2026-09-01.** What is left:

- **BLOCKER-3 is FULLY CLOSED (2026-09-02): the agent answers from real data.** Asked which
  weekday has the most launches it replied *"Saturday, with 309 launches recorded in the
  launches table"*, citing its source — and the figure was **independently re-derived** through
  the MCP server rather than taken on trust (Saturday 309, Sunday 181, Tuesday 162 …), an exact
  match. Eight findings stood between the tab saying "not configured" and that answer: F122,
  F124, F128, F129, F130, F131, F133, F134. **All are fixed in the repo**, not by hand, so a
  rebuild reproduces the working state rather than reverting to it — which matters, because
  F129 and F131 were both configurations that could not have survived the teardown-and-rebuild
  this demo exists to showcase.

  **The authentication half closed on 2026-09-02.** The page forwards its Easy Auth token
  and the Function verifies signature, issuer, audience and expiry before touching the Direct
  Line secret; both are deployed, and an anonymous caller gets 401. Two findings came out of
  shipping it: **F135** (the token store was off, so there was no token to forward - I had
  verified a token without checking one could be *obtained*) and **F142** (it expires after an
  hour and nothing renewed it - I verified expiry without asking what happens when it
  *expires*). Same shape twice: the check was right and the lifecycle around it was not.

- **BLOCKER-4: the token half is DONE and proven.** `SELF_HEAL_TOKEN` is now a repository
  secret, the 403 is gone, the selector reads the alert surface, **V10.3 PASSES**, and the
  Dependabot lane runs instead of skipping. Both recorded problems are closed: the chain can
  see its subject (**F123**), and its verify job can actually run (**F125** - it never could).
  **What remains is an OPEN QUESTION, not a known fix.** Dependabot opens no security PR for
  the three seeded CVEs, so the lane has nothing to adopt. A full heal-and-re-arm cycle
  (#148, #149) did not change that - GitHub reopened the same alerts rather than raising new
  ones (**F126**). Ruled out: the repo setting, patched-version availability, ignore
  conditions, lingering branches. Leading candidate: `open-pull-requests-limit: 0` on
  `/apps/vuln-lab`, whose exemption for security updates is asserted in a comment and has
  never been verified. **Do not edit that limit casually** - raising it also enables
  version-update PRs that would disarm the seed.
- **BLOCKER-5 is CLOSED** (2026-09-01). `verification/layer-12-audit.ps1` exists, runs as
  `mls-verifier`, and is wired into `compliance.yml`. Four criteria are checked
  independently and two are explicit SKIPs naming where they *are* checked - V12.3 would
  have to defeat V12.4 to run, and V12.5 is L8's V8.3 against the same server.
- **One open sub-item, not a blocker:** V8.1 needs a Dataverse read role for
  `mls-verifier` - see BLOCKER-2's resolved entry for what has been tried.

### F156 — the cost donut dropped services silently, so new spend could vanish *(fixed 2026-09-02)*

Asked to make sure newly enabled Defender spend reaches the Ops tab, the plumbing checked out:
the Cost Management query groups by `ServiceName` with **no filter**, and the "Run cost by
service" table lists every row. Defender appears there by construction.

**The chart above it did not.** `Cost by Azure service` charted `byService.slice(0, 8)` and
discarded the tail, so:

- the ring totalled **less** than the "Total run cost" KPI printed directly above it, and
- a small line simply vanished — which is precisely what a Defender plan billing cents beside a
  database billing dollars would do.

Five Defender plans were enabled today. Each is individually tiny next to Azure SQL, so all five
would have fallen off the ring while the total silently disagreed with itself.

**Fixed:** the tail is grouped as `Other (N services)` rather than dropped, so the ring
reconciles with the total and the chart says how many it summarised. Mutation-tested — restoring
the plain `slice` fails three tests, including one that plants a cent-sized
`Microsoft Defender for Cloud` line and asserts it survives into the total.

**A cost chart that does not add up is worse than no cost chart**, because it invites arithmetic
a reader will trust.

**Not fixed, and worth stating:** the Ops tab shows what is billing, not what is *about to*.
All five Defender plans are on free trials that expire **2026-10-01/02** — about ten days after
the 30-day demo window closes. Nothing on the tab would warn anyone that a $0 line becomes a real
one on that date. Surfacing trial expiry needs a feed that carries it; `az security pricing list`
returns `freeTrialRemainingTime`, so the data exists.

### F155 — the attack surface was written by hand, so two internet-facing apps were never scanned *(fixed 2026-09-02)*

F152, earlier the same day, enumerated the estate's external surface and listed **four** entries.
The sponsor's reaction — *"I think we have more than 3 container apps, our documentation is
probably out of date"* — was right, and understated it. Read live:

    mls-control-tower-demo-ca   external   Easy Auth
    mls-launch-ops-demo-ca      external   Easy Auth
    mls-compliance-demo-ca      external   Easy Auth
    mls-mcp-demo-ca             external   app-level bearer only
    mls-data-api-demo-ca        INTERNAL   -
    mls-vuln-lab-demo-ca        no ingress -
    mls-cost-ingest-demo-func   external   NONE  -> HTTP 200 anonymous
    mls-directline-demo-func    external   NONE  -> HTTP 200 anonymous

**Two Function Apps, internet-facing, answering 200 to an anonymous caller with no platform
auth, that no scan had ever touched** — and that F152's own list omitted, because that list was
written by hand and stopped at container apps. They are not even in the same resource group
(`mls-rg-ops`, not `mls-rg-apps`), which is exactly the sort of detail a hand-written inventory
loses.

**The class:** a surface written down is a surface that goes stale the next time someone
deploys. F144 taught the same lesson about one hostname; this is the same defect applied to the
*set* rather than to a member of it. An inventory that is not derived is a guess with a
timestamp.

**Fixed by enumerating instead of listing.** `zap.yml` now asks Azure every run which Container
Apps have `ingress.external` and which Function Apps are running, classifies each anonymously
(`content` / `auth-wall` / `unreachable`), and scans every one that answers with content. The
scan is a **matrix**, `fail-fast: false` — a run is an expensive observation and returns
everything it saw, so one endpoint's High-risk alert must not cancel five other scans.

**The audit contract is untouched.** A merge job combines the per-target reports into the single
`zap-baseline-report` artifact V9.4 already downloads by name, so the criterion now asserts zero
High across **every reachable endpoint** rather than across one, with no change to
`layer-09-audit.ps1`. The merge runs on `always()`, because a target that failed its own gate
still produced a report and hiding it would hide the findings worth having.

**Still open:** the three Easy Auth apps remain unscannable by an unauthenticated baseline, and
are correctly reported as `auth-wall` rather than passed. An Application ID URI was added to
`mls-launch-ops-demo-app` to make an authenticated scan possible; minting a token then failed
`AADSTS65001 consent_required`, so it needs an app-role assignment for the CI service principal.
That work is not done, and the criterion says so rather than implying coverage it does not have.

### F154 — the security board understated severity, trebled the work, and counted a fixture as exposure *(fixed 2026-09-02)*

Three defects on one panel, found by looking at it rather than by a check.

**1. High rendered GREEN.** The bar chart set no colour, so the chart library assigned from a
*categorical* palette by index: Critical blue, **High green**, Medium and Low pink. Green is the
one colour that reads as "fine", sitting on the second-most serious bar on a security board.
Colour was working against the reader. Severity colour is now explicit, ranked and semantic, and
a test asserts every bar carries one.

**2. "88 open alerts" is 30 distinct findings.** The container scan raises the same base-image
CVE once per image, so three images treble every finding. The count was true and overstated the
real work roughly threefold — in a repository whose entire argument is that it does not overstate
itself. The board now leads with **distinct findings** and reports **alert instances** beside it,
and the chart's own subtitle says how many collapsed into how few.

*(An earlier note in this session put the distinct count at "about 6", reasoning from the top-6
rule IDs. It is 30. Counting beats inferring.)*

**3. One of the two open criticals is a deliberate fixture.** `CVE-2021-44906` is seeded in
`apps/vuln-lab` for L9's negative test — V9.2 exists to prove CI fails on it. The board could not
tell it from real exposure, because **`manifest_path` was dropped by the data-api's projection**,
so the only field that distinguishes them never reached the browser. It is now carried, seeded
alerts are counted separately as **"Seeded for the demo"**, and they are **labelled, never
hidden** — removing them would be the mirror-image lie.

The sharpest evidence is in the test fixture: **High falls from 2 to 1**, because its only
high-severity dependency alert is a seed. Mutation-tested both ways — counting seeds as real
fails three tests, dropping the colours fails a fourth.

**Two things this turned up on the way:**

- **The feed contract is declared twice** — `apps/data-api/src/contract/feeds.ts` and
  `apps/control-tower/src/providers/types.ts` — with nothing keeping them in step. A field added
  to one and not the other arrives `undefined` at runtime, with no error and no test. Both now
  carry a note; the drift risk deserves its own check.
- **`dependabot/alerts?state=all` returns an empty list.** No state parameter returns 10, and
  `state=open` returns 8 — but `state=all`, which is valid for *code scanning*, is not valid here
  and GitHub answers it with `[]` rather than an error. Anyone writing the obvious query gets
  zero Dependabot alerts and no indication anything is wrong. It was checked before the trend
  chart was built on it.

**Deferred deliberately:** the opened/closed-over-time chart the sponsor asked about. The data
supports it — 411 code-scanning alerts, every closure dated — but 390 of the opens and all 323
closures fall on **2026-08-29**, the day CodeQL first swept every image. The chart would be one
column and two slivers: true, and a picture of a single scan rather than a working find-and-fix
cycle. It gets built when the rebuild gives it a second data point.

### F153 — Defender has never assessed this subscription, and nothing noticed *(criterion added 2026-09-02)*

The sponsor direction's phase 3 promises **"Defender scans producing real posture"**. There is
none, and there never has been:

    GET .../Microsoft.Security/secureScores?api-version=2020-01-01   -> empty
    GET .../Microsoft.Security/secureScores/ascScore                 -> ResourceNotFound
    GET .../Microsoft.Security/assessments?api-version=2021-06-01    -> empty

Read at the REST layer, not through the CLI, so this is not a stale api-version artefact. The
MCP server's `get_defender_posture` fails `404 Secure score 'ascScore' does not exist` for
exactly this reason — the tool is right and the estate is empty.

**Nothing asserted it.** V9.5 checks that the Defender plan can be toggled on and off. A plan
that toggles perfectly and assesses nothing passes V9.5. That is the plumbing-without-water gap
§ D describes, in the security layer.

**The trap, and why the new criterion names it.** The Azure **Policy** half works:
`ASC Default` (`SecurityCenterBuiltIn`) is assigned and evaluating — **6 non-compliant resources
across 35 policies**. So an operator who asks "is the security initiative assigned?" gets *yes*
and concludes Defender is healthy. Assessments and secure score are a **different pipeline**, and
they are the one the demo reads. V9.6's failure message says this outright so the reader is not
sent to re-check an assignment that is already there.

**V9.6 added:** at least one secure score OR at least one assessment. Three outcomes, not two —
an endpoint that does not answer is **UNOBSERVABLE**, never "Defender produces nothing", because
reporting an absent control on the strength of a failed read is the class this repository pays
most for. Both failure paths are `-Final`: Defender's assessment surface fills over hours, so a
five-minute retry cannot change the verdict and must not spend the wall clock reaching the same
one. Mutation-tested; 21 L9 audit tests pass.

**Cause not established, deliberately.** `FoundationalCspm` and `Discovery` are `Standard`, the
provider is registered, 30 resources exist and 1,302 assessment definitions are visible — yet no
assessment has ever been produced. That is recorded as the observation it is rather than a
diagnosis, per the register's own habit of distrusting confident first explanations.

### F152 — the ZAP scan has been assessing a login redirect *(fixed 2026-09-02)*

V9.4 passes. It asserts "ZAP report artifact exists with 0 High", and that is a true statement
about **a door**.

`launch-ops` runs behind Container Apps Easy Auth with
`unauthenticatedClientAction: RedirectToLoginPage`. An anonymous request gets a **302 to
login.microsoftonline.com with a zero-length body**, so an unauthenticated baseline scan never
reaches the application. Pulled from the last run's own artifact:

    sites scanned            : 1
    distinct URLs in alerts  : 3   ->  /   /robots.txt   /sitemap.xml
    alerts                   : 17  ->  all describing the REDIRECT

Every finding is about Easy Auth's own response: "Cookie with SameSite Attribute None" (Easy
Auth's cookies), "Session Management Response Identified" (the login flow), CSP and
anti-clickjacking headers missing **on a 302**. Zero application URLs were assessed.

**Third time this criterion has reported a verdict it never earned.** F102: the gate step was
skipped and its failure read as a security failure. F144: the target was a hostname from an
environment that no longer existed. Now: the target resolves, answers, and is a login wall.

**Why it cannot simply be authenticated.** Checked before designing anything: the launch-ops app
registration has **no `identifierUris` and no exposed OAuth2 scopes**, so no token can be minted
for its audience — `az account get-access-token --resource api://<clientId>` returns
`AADSTS500011: resource principal not found`. Easy Auth there is interactive sign-in only.
Adding an API audience so a scanner can get in would widen a UI app's auth surface for the
scanner's benefit, which is a poor trade; driving a real user login needs a stored password,
which is a rule-5 credential.

**Fixed by scanning what an unauthenticated attacker actually reaches, and by refusing to call
the other thing a pass.** The estate's real external surface, enumerated:

    mls-control-tower-demo-ca   external   Easy Auth (RedirectToLoginPage)
    mls-launch-ops-demo-ca      external   Easy Auth (RedirectToLoginPage)
    mls-compliance-demo-ca      external   Easy Auth (RedirectToLoginPage)
    mls-mcp-demo-ca             external   NO platform auth - app-level bearer only
    mls-data-api-demo-ca        INTERNAL   -
    mls-vuln-lab-demo-ca        no ingress -

`zap.yml` now classifies the target anonymously before scanning (`content` / `auth-wall` /
`unreachable`), scans the **API surface** when the app is a wall, and the gate **fails as
UNOBSERVABLE** when nothing but a redirect was assessed. A "0 High" that describes a login page
can no longer be recorded as a pass.

### F151 — the closed credential list was not closed *(open — needs a decision)*

CLAUDE.md rule 5 states "the complete list of long-lived credentials" and names two Key Vault
entries. **The vault holds four.** Alongside the Direct Line secret and `mcp-auth-token` it
carries `mls-github-token` and `mls-data-api-github-token`, which are referenced **nowhere** in
`infra/`, `.github/` or `apps/`.

The list is closed precisely so this cannot happen, and it happened anyway. The cost is not
hypothetical: `gitleaks.yml`'s incident text is the rotation runbook, and it agreed with
CLAUDE.md rather than with the vault — so a leak would have rotated four credentials and left
two behind, unnoticed, because nothing named them.

**Contained, not resolved.** Both are now in the rotation table and CLAUDE.md records the
discrepancy. What is still owed is the decision: establish whether anything reads them by a name
built at runtime, then either rotate-and-delete them as orphans or promote them into the list
with a written reason. **Do not delete on the strength of a grep** — F147 is a fresh reminder
that a value can be read under a name no static search will match.

Found by taking a census rather than by a check, which is itself the finding: nothing asserts
that the vault's contents match the documented inventory. That is a cheap check nobody has
written.

### F150 — my recovery link signed the user out and left no way back *(fixed 2026-09-02)*

F149 shipped a "Sign in again" link. The sponsor clicked it, chose their account, **was signed
out**, and landed on:

> **Agent unavailable** Could not read this session's Entra token from /.auth/me...

Worse than the expired token it was meant to repair, and the message offered nothing.

**Two mistakes, one in each half.**

**The link pointed at `/.auth/logout`.** The reasoning was that ending the session would let the
app's own `unauthenticatedClientAction: RedirectToLoginPage` start a fresh flow. It does not
reliably: the post-logout redirect lands on `/`, which the browser can answer **from its own
cache** - the SPA shell was already loaded - so the page renders with no session and never
reaches the middleware that would have redirected it. `/.auth/login/aad` re-runs the
authorization-code flow *keeping* the session, and is a server endpoint that cannot be cached.

**Verified against the deployed app this time rather than reasoned about:**

    GET /                                           302 -> login.microsoftonline.com
    GET /.auth/me                                   302 -> login.microsoftonline.com
    GET /.auth/login/aad?post_login_redirect_uri=/  302 -> login.microsoftonline.com
    GET /.auth/logout?post_logout_redirect_uri=/    302 -> login.microsoftonline.com

**And `readEasyAuthToken` could not tell "signed out" from "no token".** `/.auth/me` answers an
unauthenticated caller with a **302**, and a default `fetch` follows it to
login.microsoftonline.com where CORS throws - so both states collapsed into one null and one
message. It now reads with `redirect: "manual"` and returns three outcomes: a token, **signed
out** (offer the link), or **signed in with no token in the store** (F135's case - offer nothing,
because signing in again cannot fix a deployment).

**The test that should have caught it asserted the defect.** `it("ends the session rather than
just visiting the login endpoint")` passed, because it encoded exactly the same wrong assumption
as the code. A test written from the same mistaken premise as the implementation is not
independent evidence - it is the premise, restated. It is now inverted and says why.

Mutation-tested both ways: restoring the logout URL fails three tests, removing
`redirect: "manual"` fails a fourth. 121 passing.

**Standing limitation, not a defect:** the link is the correct FALLBACK, but it should be rare
rather than hourly. It is hourly because Easy Auth here has no client secret and no
`offline_access`, so no refresh token exists. Configuring both makes renewal silent - at the cost
of a long-lived credential, which is a rule-5 decision and not one to take quietly.

### F149 — I fixed the expiry with a refresh the provider cannot perform *(fixed 2026-09-02)*

F142's fix reached the browser and produced exactly the message it was written to produce:

> **Agent unavailable** This sign-in has expired, so the Ask tab cannot prove who is asking.
> Reload the page to sign in again - the agent itself is fine.

**Both halves of that fix were wrong, and the configuration says so plainly:**

    az containerapp auth show -n mls-control-tower-demo-ca ...
      identityProviders.azureActiveDirectory.registration
        clientSecretSettingName : (none)
        login (scopes)          : (none - so no offline_access)

Redeeming a refresh token is a **confidential-client grant**. With no client secret and no
`offline_access`, **no refresh token is ever issued**, so `/.auth/refresh` had nothing to redeem
and could not have succeeded on any run. And the fallback advice was equally empty: **reloading
does nothing**, because the session cookie is still valid and Easy Auth serves the SAME stored
token rather than re-authenticating. That is precisely why an Incognito window worked and F5 did
not - evidence that was already in hand when F142 was written.

**This is F135's class for the third time in two days.** F135: verified a token without checking
one could be obtained. F142: verified expiry without asking what happens when it expires. F149:
wrote the renewal without asking whether renewal was possible. Each time the code was careful
about the half already in hand and silent about the half it depended on.

**Fixed with what the provider can actually do.** Ending the Easy Auth session and letting the
app's own `unauthenticatedClientAction: RedirectToLoginPage` run the login flow again needs no
credential; Entra answers it from the live browser SSO session, so it is normally a redirect
rather than a password prompt, and it puts a new `id_token` in the token store. The error now
carries a `signInUrl` and the tab renders **a link the user clicks** - never an automatic
navigation, which is how one bad token becomes a redirect loop. The link is present ONLY for an
expired sign-in: a 500 offers none, because signing in again would not fix the deployment.

`/.auth/refresh` is kept but is no longer load-bearing - a fork that configures a client secret
gets silent renewal from it for free - and its comment now states the precondition instead of
assuming it. Mutation-tested: removing the recovery URL fails the test. 118 passing.

**Checked at the same time, because the sponsor asked whether the two tabs trade off:** they do
not. `data-api` over the last 24 h shows `GET /feeds/:name` **200 x 98** and **304 x 21**, latest
17:12 UTC, with the last **502 at 15:19 UTC** and none since - the F139/F140 cost-cache work
holding. Ops and Ask are independent subsystems that happen to share a page; nothing about
fixing one has ever broken the other.

### F147 — the eval looked for the Direct Line secret under a name nothing creates *(fixed 2026-09-02)*

L8's eval job has reported, on every run:

    mls-sec-demo-kv holds no 'directline-secret', so the agent cannot be evaluated
    and no artifact was produced.

**The vault holds `mls-directline-secret`.** The estate names it in the `demo` environment
variable `MLS_DIRECTLINE_SECRET_NAME`, which is what L6 hands the Bicep and what the Function's
Key Vault reference resolves - V6.8 confirms that reference resolves, so the secret has been
readable all along. The eval job hardcoded `directline-secret`, the name in the **G0 bootstrap
runbook**, and never read the variable.

**The invisible-value class again** (F122, F123, F124, F125): a value that exists, is spelled
correctly, and cannot be seen by the thing that reads it. What makes this one expensive is the
MESSAGE - "holds no 'directline-secret'" reads as *nobody has created it yet*, and it sent a
reader off to publish an agent and mint a secret that had been in the vault for a day.

**Four criteria skipped on it - V8.2, V8.3, V8.4, V8.5 - on every run, while the job reported
success**, which is correct: skipping cleanly is exactly what that job is designed to do when it
cannot evaluate. Nothing was lying. The wrong name simply meant it could never evaluate.

**I repeated the error in my own reporting**, which is worth recording: I told the sponsor the
Direct Line golden-question eval "passed" after the 1.0.3.0 import, and offered it as evidence
the agent still answered. It never ran. A job whose success means "I correctly declined to do
anything" is not evidence that the thing works.

**Fixed:** the job reads `vars.MLS_DIRECTLINE_SECRET_NAME`, and distinguishes the two states
that used to collapse into one message - an **unset variable** is configuration, a **missing
secret** is the G0 item, and they need different fixes. Encoded as a class: `az keyvault secret
show/set --name` must take an expansion, never a literal, because a name written in a workflow
is a second source for a value the environment already owns and outranks it silently. Mutation-
tested.

### F146 — I broke L9's startup with F144's own fix *(fixed 2026-09-02)*

The full L9 run dispatched to **prove** F144's fix reported:

    conclusion: startup_failure     jobs: []

No jobs, no logs, no annotation naming the cause. A reusable workflow cannot ask for a
permission its **caller** has not granted, and `zap.yml` had just started needing
`id-token: write` to read the live ingress FQDN. `layer-09-devsecops.yml`'s `zap:` job granted
`contents: read` and nothing else, so the whole workflow refused to start - not the one job at
fault, the whole thing.

**The diagnostic is the finding.** Every other failure in this repository leaves a log to read;
this one leaves an empty array. That makes it exactly the shape worth spending a check on, and
`verification/tests/failure-classes.Tests.ps1` now unions every `write` permission any job in a
called workflow declares and asserts the calling job grants each one. Deliberately over-strict:
it does not reason about which callee jobs actually run, because a caller granting slightly more
than one run needs is a far cheaper mistake than a workflow that cannot start. Mutation-tested -
removing the grant fails it, naming the job, the callee and the permission.

Worth stating plainly: **the check that would have caught this did not exist because I wrote the
defect and the fix in the same change.** F144 was verified as YAML that parses; nothing asked
whether the caller could satisfy what the callee now asked for.

### F145 — V8.1 could never have passed, and the recorded reason was wrong *(fixed 2026-09-02)*

The L8 run that imported solution 1.0.3.0 reported:

    [FAIL] V8.1  Deployed agent's solution ... match the committed solution exactly
           observed: components missing [] extra [Conversation Start, Conversational
           boosting, End of Conversation, Escalate, Fallback, Goodbye, Greeting,
           Meridian Launch Copilot, Meridian Ops Tools, mls_MeridianLaunchCopilot.
           shared_..., Multiple Topics Matched, On Error, Reset Conversation,
           Sign in , Start Over, Thank you]

**Sixteen confident, specific, wrong names.** Every one is a legitimate component of the agent,
committed to this repository, and a reader would have gone hunting for drift that does not
exist.

**The register's recorded cause - "V8.1 still fails on a Verifier Dataverse read permission" -
was wrong.** The read succeeded on every run; that is where the sixteen names came from. This is
why CLAUDE.md says to check a blocker's evidence yourself before acting on it.

**The real defect: the expected set was built from one of three files.** `Other/Solution.xml`
lists *root* components - one, the connector - while `msdyn_solutioncomponentsummaries` reports
*every* component, because a Copilot Studio agent's topics belong to the solution without being
roots of it. Set equality between those two vocabularies could never hold. **A criterion that
cannot pass is not a strict criterion, it is a broken one**, and it hid the question it existed
to ask.

**The committed side is fully enumerable, so the fix makes the check stronger, not weaker:**

    Other/Solution.xml                  RootComponent/@schemaName                     1
    botcomponents/*/botcomponent.xml    <name>                                       15
    Assets/botcomponent_connection...   @connectionreferenceid.…logicalname           1
                                                                                 -----
                                                                                    17

which is exactly what Dataverse reported. `<name>` is returned verbatim in `msdyn_name` - down
to the trailing space in `'Sign in '` - so the comparison stays exact rather than normalised; a
helper that trimmed there would hide a real rename behind a cosmetic one. V8.1 now compares
seventeen components where it compared one.

**Unobservable, never absent.** If the component files cannot be enumerated the criterion says
so. A truncated expected set turns every deployed component into an "extra", which is precisely
how this produced sixteen false names rather than one honest "I could not read the expected
list".

**A second defect fell out of the first, and it is the more instructive one.** V8.3 counted
"tool/connector components" by filtering the *same* list for `connector|connection|tool|agent`.
Enriching that list for V8.1 silently widened V8.3: a topic whose display name is
**"Meridian Ops Tools"** would have counted as a tool, and V8.3 would have failed on a correct
solution - trading one broken criterion for another. Widening one check's input widened a
different check's meaning. Roots and connection references are now their own fields: two
questions, two lists.

**The fixture was part of the problem.** It wrote a lone `Solution.xml` into a temp directory,
so it exercised a parse the production code no longer performs and would have stayed green
while the thing it stands for was broken. It is now a real solution tree.

Twenty L8 tests pass, four of them new.

### F144 — the ZAP scan has been pointed at a host that does not exist *(fixed 2026-09-02)*

An L9 diagnostic run to re-check V9.1 turned this up on the way past:

    Job spider failed to access URL
    https://mls-launch-ops-demo-ca.thankfulisland-7f9b1aba.centralus.azurecontainerapps.io
    check that it is valid : Name or service not known

The live app answers on `...happymeadow-9e15a087...`. `vars.STAGING_URL` was set at
2026-09-01T00:19Z and was correct then; the apps environment was recreated later that day
while fixing F129, and **a Container Apps environment domain is assigned at creation and
changes on every rebuild** - the one thing this demo exists to do. So every ZAP baseline since
has scanned nothing.

**This is F129's class and F90's before it**, in the one place the existing sweep cannot see: a
GitHub variable is not a committed artifact, and an absent or stale variable is a well-formed
string rather than an error.

**The gate behaved correctly, and that is the good news.** The scan produced no report and the
step said *"An unreachable target is a FAILURE, not a pass (L09 V9.4)"* rather than passing on an
empty result. That is F102's fix working on a defect nobody had found yet.

**Two things were wrong, not one.** The target was stored rather than derived; and the
resolution step asserted the URL was well-*formed* without asking whether it was
**reachable** - so the failure surfaced as `docker failed with exit code 3` inside a
third-party action, which names the symptom and not the cause. That is F135's rule again:
verify the input can be obtained before verifying that it is valid.

**Fixed:** `zap.yml` reads the live ingress FQDN from Azure and prefers it; an explicit
`target_url` input still wins; `vars.STAGING_URL` is a last resort for a checkout with no Azure
credentials, and when it disagrees with the live value the run says so rather than silently
preferring or silently ignoring it. The target must now resolve in DNS before the scan starts.
The Azure-login guard is a **step-level** `if:`, because a job-level one is evaluated before the
environment resolves and would mean "skip always" (F125).

**Encoded as a class:** a job that reads a stored estate hostname must derive the live one in
the same job. Mutation-tested - breaking the derive fails it. On its first run the sweep flagged
`layer-09-devsecops.yml` too; that one was prose drift in an input description rather than a
second hole, and the description was corrected.

### F143 — one idle database is 99% of the bill, and auto-pause is working correctly *(open, needs a decision)*

Measured directly from Azure Monitor rather than inferred, because Cost Management was
throttling (F140, and retrying deepens the window):

    mls-launch-ops-demo-sqldb   GP_S_Gen5 serverless, min 0.5 vCore, max 2, autoPauseDelay 60
    31 Aug 00:00 - 2 Sep 18:00Z (66 h): 61,596 vCore-seconds billed = 17.1 vCore-hours
    app_cpu_billed non-zero in 34 of 66 hours; cpu_percent non-zero in only 16

Month-to-date spend is **$7.70**, of which **$7.65 is SQL**. Everything else in the estate -
five Container Apps, two Function Apps, storage, Log Analytics, Key Vault - is four cents.

**Auto-pause is not broken. V6.4 is not lying.** Long stretches bill exactly zero, which is the
proof. Two things about the shape of serverless billing make an idle database expensive anyway:

1. **Every connection buys a minimum of 60 minutes online.** 60 minutes is the *floor* Azure
   allows for `autoPauseDelay`; it cannot be set lower. A single one-connection wake at 02:17
   costs a full hour.
2. **While online but idle it bills ~0.68 vCore/hour, above the 0.5 floor.** Serverless bills
   `max(CPU, memory/3GB)`, and `cpu_percent` is non-zero in half as many hours as
   `app_cpu_billed` - so this is the memory of a warm cache, not work being done.

**What wakes it, and none of it is wrong:** `data-api` serving the Ops tab (the daytime
clusters), `compliance.yml` at 02:17 daily, `self-heal.yml` every six hours at :13. Those are
the estate verifying itself, which is the thing this repository is *for*.

**So this is a decision, not a defect, and it is the sponsor's:**

- **Do nothing.** ~$120 of a $200 ceiling over the remaining 30 days. It fits, with less
  headroom than the old $1.40 figure implied.
- **Wake it less.** Drop `self-heal.yml` from every 6 hours to daily: up to 3 fewer hour-long
  wakes a day, maybe $1.50/day. It costs self-healing latency, on the one showpiece that is
  still not demonstrated.
- **Ask whether the database is needed at all.** The lakehouse already holds the launch data,
  and `data-api` reads Fabric for most feeds. If Azure SQL only backs one feed, retiring it is
  the whole $120. That is a design question worth an hour before it is worth a change.

**Not acted on.** Every lever trades away either verification frequency or a component the
demo may need, and none of the three is mine to choose.

### F142 — the sign-in expires after an hour and nothing renewed it *(fixed 2026-09-02)*

The Ask tab answered at 11:00 and returned 401 by 15:30, with:

> `{"error":"A valid Entra user token is required to request a Direct Line token."}`

Tenant and audience were provably correct - the Function expects `c3571944…` / `88106f53…` and
Easy Auth issues for exactly those - and `/.auth/me` succeeded, so the page had a token and sent
it. The failure was **expiry**, the fourth thing the Function verifies.

**The `id_token` is issued at sign-in with about an hour's life, and nothing renewed it.** The
token store persists what Easy Auth received; refreshing needs a client secret, which this design
deliberately does not have. So the control worked for an hour after sign-in and then locked the
user out of their own agent, with a 401 that reads like an outage.

**Confirmed before fixing, not assumed:** a fresh Incognito sign-in answered immediately.

This is **F135's shape a second time**. There I verified a token without checking one could be
*obtained*; here I verified its expiry without asking what happens when it *expires*. Both times
the check was correct and the lifecycle around it was not.

**Fixed:** a 401 from the token endpoint triggers one `/.auth/refresh`, re-reads `/.auth/me`, and
retries once. **No navigation happens automatically** - redirecting to a login endpoint on failure
is how a bad session becomes a redirect loop, and a loop is worse than the bug. When the retry
also fails the tab says *"This sign-in has expired… Reload the page to sign in again - the agent
itself is fine"*, which is true, actionable, and distinguishes a session problem from an outage.
Mutation-tested: disabling the refresh fails both new tests.

### F141 — nothing validated Bicep, so a typo cost a twenty-minute deploy *(fixed 2026-09-02)*

A malformed params file reached a deployment and failed there rather than in CI. The reason the
existing check missed it is worth keeping: **`az bicep build` on a template passes while its
params file is invalid** - only `build-params` reads the params file at all. A validation step
that names the thing it does not read is the same defect class as an audit that cannot see what
it reports on.

**Fixed:** `.github/workflows/lint-ci.yml` gained a `bicep` job that builds every template **and**
every params file, so the twenty-minute failure is now a sixty-second one.

### F140 — every page load was a retry, and so was the diagnosis *(fixed 2026-09-02)*

Cost Management throttles **per principal**, and each refusal lengthens the window. The Ops tab
had no cooldown: a reader pressing refresh on a 502 was extending the outage they were trying to
end. **I did it to myself during the diagnosis** - throttling my own admin identity by retrying
the query, which is precisely the mistake the code was making.

**Fixed:** `cloud.ts` records `costUpstreamBlockedUntil` on a 429 and serves the persisted answer
as `stale: true` until it passes, without calling upstream.

**Two bugs in my own fix, both caught by tests before deploy.** `isThrottled` read only
`err.message` when the status is in `detail`; and the detection regex was `/\x08429\x08/` -
`\b` had been corrupted into a literal backspace byte on its way through a heredoc. The second is
why `verification/tests/control-characters.Tests.ps1` now sweeps the repository for control
characters, and why CLAUDE.md carries a rule about how these files get edited.

### F139 — an in-memory cache on a scale-to-zero container is not a fallback *(fixed 2026-09-02)*

The Ops tab showed:

> **Data unavailable.** API `/api/feeds/azure-cost` responded 502. The Cost Management
> upstream did not answer successfully.

**Cost Management really is throttled** — verified directly, `HTTP 429 "Too many requests"` —
so this is an external rate limit, not a regression. And `cloud.ts` already handles it
correctly: a 429 with something cached is served with **`stale: true`** rather than silently,
because *"a retained figure presented as current is the same defect as an empty list presented
as zero"*.

**The problem is that the cache is almost never there to be served.**

    private costCache: AzureCostFeed | undefined;   // in-memory instance field
    mls-data-api-demo-ca  minReplicas: 0            // scales to zero

The comment beside the retry logic says *"the hour-long cache above is the real fallback"* —
and on a container that scales to zero, and is redeployed several times an hour during active
work, that premise is false. The cache dies with the process. So the fallback exists, is
correct, and is empty at precisely the moment it is needed: after a restart, when the first
request must go upstream, into a throttle that lasts minutes.

**Why it matters beyond today:** the Ops tab is half of showpiece 2, and this will recur at
demo time by construction — a cold container's first request is exactly when a demo begins.

**Two honest fixes, and they are not equivalent:**

1. **Persist the last good answer** (blob, written by data-api's existing identity) so a
   restart inherits it and the `stale: true` path can actually fire. Durable, ~45 minutes,
   costs nothing meaningful, and keeps the $0-idle guarantee.
2. **`minReplicas: 1` on data-api** — the cache survives because the process does. Simpler,
   but it is a **G2 spend increase** and it treats a caching problem with money.

(1) is the better answer; (2) is what to reach for only if idle cost is not a constraint.

**Fixed with (1), and the sponsor chose it explicitly.** `apps/data-api/src/backends/costCacheStore.ts`
persists the last good answer to a blob written by data-api's existing identity, with two
properties that matter more than the caching: **nothing in it may fail a request** (every method
swallows its errors and reports "no value", because a cache is an optimisation), and it always
writes `stale: false` - whether a reader should call a figure stale depends on when it is *read*,
which is `cloud.ts`'s decision, not the writer's. Idle cost is unchanged; `minReplicas: 0` stands.

**One thing needed a human to break a deadlock.** data-api's identity was already throttled by
Cost Management, so it could never complete the query that would populate its own cache. Seeded
once from an unthrottled admin identity, using the same API, subscription, query shape and
document shape the service writes itself - **$7.70 MTD**, of which **SQL Database is $7.65, 99%
of all spend**, which is worth a look given V6.4 asserts auto-pause. The grant was removed after
seeding.

### F138 — the agent answered a different question, because its tools told it to *(fixed 2026-09-02)*

Asked *"How much have we spent to date in our tenant subscription"*, the Ask tab replied:

> Total spend to date in the tenant subscription is **$23,561,191.14999999 USD**, based on the
> full history in the `cost_daily` dataset. Source: aggregated from the `cost_daily` table in
> the Meridian operations lakehouse. I also attempted to retrieve the spend history from the
> Azure Cost Management feed, but that request was **rate-limited (HTTP 429)**, so the total
> above comes from the lakehouse cost records instead.

**Two of the three things here are the agent behaving well.** It has the right tool
(`get_cost_series`), it tried it, it was throttled by Azure's Cost Management API — a known,
external, minutes-long rate limit where retrying deepens the throttle — and it **said so**
rather than presenting a number as though nothing had gone wrong. That is the honesty property
working.

**The third is a real defect, and it is not the 429.** `cost_daily` is *Meridian's fictional
business ledger*:

    columns: cost_id, date, cost_center, amount_usd, budget_usd, currency
    row:     CST-00001, 2024-01-01, "Propulsion", 9435.57, 8610, USD

Cost centres like "Propulsion", dated 2024. It is **not Azure spend**. The real subscription
has consumed roughly **$1.40**. So the fallback was not a fallback: **it answered a different
question and kept the original question's framing**, opening with "Total spend to date in the
tenant subscription is $23,561,191". A reader who stopped at the first clause — which is what
a reader does — would carry away a number that is wrong by seven orders of magnitude, about a
thing the dataset does not measure.

Citing the source does not repair this. "Based on the `cost_daily` dataset" is true and does
not tell a reader that `cost_daily` has nothing to do with their subscription.

**Why it matters here more than elsewhere.** This estate spends its verification budget on
refusing to overstate itself, and the outbrief's sharpest argument is that it catches its own
false claims. An agent that substitutes a synthetic business ledger for a cloud bill, and
narrates the substitution accurately while mislabelling the result, is the failure mode that
argument exists to rule out.

**The diagnosis above was wrong about whose defect this is, and the correction is the
useful part.** I recorded it as an agent that substituted a dataset. It did not choose to.
Reading its actual contract - the only thing an orchestrator reasons over when picking a tool -
the substitution was **written down as guidance**:

    get_cost_series      "Fetch the daily Azure spend series … The five cost centers are
                          'Propulsion', 'Avionics' … for whole-history aggregates query the
                          cost_daily table with query_lakehouse_sql instead."
    query_lakehouse_sql  "Use this for … daily cloud spend …"

Every clause there is false in cloud mode. `cost_daily` is the fictional ledger; cloud-mode cost
centres are `costCenter` **tag** values, not "Propulsion"; and the recommended fallback is the
exact wrong answer. **The agent followed its instructions precisely.** Blaming the model for a
contract we wrote is the comfortable reading and it would have sent the fix to the wrong place.

**This is the `strftime` defect again** - a description written for one backend and shipped with
another. That one told the agent to write `strftime('%w', actual_date)` against T-SQL, which has
no such function; it was fixed by generating the description from the active backend's declared
dialect. Same fix here: `CostSeriesBackend` now declares its `source`
(`lakehouse-ledger` | `azure-cost-management`) and `get_cost_series`'s description is **built,
not written**, so it cannot promise Azure spend while reading a synthetic ledger, cannot
advertise cost centres that exist only in the other mode, and states the non-substitution rule
in the direction that applies. `query_lakehouse_sql` no longer offers itself for "daily cloud
spend", and the schema listing labels `cost_daily` as the business ledger where a model actually
reads column names.

The agent instructions gained the rule too - **one dataset never stands in for another** - made
in the solution rather than the portal, because the next import reverts a portal edit (F131), and
version-bumped to 1.0.3.0, because the import is idempotent on version rather than content
(F130). Currency now presents to two decimals: `$23,561,191.14999999` was floating-point residue,
not precision the data has.

**Eleven tests, and the eval suite still passes 10/10.** The 429 remains external and correct
to report - what changed is that being unable to answer is now the answer.

### F136 — the Functions host owns the preflight *(fixed 2026-09-02)*

"Failed to fetch", with DevTools showing:

    me      200          fetch       <- /.auth/me works; the token store is fine
    token   CORS error   fetch
    token   204          preflight   <- 204 with no CORS headers

A POST **without** the `Authorization` header returned `Access-Control-Allow-Origin`
correctly, so the function's own CORS handling was never broken. Forwarding the caller's
token added an `Authorization` header, which makes the request **preflighted for the first
time** — and the Functions host answers `OPTIONS` *itself*, before any function code runs.
With no platform CORS list it replied 204 with no headers, while the function's own correct
allow-list sat one layer below, never consulted.

**CORS worked for every request except the one the browser had to ask permission for first.**

The old comment — *"configuring the platform CORS list as well would give two places to be
wrong and one of them silent"* — was right when written, and held for exactly as long as
every request was **simple**. Both layers now read the same derived origin: the platform for
the preflight it owns, the function for the response it owns.

### F135 — the token store was off, so /.auth/me had no token to forward *(fixed 2026-09-02)*

The Ask tab reported, against a correctly signed-in user: *"Could not read this session's
Entra token from /.auth/me."* `login.tokenStore.enabled` was **false**, and Container Apps has
no built-in store — without one `/.auth/me` returns **claims and no raw token**.

**The verification was shipped without checking that the token it verifies could be
obtained.** The Function-side work was careful — real key pairs, twelve negative cases — and
none of it tested the browser's ability to get a token at all.

**The design had already named this condition.** The block read *"No downstream API is ever
called on the signed-in user's behalf, so no provider token is worth persisting"* — true of
three static dashboards, and false the moment the Ask tab began calling the directline-token
Function on the signed-in user's behalf. Enabling the store is that premise being met, not an
override of it. Still no client secret: the store persists the id_token issued at sign-in, and
the blob path authenticates with a managed identity.

Infrastructure: a user-assigned identity for the control tower (**it had none**), one
Standard_LRS account with one private container, shared-key access disabled, and Storage Blob
Data Contributor scoped to that account.

**`workload-rbac.Tests.ps1` failed on the fourth role GUID** — this layer's documented set was
read-only and Easy Auth writes. That is the check working: a new role appearing silently is
either an undocumented grant or an escalation. It is now argued for where it is defined, and
the test's name no longer claims *read-only*, because a name that lied would be the failure
that suite exists to prevent.

### F134 — mcp-tools had no Fabric role at all *(fixed 2026-09-02)*

With the tool server finally in cloud mode, the agent issued a real lakehouse query and got:

    "The data source returned: 'Could not login because the authentication failed.'"

`infra/fabric/provision-workspace.ps1` grants workspace roles **per principal** — `data-api`
and `mls-verifier` as Viewer, `cost-ingest` as Contributor — and there was **no entry for
`mcp-tools`**. Its identity held no role on the workspace whatsoever.

**Why it stayed hidden for the life of the project:** mcp-tools ran in local backend mode
(F133), so it never asked Fabric for anything and the missing grant cost nothing observable.
F133 turned a dormant gap into a live failure — and the failure surfaced **inside a Copilot
answer**, three systems away from the file that decides workspace roles, phrased as
*authentication* when it was *authorisation*.

Granted Viewer, matching the other readers, in the existing F24 pass rather than a step of its
own: both identities live in `RG_APPS`, both take the identical role, and that step already
holds the Fabric token. An absent mcp-tools identity now emits a **warning naming the exact
error it would otherwise produce**.

### F133 — the MCP server read data/generated, so the agent worked and answered nothing *(fixed 2026-09-02)*

The Copilot chain reached end-to-end for the first time, and the answer was:

    "I couldn't determine which day of the week has the most launches because the
     launch-history query failed. The lakehouse tool returned: 'Generated data not
     found at /repo/data/generated.'"

`mls-mcp-demo-ca` shipped with `MLS_TOOL_BACKENDS=local`, reading a directory that is not in
the image, while the lakehouse it should query holds 1,200 rows. **Section D's exact shape:
every layer working and the answer empty.**

`data-api` has read the lakehouse correctly all along **from the same template**, deriving its
mode from whether L5 handed over a Fabric SQL endpoint. mcp-tools did not, for a reason that
reads well and was wrong: its parameter defaulted to the literal `'local'` so the mode would
always be *"an explicit deployment decision rather than an omission"* (F2). **That made
explicit-local and nobody-said indistinguishable**, so the template could not derive — and the
omission it was guarding against arrived anyway, wearing the default as a disguise.

Empty now means derive; an explicit value still wins. L7 prints the resolved mode and warns
when it is not cloud — the treatment data-api already had, and whose absence is why nobody
noticed.

### F131 — the committed solution carried the settings that break Direct Line *(fixed 2026-09-01)*

**Caused by me, and the finding is bigger than the mistake.** The agent had been fixed by
hand — Settings → Security → Authentication → "No authentication" — and published. Re-importing
the solution to fix F129's connector host **silently reverted it**, because the committed
`bot.xml` carried:

    <authenticationmode>2</authenticationmode>       "Authenticate with Microsoft"
    <authenticationtrigger>1</authenticationtrigger>  require users to sign in

The next publish made that live and the agent went straight back to
`IntegratedAuthenticationNotSupportedInChannel`, costing a full round trip.

**`agent-definition.md` §7.1 was wrong about this, and the wrongness is the danger.** It said
*"after a solution import the auth settings are blank and must be reconfigured by hand"*. They
are not blank — they are **restored from the solution**, which is worse: reconfiguring by hand
produces a working agent that the next import quietly undoes, and nothing reports it. In a
repository whose claim is *the repo is the product*, the repo was carrying a configuration that
cannot work on the channel this demo uses.

**The enum is now OBSERVED rather than guessed**, which is what makes editing it legitimate
where this register earlier said it would not be: with the UI showing "No authentication",
Dataverse read `authenticationmode 1`; the committed `2` reproduced the channel error. So
1 = No authentication, 2 = Authenticate with Microsoft — measured, not remembered.

Fixed in the source: mode `2 → 1`, trigger `1 → 0`, and the tool's
`connectionProperties.mode` from `Invoker` to `Maker` — end-user credentials being the other
half of the contradiction, since an agent that authenticates nobody has no end user to run a
tool as. All three now survive an import.

### F130 — a green import that deployed nothing, because the check is version-keyed *(fixed 2026-09-01)*

The first L8 re-import after F129's fix reported `import the Copilot Studio solution = success`
and changed nothing. `import-agent.ps1` is idempotent on the solution **VERSION** — it compares
the online version with the committed source and skips when they match — and the fix changed
*content* (the connector host) without changing the version. Dataverse still read the dead host
after a green run.

The version is a **proxy** for "has the content changed", and it failed in exactly that way —
the estate's own recurring shape, this time in the deploy path rather than a verification. A
version bump is the honest remedy rather than `-Force`, because the content really did change.

**What did NOT catch it:** V8.1 compares the deployed component list against the committed one,
and it is red for an unrelated reason (16 platform-generated topics). A real content drift
arrived while the criterion that would have named it was already failing for something else — a
red check is not a working check.

### F132 — L8 has not genuinely deployed in a long time *(fixed 2026-09-02)*

Every L8 run on 2026-09-01 failed, and the ones whose import job read `success` had **skipped**
(F130). The first run that actually packed produced:

    Error: Solution package type did not match requested type.
    Pack 'MeridianLaunchCopilot' as Managed failed

`layer-08-copilot-studio.yml` defaults `deploy_as_managed: true`, but the committed source is
`<Managed>0</Managed>` and the installed solution reports `ismanaged: False`. So the default has
never been satisfiable, and every import either skipped or failed. It only succeeded once
dispatched with `deploy_as_managed=false`.

**The decision, taken 2026-09-02: the default changes to match the artifact.** Microsoft's
"deploy managed" guidance assumes a **separate authoring environment**. This demo has ONE Power
Platform environment, which is both the maker environment and the deployment target, so unmanaged
source is correct and the managed default was the misconfiguration. Deploying managed would need
a managed export from a second environment - a change to the ALM topology, not a flag, and not
one a $0 developer plan supports.

Three changes, because a flag flip alone would leave the trap armed:

- The default is `false`, **in both trigger declarations** - F132 survived in both copies, so a
  check reading only the first would have passed.
- `import-agent.ps1` asserts the requested package type against the committed `Solution.xml` **in
  preflight, before any tenant write**, and names which way to resolve the disagreement. This is
  the "constant that names something in another system" rule pointed inward: the other system is
  the solution tree, and it is right there to read.
- `verification/tests/failure-classes.Tests.ps1` encodes the class. Mutation-tested: restoring
  `default: true` fails it in **31 ms**, against a full L8 run to learn the same thing.

The unmanaged-import `::warning` is gone. It fired on the correct path, and a warning that is
right by default trains people to ignore warnings.

### F129 — the copilot connector points at an environment that no longer exists *(fixed 2026-09-01)*

Chasing F128's `AuthenticationNotConfigured` into the tool's own panel produced the real
cause, and it is not an auth problem at all:

    Connector request failed
    "The remote name could not be resolved:
     'mls-mcp-demo-ca.thankfulisland-7f9b1aba.centralus.azurecontainerapps.io'"

The live server is `mls-mcp-demo-ca.**happymeadow-9e15a087**.centralus.azurecontainerapps.io`.
The committed connector definition hardcoded the old one:

    "host":"mls-mcp-demo-ca.thankfulisland-7f9b1aba.centralus.azurecontainerapps.io"

**`thankfulisland-7f9b1aba` is a Container Apps environment that no longer exists.** Azure
assigns that domain segment randomly, once per environment, and a teardown/rebuild gets a new
one. So the literal was **guaranteed to be wrong after the very kill-and-rebuild this demo
exists to showcase** — and it broke the copilot silently, surfacing three layers away as
"Connector request failed" with nothing anywhere naming a hostname.

**This is F90's class exactly**: a name from another system, written into a committed
artifact, surviving the change it should have tracked. F90 was 22 Entra names surviving a
rebrand; the answer there was to tokenise `infra/entra/manifest.json` with `${prefix}`/`${env}`
and resolve it in the one place that reads it. Same answer here.

**Fixed** in three parts:

- The connector definition keeps **`"host":"${mcpHost}"`** — no environment-shaped literal in
  the repository.
- `import-agent.ps1` resolves the live FQDN (`-McpHost`, `MLS_MCP_HOST`, or an `az` lookup),
  copies the source to a staging tree, substitutes, and packs **from the copy** — so the
  package carries real values and the repo keeps the token. It **fails loudly** when it cannot
  resolve one, rather than importing a connector aimed at a dead host.
- `verification/tests/failure-classes.Tests.ps1` rejects any deployable artifact containing a
  Container Apps environment domain. Mutation-tested. Scoped deliberately: documentation
  quoting a live FQDN as evidence is honest; **configuration** carrying a random segment
  nothing regenerates is not.

**A red herring worth recording, because it is a real demo risk on its own.** The MCP server
runs at `minReplicas: 0` for the $0-idle guarantee and takes **26 seconds** to cold-start, which
also produces "Connector request failed" when Copilot Studio's connector times out first. That
was the first hypothesis and it was wrong here — but it will bite the **first question of any
live demo**. Holding one replica warm costs **~$14.04 / 30 days (0.25 vCPU, 0.5 GiB, after the
free grant)** and is a **G2 decision**, deliberately left to the sponsor.

### F128 — the Ask tab connects, and the agent refuses on an auth mode it cannot use *(2026-09-01)*

**The entire chain works.** Opened by a signed-in human, the Ask tab minted a token,
connected Direct Line, created conversation `7BwKu2KdUX8BKPJKFrcsIk-us`, sent *"Which day of
the week has the most launches"* — and the agent replied:

    Sorry, something unexpected happened. Error code:
    IntegratedAuthenticationNotSupportedInChannel

Every link F122 and F124 fixed is confirmed by this: the secret resolves, the Function mints
tokens, the bundle carries the endpoint, Web Chat initialises, and the agent is reachable and
answering. **What fails is one setting on the agent itself.**

**Confirmed from our own committed artifact, not from the error text.**
`infra/copilot-studio/solution/.../bots/mls_MeridianLaunchCopilot/bot.xml` carries
`<authenticationmode>2</authenticationmode>` — "Authenticate with Microsoft" (integrated),
which Direct Line does not support. `agent-definition.md` §7.1 already flagged this on
2026-08-31: *"Current state is NOT this. `settings.mcs.yml` reads
`authenticationMode: Integrated` — that is 'Authenticate with Microsoft', the option this
section rejects."* It was a known deviation waiting for a channel to prove it.

**The design's own fix is the wrong one here, and §3 says why.** §7.1 prescribes
*Authenticate manually* with Entra ID V2, which needs the `mls-copilot-auth` and
`mls-copilot-canvas` registrations — **neither declared in `infra/entra/manifest.json`**
(F106), so neither will ever exist. But that whole requirement descends from §3.3, whose
purpose is to obtain a `User.AccessToken` for the **connected Fabric data agent** — and §3
opens by stating that path is the **paid-F2 upgrade**, G2-gated, explicitly not the default:

> *"Fabric data agents require a paid F2+ capacity… During the trial phase this agent runs
> **tools-only via MCP**, answering lakehouse questions through the MCP server against the
> SQL analytics endpoint."*

The MCP server authenticates with **its own API key** (`mcp-auth-token`, Key Vault). No user
token is involved in the data path that is actually deployed. So **"No authentication" is not
a compromise for this configuration — it is the correct setting**, and it sidesteps F106
entirely. If the estate ever moves to paid F2 and attaches the Fabric data agent, §7.1's
manual mode becomes necessary again *and* F106 must be closed first.

**AND THE AUTH MODE WAS ONLY HALF OF IT.** With "No authentication" saved and published -
Copilot Studio's own Agent status confirms it: *"Anyone can view this agent's content because
it doesn't require users to sign in"*, state **Draft, Published** - the agent still answered
`AuthenticationNotConfigured`. The remaining half is the tool, read live from Dataverse:

    component: Meridian Ops Tools
    connectionProperties:
      mode: Invoker

**`Invoker` means the MCP connection runs as the INVOKING USER.** With no authentication
there is no invoking user, so the connection cannot be established. The two settings
contradicted each other, and fixing one without the other just moved the error.

This is §3.3's *"User authentication or Agent author authentication"* choice, and the same
reasoning applies as to the auth mode: user authentication exists so Fabric can enforce
per-user permissions on the **connected Fabric data agent**. On the deployed path there is no
Fabric data agent - the MCP server answers everyone with **one API key** - so running the
connection as the invoker buys no segregation and costs the whole feature. **Agent author /
Maker mode is correct here**, for exactly the reason "No authentication" is.

Both revert together the day the estate moves to paid F2 and attaches the Fabric data agent,
and F106 must be closed before either can.

**The change is a human one, and deliberately not automated.** Auth settings are blank after
a solution import (§6) and take effect only on publish, both of which are Copilot Studio UI
steps:

    Copilot Studio -> the agent -> Settings -> Security -> Authentication
      -> "No authentication"  -> Save                                   [done]
    Copilot Studio -> Tools -> "Meridian Ops Tools" -> connection
      -> run as AGENT AUTHOR (Maker), not the invoking user             [required]
    -> Publish

Afterwards run `infra/copilot-studio/export-agent.ps1` so the committed solution captures the
real value rather than anyone guessing the option-set integer — the repo's own round-trip,
and the reason not to hand-edit `bot.xml` to a number nobody has verified.

### F127 — V7.7 measured Microsoft's login page and blamed our app *(fixed 2026-09-01)*

With F104 fixed, L7 ran to completion for the first time and reached **6/7** — V7.5 and
V7.6 passing on their first-ever evaluation. V7.7 failed:

    launch-ops    /.auth/me answered 200 with no x-ms-middleware-request-id
    control-tower /.auth/me answered 200 with no x-ms-middleware-request-id
    - Easy Auth is not handling /.auth, so the sign-in callback has nowhere to land

**Easy Auth was handling it perfectly.** `curl` against the same URLs returns **401 with the
header present**, and all three container apps carry identical, correct auth config.
Reproduced the discrepancy directly:

    maxRedirect=-1 (default)  ->  HTTP 200, middleware header ABSENT
    maxRedirect=0             ->  HTTP 302, middleware header PRESENT

The probe followed the redirect. `/.auth/me` answers **302 to the Entra sign-in page**, and
the criterion dutifully followed it and reported **`login.microsoftonline.com`'s 200** as our
container's answer. It was measuring Microsoft's login page and attributing the result to our
app. Both frontends failed a control that works.

This is the **same trap that bit V12.4 hours earlier** — the reason `-MaximumRedirection`
was added to `Invoke-MlsHttp` in the first place. V7.7 predates it and never adopted it.

**Fixed** with `-MaximumRedirection 0`, and the assertion widened from `401` to *any refusal
carrying the middleware header* — because **Easy Auth picks its refusal by the caller**: 302
to PowerShell, 401 to curl, same app, same minute. Pinning 401 fails a working control on the
User-Agent of whoever ran the audit. A **2xx still fails**, which is the SPA-fallback state
the criterion was written for (F110).

**Confirmed against the live estate 2026-09-01**: a filtered re-run
(`only_criterion: V7.7`) reports **PASS** in **4 minutes** rather than the ~55 a full L7
costs, because V7.5 alone waits up to 30 for scale-in. The run exits 3 - `DIAGNOSTIC -
filtered run; no verdict, and no layer can be signed off from it` - which is correct and is
why the job shows red. **L7's verdict is therefore still 6/7 on the record.** The evidence
for 7/7 is strong but spans two runs: a full run that reached 6/7 with V7.7 failing on this
bug, plus a filtered run showing V7.7 now passes. A single unfiltered run is what would make
it a sign-off, and it has not been paid for yet.

**A note on the test, because it is the more useful lesson.** The first version of the
regression test *passed with the defect reintroduced* — a mirror, not a test. It captured the
probe's argument into a `$script:` variable that did not survive Pester's scoping, so the
assertion compared `$null` and never fired. Only the mutation run exposed it. It now uses
`Should -Invoke -ParameterFilter`, asserts that **no** `/.auth/me` probe follows redirects,
and separately asserts the probe ran at all so the first assertion cannot be vacuous.

### F126 — the self-heal notice named a remedy that was already done *(fixed 2026-09-01)*

`SELF_HEAL_TOKEN` was re-scoped to a repository secret and **the chain immediately started
working**: the selector reads the alert surface, **V10.3 PASSES**, and the Dependabot lane
runs instead of skipping. It then stopped on this:

    notice: No Dependabot PR to gauntlet
    ... so this path needs 'Dependabot security updates' switched ON in repository settings.

**The setting was already on.** `gh api repos/.../automated-security-fixes` →
`{"enabled":true,"paused":false}`. A confident, specific, *wrong* remedy is worse than no
remedy: it sends the reader to change something already correct and stops them looking.

**The real cause**, established by elimination rather than asserted:

| Checked | Result |
|---|---|
| `automated-security-fixes` | **enabled, not paused** — not the cause |
| Alerts have patched versions | all four do (`minimist` 1.2.6, `semver` 7.5.2, `json5` 2.2.2, `esbuild` 0.28.1) |
| Ignore conditions | Dependabot: *"No dependency name (minimist) or ignore conditions found to unignore"* — **none exist** |
| Lingering `dependabot/**` branch | only PR #102's; the vuln-lab ones are gone |
| Prior security PRs | **#30, #35, #36 opened 2026-08-28 and closed unmerged 2026-08-29 04:45**, all in one minute |

**Dependabot does not reopen a security PR that was closed unmerged, and records no ignore
condition when it happens** — so the alert stays open forever with no PR and nothing
anywhere explains why. `@dependabot reopen` does not bring it back either.

**A full heal-and-re-arm cycle was run, and it did NOT fix it.** PR #148 bumped the three
pins to their patched versions (all three alerts went to `fixed`); PR #149 ran
`apps/vuln-lab/reseed.ps1` to restore the vulnerable pins. The advisories came back — but
**GitHub REOPENED alerts #2, #3 and #4, with their original `created_at` of
2026-08-28T23:52, rather than creating new ones.** The premise the cycle rested on ("a newly
raised alert carries no association with a closed pull request") therefore never applied:
they are the same alerts. Ten minutes after the re-arm, still no Dependabot security PR.

**So the cause is still not established, and this entry does not pretend otherwise.** What
is now ruled out: the repo setting, missing patched versions, ignore conditions, lingering
branches, and a stale alert state.

**`open-pull-requests-limit: 0` is ALSO ruled out, and the evidence was in the repo the
whole time.** That was named here as the leading candidate; it is wrong. PRs #30, #35 and
#36 were security-update PRs *for `/apps/vuln-lab`*, opened 2026-08-28 — **while that
directory already had `open-pull-requests-limit: 0`**. The limit demonstrably did not stop
them, so `dependabot.yml`'s comment on the subject is correct after all. Anyone tempted to
test it by raising the limit would be disarming the seed for nothing.

**`esbuild` (#5) looks like a counter-example and is not.** It sits in the ROOT manifest,
where the limit is 5, and has never had a PR either — but it is a **transitive dev
dependency**, so there is no direct pin for Dependabot to bump and no fix it can author. Its
silence is expected and says nothing about the three seeded CVEs, which are direct
dependencies.

That leaves the closed-unmerged history of #30/#35/#36 as the only explanation still
standing, and the reopened-alert cycle showed it survives a fixed/open transition. **The next
useful observation is free:** Dependabot re-evaluates on its own weekly schedule (Monday
06:00 per `dependabot.yml`), so a scheduled pass may open the PRs without anyone doing
anything. Sponsor decision 2026-09-01: **wait for that rather than spend more on it** — there
is a month of runway and nothing else depends on it.

The cycle was not wasted: it proved the lab's heal/re-arm machinery works end to end, and
`reseed.ps1` verified its own output (3 advisories present, 2 code flaws restored).

**Fixed** by replacing the single asserted remedy with three candidate causes in order,
each with the command that tests it, and an explicit note that the first one being already
on means *it is not your cause*.

### F125 — a job-level `if:` cannot see environment variables, so two verify jobs never ran *(fixed 2026-09-01)*

Found by dispatching `compliance.yml` to prove L12's new audit runs in CI rather than only
locally. It did not run: `verify L12 (mls-verifier) = skipped`. **The guard I had just
written was the cause**, which is the point — this class is easy to write and impossible to
see.

    verify:
      environment: verify
      if: ${{ ... && vars.AZURE_VERIFIER_CLIENT_ID != '' && ... }}

**A job-level `if:` is evaluated BEFORE the job's environment is resolved.** So `vars.` is
the empty string there even though the job declares `environment: verify` and the variable
is set on it. This repository has **zero repository-level variables** — every one lives in
`demo` or `verify` — so any `vars.` in a job-level `if:` is unconditionally empty, and a
guard meaning *"skip when no verifier is configured"* actually means **"skip always"**.

`layer-05-fabric.yml` has an identical-looking guard that has always worked, because it is
**step-level**, where the environment has resolved. Same expression, different line,
opposite behaviour.

**What it cost:** `self-heal.yml`'s `verify` job **has never been able to run.** That
compounds BLOCKER-4 exactly — even with a readable alert surface and a healed alert, the
audit that judges the chain would still have skipped. Nobody noticed, because **a skipped
job is green**.

**Fixed** by moving the guard to a step inside each job, where `vars.` resolves. The
behaviour it was written for is preserved and now actually works: a stranger cloning this
repo without an `mls-verifier` identity gets a clear `::notice` saying the layer is
*unverified, which is not the same as broken*, rather than a red run.

`verification/tests/failure-classes.Tests.ps1` now fails any `vars.*` reference in a
job-level `if:` — mutation-tested: with the defect reintroduced it names
`compliance.yml::verify gates on vars.AZURE_VERIFIER_CLIENT_ID`.

**This is the fourth instance of one shape in a single session** (F122, F123, F124, F125):
*a value that exists, is spelled correctly, and is invisible to the thing that reads it* —
failing silently and green every time.

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

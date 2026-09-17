# Demo readiness — what is verified, what is broken, and what the audits cannot see

**The live state of the estate, and the only file here that claims to be current.** Every
verdict below came from a run against the deployed estate. Where something has not been
re-verified, this file says so rather than reusing an older verdict — a verdict recorded at
one moment and carried forward after the system changed underneath it is the single most
common defect this project has recorded.

A layer is done when the independent auditor says so, not when a deploy exits zero. Read
the criterion tables, not the job status.

**Refreshed 2026-09-17, ~01:30 UTC.** The previous refresh was the morning of 2026-09-16 and
was overtaken within hours: the estate reached a **second cloud** that day. Everything below
was re-measured for this pass or is explicitly marked as not re-measured — there is a
**freshness** column and it is the most important one on the page. What was checked, and
how: live Azure via `az`, GitHub workflow runs and their logs and artifacts via `gh`,
`compliance/state/` and the git log on disk. What was *not* checked is named rather than
assumed.

> **One caveat on provenance, stated because this file's whole value is provenance.** The
> live Azure reads in the estate table below were made from an ambient `admin@` Azure CLI
> context, **not** as `mls-verifier`. That is a *wider* credential, so those reads may see
> what an audit would not: treat them as evidence the resources exist, never as evidence
> that the Verifier identity can see them. Every criterion verdict in this file comes from a
> real audit job running as `mls-verifier` in CI, and each one carries its run id.

The history — every defect found while building this, in order, including the diagnoses
that turned out to be wrong — is a dated archive:
**[2026-08-22 → 09-03](findings/2026-09-03-finding-register.md)**,
**[2026-09-04](findings/2026-09-04-finding-register.md)** (F190–F200) and
**[2026-09-16 / 09-17](findings/2026-09-16-finding-register.md)** (F201–F217, the
cross-cloud day). Nothing was removed from any of them.

---

## THE SCORECARD

*Standing section. Update it when a status changes; do not let it drift. A new agent, or a
conversation that has been compacted, should be able to read only this and the blocker tree
below and know what to do next.*

`docs/BRIEF.md` commits to **four showpieces** and **twelve layers**. There is now a fifth
capability the brief never described — a **cross-cloud lakehouse link** — and it has its own
section below.

### THE DEADLINE — the estate shuts down around 2026-09-27

**This is the thing that orders all other work, so it goes first.** The subscription and
trials behind this estate expire and the estate is scheduled for teardown **around
2026-09-27**: roughly **ten days** from this refresh. A teardown and rebuild is expected
before then.

What that changes about priority:

| | |
|---|---|
| **Capture evidence while the estate is up** | Screenshots, real rows, rendered dashboards. After shutdown these are unobtainable. The outbrief's *prose* can be written afterwards; its *screenshots* cannot |
| **Turn observations into properties** | Several things pass **once**, against an estate never torn down since they existed — V8.6, V8.7, and the whole AWS link. A rebuild is the only thing that converts them, and there is one rebuild left |
| **Chase the phase-3 gaps that still have time** | **V6.2's fix has never once executed**; V9.5; V11.3–V11.5 have never reported at all |
| **Instrument the final teardown** | The last teardown is itself evidence — the claim the repository exists to make. Run it as a measured demonstration, not as cleanup |

**Four objects survive the teardown deliberately and need their own line items**, because
`infra-down.yml` deletes four resource groups by name and none of these is inside them:

1. **`mls-rg-identity`** — holds `mls-aws-demo-id`, the managed identity the AWS trust chain
   federates from. Placed outside the blast radius on purpose, so the AWS trust policy's
   `sub` condition survives a rebuild.
2. **The AWS IAM role** `launch-intel-athena-reader`, in the sponsor's account.
3. **and 4. Both AWS OIDC identity providers** (the `sts.windows.net` and
   `login.microsoftonline.com` ones). These are newly named here: `./.aws-anchor.env`
   records **`MLS_AWS_PROVIDER_V1_PREEXISTED=true`** and `_V2_PREEXISTED=true`, so
   `01-oidc-provider.sh` *adopted* rather than created them — and `scripts/aws/teardown.sh`
   deliberately deletes a provider only when its `_PREEXISTED` flag is the literal string
   `false`. **The teardown will remove the role and leave both providers standing.** That
   default is right (a provider this setup did not create may be load-bearing elsewhere),
   which is exactly why it needs a deliberate decision rather than a discovery.

### The live estate, read 2026-09-17

Read directly from Azure. Credential caveat above applies.

| | |
|---|---|
| Resource groups | **5** — `mls-rg-apps`, `mls-rg-data`, `mls-rg-ops`, `mls-rg-platform` (the four the teardown deletes) plus **`mls-rg-identity`**, deliberately outside the blast radius |
| Resources in the teardown blast radius | **30** — apps 10, ops 9, platform 8, data 3. The same 30 the 2026-09-03 rebuild produced |
| Resources outside it | **1** — `mls-aws-demo-id`, the user-assigned identity the AWS trust chain federates from |
| Container apps | **6 / 6** `Running` / `Succeeded` — compliance, control-tower, data-api, launch-ops, mcp, vuln-lab |
| Region | `centralus`, all five groups |
| Uptime | L7 redeployed **twice on 2026-09-16** (21:12Z and 23:01Z) after thirteen untouched days; L2/L5/L6 unchanged since the 2026-09-03 rebuild |

**The gap this table carried yesterday is CLOSED.** `mls-mcp-demo-ca` now lists **both**
`mls-mcp-demo-id` and `mls-aws-demo-id`; the AWS identity wiring in
`infra/bicep/apps/main.bicep` was deployed by L7 run `35151079462`. Verified 2026-09-17 by
reading the container app's `identity` block directly.

**A new one opened in its place, and it is F203.** The estate's image tags are now **mixed**:

| app | running image | deployed by |
|---|---|---|
| `mls-compliance-demo-ca` | `compliance:sha-c1b7c91` | its own app CI |
| `mls-control-tower-demo-ca` | `control-tower:sha-7945931` | its own app CI |
| `mls-mcp-demo-ca` · `mls-data-api-demo-ca` · `mls-launch-ops-demo-ca` | **`:latest`** | `layer-07-apps` |

`layer-07-apps.yml` declares `image_tag` with `default: latest`, so an L7 deploy replaces
the `sha-` tag app CI wrote. **That erased the commit provenance V10.2 reads, and turned
showpiece #3 red four hours later.** See the blocker tree.

### The teardown-and-rebuild, measured 2026-09-03

This is the claim the repository exists to make, so it keeps its place. **These figures are
from 2026-09-03 and have not been re-measured** — there has been no teardown since. They are
history, not current state, and the next teardown is the one before the 2026-09-27 shutdown.

| | |
|---|---|
| Teardowns | **clean, ~14 minutes each** — identical both times. All stages green |
| Rebuild wall clock | **87 minutes** for the full ordered run |
| Deploy work inside that | **~30 minutes** |
| Verification inside that | **~84 minutes** |
| Resources before / after | **30 / 30 / 30** across both cycles — reproduced exactly each time |
| Container apps | **6 / 6**, same names and ingress shape |
| ACA domain suffix | regenerates every rebuild, so no stored FQDN survives (F129's class) |
| Log Analytics workspace | **three distinct identities across three builds** — `5c967cf4` → `87f95e84` → `e26c9dcb`. F107's purge holding across repeated cycles rather than once |
| Managed identities | **all recreated with new principal ids**. This is the condition F172 exists for, and the reason cycle 2 was worth running |

**The estate deploys in half an hour and takes three times that to verify.**
`docs/runbooks/kill-rebuild.md` § 5 budgets "~8–10 min" for the audits and attributes the
wall clock to the deploys; measured, that is inverted. The `<60-minute` claim in § 5 was not
met on 2026-09-03 and the margin is eaten by audit retry windows, which that section's model
does not represent at all. **Whether it is met now is unknown.** One new data point, not a
re-measurement: L7's audit on 2026-09-17 took **93 minutes**, and that is V7.5's scale-in
wait rather than a hang.

### The four showpieces

| # | Showpiece | Status | Freshness | Evidence |
|---|---|---|---|---|
| **1** | **Copilot service** — Ask tab over Direct Line | ✅ **working, and it now answers from two clouds and says which is which** | **current — 2026-09-17 00:37 UTC** | **The eval grades, for the first time in this project's life: 9 / 10, bar 9, `unobservable: 0`**, over Direct Line against the deployed agent (`layer-08-copilot-studio` run `35166952968`, path `mcp-tools-only`). For a fortnight it returned 0/10 with zero tool calls. Asked *"how many rows are in the launches table"* the agent answers **both** lakehouses unprompted — **1,200** (Meridian, synthetic) and **286,473** (AWS, real launch-industry data) — *"because the question is ambiguous"*. **Two cautions carried deliberately:** this is the **eval's artifact, not a V8.2 verdict** (V8.1–V8.5 all reported `(not selected)` in that run, which was filtered for V8.6/V8.7); and the same artifact records **p95 34.18 s against V8.5's 20 s budget**, driven by an un-warmed first question. See F216 |
| **2** | **Control tower** — Dev/Sec/Ops on Well-Architected pillars | ✅ **7 of 7, on the revision carrying the AWS link** | **current — 2026-09-17 00:38 UTC** | **V7.1–V7.7 all PASS**, `layer-07-apps` run `35160458879`, verify job as `mls-verifier`. Including **V7.6 — the data API answers with rows, not merely a status code**, the criterion that exists because an empty estate once signed off 5/5. **V7.6 is the FABRIC-backed data API. No L7 criterion touches the AWS link at all** — a green 7/7 sitting beside tonight's 286,473 rows is *two independent facts that look like one*, and reading them as one re-creates § D's failure one tool over |
| **3** | **Self-healing code** | ❌ **V10.2 FAILED tonight, after twelve consecutive green runs** | **current — 2026-09-17 00:58 UTC** | `self-heal` run `35168595017`: **V10.1 PASS · V10.2 FAIL · V10.3 PASS · V10.4 PASS**. One unexplained closure: `#9 code-scanning js/trivial-conditional fixed but mls-mcp-demo-ca: could not establish whether the running image carries this heal — the running image carries no sha- tag`. **The criterion is behaving correctly; the estate changed underneath it.** An L7 deploy retagged the app to `:latest` and erased the commit binding F197's fix reads. This is **F203**, it is not a regression in the heal chain, and the chain itself ran: the Dependabot lane's gauntlet job succeeded in the same run |
| **4** | **Compliance platform** — NIST 800-171 | 🟡 **the platform works and its history is real; the content is still thin** | **current — 2026-09-17 00:52 UTC** | **V12.1, V12.2, V12.4, V12.6 PASS; V12.3 and V12.5 SKIP**, from `compliance` run `35168252498`. `compliance/state/` holds **fifteen dated snapshots** in an unbroken daily run 2026-09-05 → 2026-09-17, all committed to `main`; `state-latest.json` collected `2026-09-17T00:51:54Z` at commit `7945931`. **The figures have not moved and that is the honest part**: 110 requirements, **0 COMPLIANT**, 15 PARTIAL, 1 GAP, 94 NOT_ASSESSED; provenance **0 machine-verified**, 16 asserted, 94 none. The freshness problem is fixed. The coverage problem is not, and was never the same problem |

### The twelve layers

**Current verdicts — measured within the last 24 hours:**

| Layer | Status | Measured | Note |
|---|---|---|---|
| L3 Entra | ✅ **4 of 4 PASS** | **2026-09-16 20:32**, run `35147161355` | V3.1 object counts · V3.2 group memberships · V3.3 CA policy state, *and the enforced policy really enforces MFA* · V3.4 licensing 5 of 5. Re-run because the AWS workstream added a fifth app registration |
| L7 apps | ✅ **7 of 7 PASS** | **2026-09-17 00:38**, run `35160458879` | V7.1–V7.7, on the revision that carries the AWS link. **No L7 criterion touches AWS** |
| L8 Copilot Studio | 🟡 **V8.6 + V8.7 PASS; V8.1–V8.5 have no verdict** | **2026-09-17 00:38**, run `35166952968` | The first time L8 has ever asserted that the AWS lakehouse **answers**. V8.1–V8.5 reported `(not selected)` — a filtered run, deliberately exiting 3 so nothing downstream reads a diagnostic as a sign-off, which is why the job shows a red X |
| L10 self-healing | ❌ **3 PASS, 1 FAIL** | **2026-09-17 00:58**, run `35168595017` | V10.2 fails on one unexplained closure. Cause is F203, outside L10 |
| L12 compliance | ✅ **4 PASS + 2 SKIP** | **2026-09-17 00:52**, run `35168252498` | V12.1/2/4/6 PASS, V12.3 and V12.5 SKIP. Runs nightly at 02:17 UTC and on every push to `main` |

**Verified on the rebuilt estate 2026-09-03/04, and NOT re-audited since.** These are real
verdicts against a real deploy — and they are thirteen to fourteen days old. Treat them as
*last known good*, not as current.

| Layer | Last known | Measured | Note |
|---|---|---|---|
| L1 repo / IaC / OIDC | ✅ green | 2026-09-04, run `33834831053` | `verify-l1` concluded `success`. **Criterion-level verdicts were not re-read for this refresh**, so "green" here means the job, which is exactly the thing this file tells you not to trust. V1.5 (governance mode vs. the live ruleset) is the one worth re-running: `.github/governance-mode.json` still declares `development` |
| L2 landing zone | ✅ verified | 2026-09-03, inside `infra-up` | No standalone `layer-02-landing-zone` run has ever been made; its sign-off happens inside the ordered rebuild |
| L4 Purview labels | ✅ **2 PASS + 1 by-design SKIP** | 2026-09-03, run `33753883078` | `V4.1` the four labels · `V4.2` survival across kill/rebuild, deferred to L11 by design · `V4.3` the label policy publishes the taxonomy. **V4.2 is still unproven by machine.** Nothing has touched Purview since, so this is *likely* still true — *likely* is not verified |
| L5 Fabric | ✅ 4 of 4 | 2026-09-03, inside `infra-up` | First clean sign-off after F104/F105/F114. The last *standalone* `layer-05-fabric` run was 2026-09-01 and it **failed**; do not read that run as current either |
| L6 platform | 🟡 **6 of 8, and V6.2's fix has never executed** | 2026-09-02 / 2026-09-03 | V6.1, V6.5, V6.7, V6.8 PASS; V6.3, V6.4 PENDING by design. **V6.2 is the live unknown — see the blocker tree** |
| L9 DevSecOps chain | 🟡 partial | 2026-09-03, `zap` run `33720917308` | The DAST was re-run on the rebuilt estate and is real: six targets *derived from Azure*, three authenticated, **zero High-risk alerts**. V9.5 remains the gap and needs a Defender toggle round-trip, which is a G2 action. The last standalone `layer-09-devsecops` run was 2026-09-02 and **failed** |
| L11 teardown / rebuild | ✅ V11.1 and V11.2 PASS | 2026-09-03, run `33751531348` | V11.2 — the criterion proving a teardown did not cross the G3 tenant-object line — reported for the first time ever, after three attempts and three distinct causes (F170, F180, and F180's own fix). **V11.3–V11.5 have never reported at all.** The shutdown teardown is the next chance and probably the last |

### The cross-cloud AWS lakehouse link — SHIPPED, 2026-09-16

**Nine of nine plan tasks merged.** A link from the Copilot agent to the sponsor's **real**
AWS Athena lakehouse (`launch-intel`), over **OIDC federation with no stored AWS
credential** — the same trust model the Azure side already uses, extended across a cloud
boundary. Nothing is copied; only result rows cross.

- Spec: [`docs/superpowers/specs/2026-09-16-aws-lakehouse-link-design.md`](superpowers/specs/2026-09-16-aws-lakehouse-link-design.md)
- Plan: [`docs/superpowers/plans/2026-09-16-aws-lakehouse-link.md`](superpowers/plans/2026-09-16-aws-lakehouse-link.md)
- Sponsor runbook: [`scripts/aws/README.md`](../scripts/aws/README.md)
- Findings: [F201–F217](findings/2026-09-16-finding-register.md)

| What it does | Evidence, and when it was observed |
|---|---|
| Answers from AWS | `SELECT COUNT(*) FROM launches` → **286,473 rows in 4,431 ms**, 2026-09-16 ~23:15Z, through the live MCP endpoint. **No redeploy and no hand-patch** — the identical call against the unchanged container revision went from an STS refusal to rows the moment the IAM role landed |
| Distinguishes the two lakehouses | 2026-09-17 00:14Z, through the Ask tab: *"There are two different `launches` tables … Meridian's operations lakehouse (synthetic): **1,200** rows. AWS launch-intelligence lakehouse (real launch-industry data): **286,473** rows. I queried both because the question is ambiguous"* |
| Enumerates a catalog it was not told about | The agent listed all five Glue tables live — `launches`, `launches_latest`, `schedule_events`, `agencies`, `agencies_latest`. Both `VIRTUAL_VIEW`s are visible, which a three-table role would have `AccessDenied`ed (**F204**) |
| Is machine-checked | **V8.6 and V8.7 both PASS**, 2026-09-17 00:38Z, run `35166952968` |
| Stores no AWS credential | A repo sweep asserts it: `failure-classes.Tests.ps1`, *"the AWS lakehouse link stores no credential, anywhere"* |

**Three things about it are easy to misread, and each is a real hazard:**

1. **V7.6 is the Fabric data API, not the AWS link.** L7's 7/7 and the 286,473 rows are two
   independent facts. **No L7 criterion touches AWS.** V8.6 is the only criterion that does.
2. **V8.6 and V8.7 have passed exactly ONCE**, against an estate that has never been torn
   down since they existed. That is an **observation, not a property.** The rebuild is what
   converts it.
3. **V8.6's floors are 100,000 and 1,000** against observed 286,473 and 7,969 — deliberately
   loose, because the lakehouse is the sponsor's and refreshes from an upstream feed, so a
   pinned equality would fail on correct data. The cost, stated plainly: **V8.6 would not
   catch a lakehouse that lost 60 % of its rows.** It catches nothing, a status code, a
   denial, and a view the role cannot read. Exact counts belong to V5.3, over data this repo
   seeds.

**And one dependency that is not yet reproducible.** V8.6/V8.7 need `mcp-auth-token` from
Key Vault. `mls-verifier` holds **Key Vault Secrets User scoped to that one secret** — not
the vault, which also holds the Direct Line secret and data-api's PAT. **That grant is
written in `infra/bicep/apps/modules/key-vault-secret-role.bicep` and has never been
deployed**: the live assignment is the hand-applied one from 2026-09-16, and the last
`layer-07-apps` run (23:01Z) predates the template landing on `main` (00:51Z). Until an L7
deploy applies it, **a teardown erases the grant and both criteria return silently to SKIP.**
F159's class, with a criterion as the casualty.

### The mission itself

*"Fully agent-instantiated … destroyed and rebuilt on demand … the repo is the product."*

**Demonstrated, on 2026-09-03.** The estate was destroyed and rebuilt from a cold dispatch,
in layer order, with independent sign-off at each step, and came back with the same 30
resources — which it still has today. Four fixes that had never been through a teardown were
tested by it and all four survived.

**What the rebuild cost, and this is the honest part.** It failed twice before it passed. It
surfaced eleven findings (F167–F177), of which the three most valuable were not bugs in the
estate but **green checks that were verifying nothing** — L4's audit, V11.2, and a
grant-failure reporter that reported success. A rebuild is the only thing that finds those.

**The claim is fourteen days old, and there is more riding on the next rebuild than there
was on the last.** Everything the cross-cloud day built is unproven against a teardown, and
so are the three L5/L7 fixes from 2026-09-03 and V11.2's own fix. The shutdown teardown is
the last opportunity to prove any of it, and it should be instrumented as evidence rather
than run as cleanup.

---

## THE BLOCKER TREE

*Ordered by how much each unblocks. Entries that no longer describe reality are retired
here, with what replaced them, rather than deleted.*

- **F203 — an L7 deploy retags every app to `:latest` and erases the provenance V10.2
  reads. Showpiece #3 is red because of it.** New tonight, and the highest-value fix on this
  page because it is small, understood, and holding a showpiece down.

  `.github/workflows/layer-07-apps.yml` declares `image_tag` with `default: latest` and
  applies it to all five apps. F197 fixed V10.2 by asking whether the **running image
  contains the merge commit**, which works because app CI tags images `sha-<short-sha>` —
  *"the running image names its own commit."* The two L7 runs on 2026-09-16 replaced
  `mcp-tools:sha-…` with `mcp-tools:latest`, and the binding went with it.

  **V10.2 is behaving exactly as designed.** F197 deliberately chose *"a tag that resolves
  to nothing … reports `could not establish` and stays red; it never converts silence into
  'the heal never ran'."* That is the right rule. The consequence is that deploying
  showpiece #2 turns showpiece #3 red for the remainder of the 30-day closure window, with
  nothing in either layer's documentation connecting them.

  **Every V7 criterion passed on the same revision** — none of them asks what commit the
  image came from. The damage is only visible from another layer's audit, on a schedule,
  four hours later. **Fix: make L7 resolve a concrete `sha-` tag rather than defaulting to a
  floating one** — *prefer a value the template derives over one a human stores* (F129).

- **F202 — a newly discovered MCP tool arrives DISABLED, and a rebuild walks straight back
  into it.** Found by the sponsor, by arithmetic, hours before a demo.

  The agent answered a launch-provider question with counts summing to exactly **1,200** —
  Fabric's row count — citing a table that does not exist in the AWS Glue catalog. Seven
  tools were listed and the seventh was **switched off**. Neither the list's length nor the
  orchestration setting distinguishes that state from a working one. **F119's class in
  another system: a thing that exists but is not enabled behaves exactly like a thing that
  is absent.**

  The claim that made it possible — *"the tool list refreshes dynamically from the server"*
  — was recorded when `query_compliance` became the sixth tool, **before the connector was
  ever built**, so it had never been exercised by adding a tool to a live connection.

  **Closed in the documentation, not in the product**, because the portal state is manual by
  nature: `agent-definition.md` § 4.1 and L08.md's V8.3 no longer carry the false sentence;
  `infra/copilot-studio/README.md` § 6 step 4 and the import job's run summary now say
  *toggle every tool on, then publish*; and an eighth step says **confirm by arithmetic** —
  1,200 and 286,473, because both lakehouses have a `launches` table and plausible vehicle
  names, so only the numbers discriminate. **Bounded by measurement:** a later re-import did
  *not* disable the tool again, so the hazard is a newly *discovered* tool, not every import.

- **F201 — `.github/dependabot.yml` declares per-directory npm entries for npm *workspace
  members*, so its bump PRs are dead on arrival.** Still open. Verified against the open
  Dependabot PRs, not inferred.

  Seven npm entries name directories the root `package.json` also lists in `workspaces`. A
  per-directory entry bumps that member's `package.json` and **does not update the root
  `package-lock.json`**, which is the only lockfile root `npm ci` reads. **#264 is the
  control that proves it**: it bumps the same package as #261 and is green purely because
  the root entry maintains the root lockfile.

  **Do not fold PR #263/#273 into this** — the root group bump fails for a *different*,
  adjacent reason: `apps/mcp-tools` carries a **standalone** lockfile nothing at the root
  maintains. Two defects, one fix each. #263 has been closed; **#273 is the same bump and
  fails the same two checks today.**

  **No test reads `.github/dependabot.yml` for this shape.** That is the gap worth closing —
  *a class paid for once becomes a check* — and `failure-classes.Tests.ps1` is where it
  belongs. Full detail in the [2026-09-16 register](findings/2026-09-16-finding-register.md).

- **The Key Vault grant that feeds V8.6/V8.7 is in Bicep and has never deployed.** One L7
  run fixes it. Until then, tonight's two PASSes rest on a hand-applied role assignment, and
  a teardown returns both criteria to SKIP without anything going red. See the AWS section
  above.

- **F182's leading hypothesis about V6.2 was WRONG, and F196 says so.** Unchanged from the
  last refresh, and still the best-value cheap audit anyone can run.

  F182 recorded V6.2 failing on the rebuilt estate with one sentence offering two readings
  and committing to neither, and named a leading, explicitly unproven hypothesis: that V6.2
  retries past the federated assertion's five-minute lifetime and reports the resulting auth
  failure as "no result".

  **The code disproves it.** `Invoke-MlsAz` matches the expired-assertion error and
  **throws**, deliberately, even under `-AllowFailure`, with a comment explaining that
  swallowing it is how *"an expired credential becomes 'the lakehouse has no tables'"*. An
  expired assertion reaches a criterion as `check threw: … could not authenticate`, never as
  `no result`.

  **What was actually fixed (F196, 2026-09-05)**: on the failure path only, V6.2 now asks
  whether this identity can mint a Log Analytics token — **no token → `SKIP`**, stating that
  reachability is unobservable; **token obtained → `FAIL`**, pointing at workspace RBAC.

  **V6.2 is not claimed fixed and still has no verdict. There has been no L6 run since
  2026-09-02 — the fix has never once executed.**

- **DEADLINE — the `container-image` lane deferral expires 2026-10-07.** Declared in
  `.github/self-heal-policy.json` under `laneDeferral`. Lane 3 has **no automated path on
  this subscription**: ACR Tasks returns `TasksOperationsNotAllowed`, reproduced twice on two
  registries in two resource groups, and the documented scheduled-rebuild fallback is not
  built. Its findings do not count against V10.1 until that date, **at which point the
  deferral stops applying by itself and V10.1 goes red if the lane still has no mechanism.**

  The expiry is the design, not an oversight: *"an exclusion that cannot expire is exactly
  the dumping ground V10.4 exists to prevent, one level up."* **This date falls after the
  2026-09-27 shutdown**, so in practice it expires against an estate that no longer exists —
  worth deciding about deliberately rather than discovering.

- **DEADLINE — the one real Dependabot alert reaches its SLO on 2026-09-27.** Alert **#5**,
  `esbuild`, severity **low**, on the root `package-lock.json`, created **2026-08-28**. The
  policy declares **30 days** for `low`, so the clock runs out on the same day as the
  shutdown. The other three open Dependabot alerts (`semver`, `minimist`, `json5`) are all in
  `apps/vuln-lab` and excluded by policy. **This is what V10.1 is standing on.** Heal it, or
  record the decision not to.

- **BLOCKER-B is CLOSED (2026-09-17), and F184 with it.** It read: *the eval reports 0/10
  with zero tool calls and cannot tell an unhealthy agent from an eval that is not allowed to
  reach a healthy one.*

  **The eval grades.** Run `35166952968`, 2026-09-17T00:37Z: **9/10, bar 9,
  `unobservable: 0`**, over Direct Line against the deployed agent. The answers carry real
  numbers from both lakehouses.

  *What replaced it, and it is smaller:* the eval's artifact is **not a verdict** — V8.2 and
  V8.5 both reported `(not selected)` in that filtered run, and V8.2's second half is the
  Verifier re-deriving each number from the lakehouse, which has not happened. **An
  unfiltered L8 audit is the cheap next step.** Two things it should be run to settle:
  **p95 34.18 s against V8.5's 20 s budget** (driven by an un-warmed first question, and by
  disambiguation legitimately querying both lakehouses), and the one eval failure —
  `worst-supplier`, which failed by **declining**, not by being wrong. `toolCalls` is `[]` on
  every question, because Direct Line does not expose the orchestrator's trace: **V8.3's
  runtime half is unobservable through this transport.**

- **BLOCKER-C is CLOSED (2026-09-05).** *The nightly compliance state could not merge
  (F120).* The commit job pushes with `SELF_HEAL_TOKEN` rather than `GITHUB_TOKEN`, and where
  a direct push to `main` is available it takes it, so no pull request needs checks that can
  never report. **The evidence is the artifact, not the workflow's success**:
  `compliance/state/` holds an unbroken daily sequence 2026-09-05 → 2026-09-17 committed to
  `main`, and **V12.6 PASSES** as of 2026-09-17 00:52. The visible gap 2026-08-30 → 09-04 is
  exactly the nine days F120 ate; it is left in place because it is the record.

  *What replaced it:* nothing blocking. The remaining compliance problem is **coverage, not
  freshness** — 0 machine-verified of 110 — and that was never what BLOCKER-C described.

- **BLOCKER-D is RETIRED, not fixed — the model it described no longer exists.** PR #237
  (merged 2026-09-07) retired the seeded-CVE plant by sponsor-approved design. The showpiece
  is now four policy-driven criteria over the *real* finding backlog, declared in
  `.github/self-heal-policy.json` and read by `verification/layer-10-audit.ps1`: **V10.1**
  the backlog drains, per lane and per severity · **V10.2** every closure is traceable ·
  **V10.3** the alert surface was readable · **V10.4** pending-solution is not a dumping
  ground. `apps/vuln-lab` is excluded from the *backlog* by policy, not from visibility.

  **Three of the four pass tonight; V10.2 does not, for the reason at the top of this tree.**

- **BLOCKER-A is CLOSED (2026-09-03)**, and the closure is confirmed by L4's verdict standing
  since. `mls-verifier` holds `Exchange.ManageAsApp` and **Global Reader** — read-only,
  deliberately not the Compliance Administrator role `mls-purview` carries.

  **Performing it surfaced F178, still a live hazard.** `az ad app permission admin-consent`
  **RECONCILES** rather than adds: it removed three `Telemetry.Probe` grants and created
  nothing. Those three roles are how the authenticated DAST gets past Easy Auth. Repaired by
  re-running `layer-03-entra.yml`, and g0-bootstrap step 11d now uses a direct additive POST.
  **Never run `admin-consent` against `mls-verifier` — and if someone has, re-run L3.**

- **BLOCKER-E is CLOSED (2026-09-03), by sponsor decision.**
  `scripts/bootstrap/02-fabric-capacity.ps1`'s `-ResourceGroup` default is now
  `<prefix>-rg-fabric`, outside the four groups the teardown deletes by name. A test asserts
  the default is never one of the four, derived from `naming.bicep`.

  **`mls-rg-identity` is the same pattern applied a second time**, for the AWS trust
  identity — and it carries the same obligation, now joined by three more objects. See the
  shutdown list at the top.

- **Open sub-items, none of them blocking:**
  - V8.3 still needs a Dataverse read role for `mls-verifier`.
  - **F190 is open and worked around**: the vuln-lab cannot be re-armed through a pull
    request, because code-scanning merge protection blocks the very alert the reseed exists
    to raise. Less pressing since PR #237 made the lab non-load-bearing.
  - **V11.3–V11.5 have never reported.** The shutdown teardown is the last chance.
  - **PR #104 is NOT stale — do not merge or close it.** It is L7 V7.4's **canary pull
    request**, open by design since 2026-08-31 and passed to the audit as `-CanaryPrNumber`.
    The Verifier never writes to the repo, so the canary has to come from the deploy side and
    stay open. Merging it silently breaks a criterion, and it looks exactly like an abandoned
    docs PR.
  - **F215** — the MCP container logs `5 tools` at startup while `/healthz` on the same
    revision reports 7. A diagnostic that lies, in the exact place an operator looks when
    debugging F202's class.
  - **F217** — `aws sts get-caller-identity` on the development machine returns the account
    **root** principal, against which the sponsor's careful IAM scoping constrains nothing.
    Larger than this repository, and named here rather than left silent.
  - **An id collision in this file's own history**: BLOCKER-D cited "F126" for *self-healing
    has no subject*, while the 2026-09-03 register's F126 is *the self-heal notice named a
    remedy that was already done*. Two findings, one id. The registers are archives and are
    not edited; this note is here so the next reader is not misled.

---

## HOW TO USE THIS DOCUMENT

- **This file is the working surface, and it is short on purpose.** If you have just been
  handed this repository, or your conversation has been compacted: read the tables above,
  pick the highest blocker you can actually act on, and **check its evidence yourself
  before acting on it**. That is not ceremony — the registers record several confident
  diagnoses that a second sample disproved, and the cross-cloud day added one of the best
  examples yet: a two-branch diagnosis of F202 where **both branches were wrong** and the
  truth was a third state nobody had considered.
- **Read the freshness column before the status column.** A green verdict from 2026-09-03 and
  a green verdict from an hour ago are not the same claim. Five layers (L3, L7, L8, L10, L12)
  were measured within the last day; everything else on this page is last-known-good from the
  rebuild, and says so. **"Not re-run — no current verdict" is a legitimate row**, and it is
  more useful than a stale green one. Three things on this page have **never reported at
  all** — V6.2's fix, V11.3, V11.4 and V11.5 — and that is different again from stale.
- **Distinguish an artifact from a verdict.** An eval result, a deploy log and a hand-run
  script are *claims*; a criterion in a `verify` job running as `mls-verifier` is what makes
  one evidence. Tonight's page carries both kinds and labels which is which — the 9/10 eval
  and the p95 are artifacts, V7.1–V7.7 and V8.6/V8.7 are verdicts.
- **Distinguish an observation from a property.** V8.6 and V8.7 have passed **once**, on an
  estate never torn down since they existed. So has the entire AWS link. A rebuild is the
  only thing that converts an observation into a property, and there is one rebuild left.
- **The history is in the three dated registers** —
  [2026-09-03](findings/2026-09-03-finding-register.md),
  [2026-09-04](findings/2026-09-04-finding-register.md) and
  [2026-09-16](findings/2026-09-16-finding-register.md) — complete through F217. Nothing was
  removed from any of them when findings closed, including the diagnoses that turned out to
  be wrong. Do not mistake an entry from 2026-08-29 for current state; that is what this file
  is for.
- **A finding with a test is closed. A finding with only prose is open.** Finding ids
  (`F1`–`F217`) are greppable across `docs/`, `CLAUDE.md`, the layer runbooks under
  `docs/runbooks/layers/`, and `verification/tests/`.
- **A layer is done when the Verifier says so, not when the deploy is green.** The
  2026-09-03 rebuild found three places where a green job had verified nothing at all —
  F170, F175 and F177. Read the criterion table, not the job status. And the converse now
  applies too: **L8's verify job shows a red X tonight and two criteria PASSED inside it**,
  because the audit exits 3 on a filtered run so nothing downstream can read a diagnostic as
  a sign-off.
- **The clock is the new constraint.** With shutdown around 2026-09-27, prefer work that
  either captures evidence that becomes unobtainable afterwards, or proves a claim the
  outbrief will make. A capability demonstrated over empty data demonstrates nothing, and a
  screenshot is a claim — but an unrun audit on a live estate is a claim nobody can make at
  all once the estate is gone.

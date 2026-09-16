# Demo readiness — what is verified, what is broken, and what the audits cannot see

**The live state of the estate, and the only file here that claims to be current.** Every
verdict below came from a run against the deployed estate. Where something has not been
re-verified, this file says so rather than reusing an older verdict — a verdict recorded at
one moment and carried forward after the system changed underneath it is the single most
common defect this project has recorded.

A layer is done when the independent auditor says so, not when a deploy exits zero. Read
the criterion tables, not the job status.

**Refreshed 2026-09-16.** The previous refresh was 2026-09-04 and it had aged twelve days.
Everything below was re-measured for this pass or is explicitly marked as not
re-measured — there is a **freshness** column and it is the most important one on the page.
What was checked, and how: the live estate via `az`, GitHub workflow runs and their logs via
`gh`, `compliance/state/` and the git log on disk. What was *not* checked is named rather
than assumed.

> **One caveat on provenance, stated because this file's whole value is provenance.** The
> live Azure reads in the estate table below were made from an ambient `admin@` Azure CLI
> context, **not** as `mls-verifier`. That is a *wider* credential, so those reads may see
> what an audit would not: treat them as evidence the resources exist, never as evidence
> that the Verifier identity can see them. Every criterion verdict in this file comes from a
> real audit job running as `mls-verifier` in CI, and each one carries its run id.

The history — every defect found while building this, in order, including the diagnoses
that turned out to be wrong — is a dated archive:
**[2026-08-22 → 09-03](findings/2026-09-03-finding-register.md)** and
**[2026-09-04](findings/2026-09-04-finding-register.md)**, which carries F190–F200. Nothing
was removed from either, and nothing in this refresh removed anything from them.

---

## THE SCORECARD

*Standing section. Update it when a status changes; do not let it drift. A new agent, or a
conversation that has been compacted, should be able to read only this and the blocker tree
below and know what to do next.*

`docs/BRIEF.md` commits to **four showpieces** and **twelve layers**.

### THE DEADLINE — the estate shuts down around 2026-09-27

**This is now the thing that orders all other work, so it goes first.** The subscription and
trials behind this estate expire and the estate is scheduled for teardown **around
2026-09-27**. That is roughly eleven days from this refresh.

What that changes about priority:

| | |
|---|---|
| **Capture evidence while the estate is up** | Screenshots, real rows, rendered dashboards. After shutdown these are unobtainable. The outbrief's *prose* can be written afterwards; its *screenshots* cannot |
| **Land the AWS cross-cloud link** | Six of nine tasks remain and it is the newest showpiece-grade capability. See the workstream table below |
| **Chase the phase-3 gaps that still have time** | The copilot eval (F184), V9.5, V6.2's first post-fix run |
| **Instrument the final teardown** | The last teardown is itself evidence — the claim the repository exists to make. Run it as a measured demonstration, not as cleanup |

**Two objects survive the teardown deliberately and need their own line items**, because
`infra-down.yml` deletes four resource groups by name and neither of these is among them:
`mls-rg-identity` (holding `mls-aws-demo-id`) and the AWS IAM role created by the
sponsor-run trust-anchor scripts. They were placed outside the blast radius on purpose;
delete them deliberately at the end rather than discovering them later.

### The live estate, read 2026-09-16

Read directly from Azure on 2026-09-16. Credential caveat above applies.

| | |
|---|---|
| Resource groups | **5** — `mls-rg-apps`, `mls-rg-data`, `mls-rg-ops`, `mls-rg-platform` (the four the teardown deletes) plus **`mls-rg-identity`**, new and deliberately outside the blast radius |
| Resources in the teardown blast radius | **30** — apps 10, ops 9, platform 8, data 3. The same 30 the 2026-09-03 rebuild produced |
| Resources outside it | **1** — `mls-aws-demo-id`, the user-assigned identity the AWS trust chain federates from |
| Container apps | **6 / 6** `Running` / `Succeeded` — compliance, control-tower, data-api, launch-ops, mcp, vuln-lab |
| Region | `centralus`, all five groups |
| Uptime | unattended since the 2026-09-03 rebuild — no redeploy of L2/L5/L6/L7 in thirteen days |

**One live gap worth knowing before you plan AWS work.** `mls-aws-demo-id` exists, but
`mls-mcp-demo-ca` still lists **only its own identity** — the AWS identity is wired in
`infra/bicep/apps/main.bicep` and **has not been deployed**. L7 must be redeployed before
any token exchange from that app can work. Verified 2026-09-16 by reading the container
app's `identity` block directly.

### The teardown-and-rebuild, measured 2026-09-03

This is the claim the repository exists to make, so it keeps its place. **These figures are
from 2026-09-03 and have not been re-measured** — there has been no teardown since. They are
history, not current state, and the next teardown is the 2026-09-27 shutdown.

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
does not represent at all. **Whether it is met now is unknown** — several audits have had
their wait windows narrowed since (F169's class), and nothing has re-measured the total.

### The four showpieces

| # | Showpiece | Status | Freshness | Evidence |
|---|---|---|---|---|
| **3** | **Self-healing code** | ✅ **working, and the only showpiece with a verdict measured today** | **current — 2026-09-16 18:27 UTC** | **All four criteria PASS**, read from `self-heal` run `35134434031`, verify job running as `mls-verifier`. **V10.1** the backlog drains, no healable finding past its declared SLO · **V10.2** every closure is traceable · **V10.3** the alert surface was readable, so a denial is never recorded as "nothing to heal" · **V10.4** pending-solution is not a dumping ground. The workflow runs **every 6 hours** (`cron: 13 */6 * * *`) and **the last twelve consecutive scheduled runs all concluded `success`** (2026-09-14 01:01 → 2026-09-16 18:26). This is no longer an evidence trail from one lucky day; it is a standing green criterion set re-measured four times daily |
| **4** | **Compliance platform** — NIST 800-171 | 🟡 **the platform works and its history is now real; the content is still thin** | **current — 2026-09-16 20:34 UTC** | **V12.1, V12.2, V12.4, V12.6 PASS; V12.3 and V12.5 SKIP**, from `compliance` run `35147408731`. **V12.6 — "the collection history is a git history" — now passes**, which is BLOCKER-C closing. `compliance/state/` holds **fourteen** snapshots with an **unbroken daily run 2026-09-05 → 2026-09-16**, all committed to `main`. Latest artifact `state-latest.json`, collected `2026-09-16T20:35:03Z` at commit `5890313`. **The figures have not moved and that is the honest part**: 110 requirements, **0 COMPLIANT**, 15 PARTIAL, 1 GAP, 94 NOT_ASSESSED; provenance **0 machine-verified**, 16 asserted, 94 none. The freshness problem is fixed. The coverage problem is not, and was never the same problem |
| **2** | **Control tower** — Dev/Sec/Ops on Well-Architected pillars | 🟡 **was working on 2026-09-03; no current verdict** | **stale — 13 days** | **V7.6 PASSED on 2026-09-03**: the data API answered with rows, not merely a status code. That is the criterion that exists because an empty estate once signed off 5/5. **L7 has not been audited since.** What *is* current: all six container apps are `Running` as of 2026-09-16. What is not: whether the API still returns rows, and whether the pixels render. **Not re-opened in a browser since the rebuild** — on 2026-09-03 the API was verified and the pixels inferred; today neither is |
| **1** | **Copilot service** — Ask tab over Direct Line | 🟡 **agent survives the rebuild; the eval still cannot grade it** | **stale — 13 days** | Unchanged since 2026-09-03 and **not re-run**. F183 is fixed, so `layer-08-agent-eval` uploads and V8.2/V8.4/V8.5 no longer skip for want of an artifact. The eval reported 0/10, p95 4.0s, **0 tool calls**, no transport errors. **That result is still not interpretable (F184)**: the eval connects with the Direct Line secret and no user token, and this agent authenticates manually (Entra ID V2, F128), so a healthy agent declining tools to an unauthenticated caller produces exactly this signature. The open question is unchanged: can the eval authenticate as a user, and if not, should it report UNOBSERVABLE rather than a grade of zero |

### The twelve layers

**Current verdicts — measured within the last 24 hours:**

| Layer | Status | Measured | Note |
|---|---|---|---|
| L3 Entra | ✅ **4 of 4 PASS** | **2026-09-16 20:32**, run `35147161355` | V3.1 object counts · V3.2 group memberships · V3.3 CA policy state, *and the enforced policy really enforces MFA* · V3.4 licensing 5 of 5. Re-run because the AWS workstream added a fifth app registration; it is current by accident of that work, not by schedule |
| L10 self-healing | ✅ **4 of 4 PASS** | **2026-09-16 18:27**, run `35134434031` | V10.1–V10.4, policy-driven. See showpiece #3 |
| L12 compliance | ✅ **4 PASS + 2 SKIP** | **2026-09-16 20:34**, run `35147408731` | V12.1/2/4/6 PASS, V12.3 and V12.5 SKIP. Runs nightly at 02:17 UTC and on every push to `main` |

**Verified on the rebuilt estate 2026-09-03/04, and NOT re-audited since.** These are real
verdicts against a real deploy — and they are twelve to thirteen days old, against an estate
nobody has redeployed in that time. Treat them as *last known good*, not as current.

| Layer | Last known | Measured | Note |
|---|---|---|---|
| L1 repo / IaC / OIDC | ✅ green | 2026-09-04, run `33834831053` | `verify-l1` concluded `success`. **Criterion-level verdicts were not re-read for this refresh**, so "green" here means the job, which is exactly the thing this file tells you not to trust. V1.5 (governance mode vs. the live ruleset) is the one worth re-running: `.github/governance-mode.json` still declares `development`, declared 2026-09-04 |
| L2 landing zone | ✅ verified | 2026-09-03, inside `infra-up` | No standalone `layer-02-landing-zone` run has ever been made; its sign-off happens inside the ordered rebuild |
| L4 Purview labels | ✅ **2 PASS + 1 by-design SKIP** | 2026-09-03, run `33753883078` | `V4.1` the four labels · `V4.2` survival across kill/rebuild, deferred to L11 by design · `V4.3` the label policy publishes the taxonomy. The first verdict this layer ever had. **V4.2 is still unproven by machine.** Nothing has touched Purview since, so this is likely still true — *likely* is not verified |
| L5 Fabric | ✅ 4 of 4 | 2026-09-03, inside `infra-up` | First clean sign-off after F104/F105/F114. The last *standalone* `layer-05-fabric` run was 2026-09-01 and it **failed**; do not read that run as current either |
| L6 platform | 🟡 **6 of 8, and V6.2's fix has never executed** | 2026-09-02 / 2026-09-03 | V6.1, V6.5, V6.7, V6.8 PASS; V6.3, V6.4 PENDING by design. **V6.2 is the live unknown — see the blocker tree, because the file's old account of it was wrong** |
| L7 apps | ✅ 7 of 7 | 2026-09-03 | Including **V7.6** — the data API answers with rows — against a data-api identity whose client id had just changed, with Directory Readers holding zero members. F172's fix removed the dependency rather than automating it. **Now carries undeployed change**: `apps/main.bicep` wires the AWS identity into `mls-mcp-demo-ca` and that has not been applied |
| L8 Copilot Studio | 🟡 V8.1 PASS, V8.2–V8.5 short of a verdict | 2026-09-03 | See showpiece #1. Also true regardless of the agent's health: the import job prints **"L8 — imported, NOT yet live"**, lists seven manual steps, and **reports success anyway**. A green L8 has never meant a live agent |
| L9 DevSecOps chain | 🟡 partial | 2026-09-03, `zap` run `33720917308` | The DAST was re-run on the rebuilt estate and is real: six targets *derived from Azure*, three authenticated, **zero High-risk alerts**. V9.5 remains the gap and needs a Defender toggle round-trip, which is a G2 action. The last standalone `layer-09-devsecops` run was 2026-09-02 and **failed** |
| L11 teardown / rebuild | ✅ V11.1 and V11.2 PASS | 2026-09-03, run `33751531348` | V11.2 — the criterion proving a teardown did not cross the G3 tenant-object line — reported for the first time ever, after three attempts and three distinct causes (F170, F180, and F180's own fix). **V11.3–V11.5 remain unreported**; the up-phase audit has not completed a run. **The 2026-09-27 shutdown is the next chance to get them, and probably the last** |

### The cross-cloud AWS lakehouse link — a workstream this file has never carried

**New since the last refresh, and it is where the active work is.** A link from the Copilot
agent to the sponsor's **real** AWS Athena lakehouse (`launch-intel`), over **OIDC
federation with no stored AWS credential** — which is the same trust model the Azure side
already uses, extended across a cloud boundary.

- Spec: [`docs/superpowers/specs/2026-09-16-aws-lakehouse-link-design.md`](superpowers/specs/2026-09-16-aws-lakehouse-link-design.md)
- Plan: [`docs/superpowers/plans/2026-09-16-aws-lakehouse-link.md`](superpowers/plans/2026-09-16-aws-lakehouse-link.md)
- Ledger: `.superpowers/sdd/2026-09-16-aws-lakehouse-link/progress.md` — **detailed, and the
  best single account of what went wrong and why.** Read it before picking up a task

**Three of nine tasks merged to `main`, all on 2026-09-16:**

| Task | What it landed | PR |
|---|---|---|
| 1 | The AWS-facing Entra audience — a fifth app registration, tokenised in `infra/entra/manifest.json` | **#265** |
| 2 | The durable trust identity `mls-aws-demo-id` in `mls-rg-identity`, outside the teardown blast radius | **#266** |
| 3 | The sponsor-run AWS trust-anchor and Athena role scripts | **#267** |

**Six remain**: 4 the Trino dialect (in flight), 5 the Athena backend, 6 configuration and
the token exchange, 7 tool registration, 8 the two new criteria, 9 deploy and probe against
the real engine.

**What this workstream has already taught, and it belongs in the outbrief.** The
deploy-identity divergence recorded as a *deferred minor* after Task 1 — one deploy run
under an ambient `admin@` token instead of CI's OIDC identity — was assumed self-closing.
It was the cause of a **silent, unreportable write failure two tasks later in a different
subsystem**: `mls-github-deployer` holds `Application.ReadWrite.OwnedBy` (narrowed
deliberately by F8), the app created out of band had no owner, so L3 could never write it —
and **could never have told us**, because a converged app issues no PATCH at all. The
sponsor added the owner; L3 now returns the declared token version where it returned null.
That is F125's class one level up: not a value that cannot be seen, but a *permission* that
was never held, on an object nobody noticed was unowned.

Two more from the same workstream, both caught in review rather than production: an S3
statement conditioned on a key S3 never supplies for that action, which **granted nothing
while reading as a tighter version of itself**; and a `mapfile` that macOS's bash 3 does not
have, which under `set -u` would have silently dropped every check after it.

### The mission itself

*"Fully agent-instantiated … destroyed and rebuilt on demand … the repo is the product."*

**Demonstrated, on 2026-09-03.** The estate was destroyed and rebuilt from a cold dispatch,
in layer order, with independent sign-off at each step, and came back with the same 30
resources — which it still has today. Four fixes that had never been through a teardown were
tested by it and all four survived: the derived DAST targets, the Entra probe roles, the Log
Analytics purge (F107), and an Easy Auth audience that was correctly *erased* because the
template no longer produces it.

**What the rebuild cost, and this is the honest part.** It failed twice before it passed. It
surfaced eleven findings (F167–F177), of which the three most valuable were not bugs in the
estate but **green checks that were verifying nothing** — L4's audit, V11.2, and a
grant-failure reporter that reported success. A rebuild is the only thing that finds those.

**The claim is thirteen days old and the estate has run untouched since.** A rebuild proves
reproducibility at the moment it runs. The 2026-09-27 shutdown is the next and final
opportunity to prove it again, and it should be instrumented as evidence rather than run as
cleanup.

---

## THE BLOCKER TREE

*Ordered by how much each unblocks. Entries that no longer describe reality are retired
here, with what replaced them, rather than deleted.*

- **BLOCKER-C is CLOSED (2026-09-05).** *The nightly compliance state could not merge
  (F120).* PR #147 — the one this file recorded as open with zero checks — was **closed
  2026-09-05**. The mechanism is fixed at the root: the commit job now pushes with
  `SELF_HEAL_TOKEN` rather than `GITHUB_TOKEN`, and where a direct push to `main` is
  available it takes it, so no pull request needs checks that can never report.

  **The evidence is not the workflow's own success, it is the artifact.** `compliance/state/`
  holds an **unbroken daily sequence 2026-09-05 → 2026-09-16** committed to `main`, each as a
  `verify(compliance): state at <sha>` commit, and **V12.6 — "the collection history is a git
  history" — PASSES** as of 2026-09-16 20:34. There is a visible gap 2026-08-30 → 2026-09-04,
  which is exactly the nine days F120 ate; it is left in place because it is the record.

  *What replaced it:* nothing blocking. The remaining compliance problem is **coverage, not
  freshness** — 0 machine-verified of 110 requirements — and that is a different piece of
  work that was never what BLOCKER-C described.

- **BLOCKER-D is RETIRED, not fixed — the model it described no longer exists.** It read
  *"self-healing has no subject: Dependabot opens no security PR for the three seeded CVEs,
  so the lane has nothing to adopt."*

  **PR #237 (merged 2026-09-07) retired the seeded-CVE plant by sponsor-approved design.**
  The showpiece is no longer "a planted flaw gets healed". It is now four policy-driven
  criteria over the *real* finding backlog, declared in
  **`.github/self-heal-policy.json`** (`declaredAt: 2026-09-07`, `declaredBy: sponsor`) and
  read by `verification/layer-10-audit.ps1`:

  - **V10.1** the backlog drains — no healable finding open past its declared SLO, reported
    **per lane and per severity, never blended into one number**
  - **V10.2** every closure is traceable — a complete heal trail, or an explicit record of
    being closed another way
  - **V10.3** the alert surface was **readable** — a denial is never recorded as "nothing to
    heal" (F102/F103/F105's rule, encoded)
  - **V10.4** pending-solution is not a dumping ground — every finding held there is checked
    for an upstream fix that actually exists

  `apps/vuln-lab` is now **excluded from the backlog by policy**, not by accident: it is a
  manual demonstration generator a human arms deliberately, and its knowingly-vulnerable pins
  must not age against an SLO the estate never intended to meet. The exclusion is from the
  *backlog*, not from visibility — the alerts still exist, V10.3 still proves the surface was
  readable, and the audit reports how many findings were excluded and why, so an empty backlog
  cannot be manufactured by quietly adding a path.

  **All four criteria PASS as of 2026-09-16 18:27**, and have done across twelve consecutive
  scheduled runs. The F188/F188b/F188c story that sat under this entry is history now and
  lives in the 2026-09-04 register; it is not restated here.

- **DEADLINE — the `container-image` lane deferral expires 2026-10-07.** Declared in
  `.github/self-heal-policy.json` under `laneDeferral`. Lane 3 has **no automated path on
  this subscription**: ACR Tasks returns `TasksOperationsNotAllowed`, reproduced twice on two
  registries in two resource groups, and the documented scheduled-rebuild fallback is not
  built. Its findings do not count against V10.1 until that date, **at which point the
  deferral stops applying by itself and V10.1 goes red if the lane still has no mechanism.**

  The expiry is the design, not an oversight: *"an exclusion that cannot expire is exactly the
  dumping ground V10.4 exists to prevent, one level up."* The audit prints the deferred count,
  the expiry and the days remaining on **every** run. **This date falls after the 2026-09-27
  shutdown**, so in practice it expires against an estate that no longer exists — which is
  worth deciding about deliberately rather than discovering.

- **DEADLINE — the one real Dependabot alert reaches its SLO on 2026-09-27.** Alert **#5**,
  `esbuild`, severity **low**, on the root `package-lock.json`, created **2026-08-28**. The
  policy declares **30 days** for `low`, so the clock runs out on **2026-09-27** — the same
  day as the shutdown. It is currently the **only** open alert in the backlog: the other
  three open Dependabot alerts (`semver` high, `minimist` critical, `json5` high) are all in
  `apps/vuln-lab` and excluded by policy.

  **This is what V10.1 is standing on.** A single low-severity finding inside its window is a
  passing backlog, and it will stop being one on the 27th. Heal it, or record the decision
  not to.

- **F201 — `.github/dependabot.yml` declares per-directory npm entries for npm *workspace
  members*, so its bump PRs are dead on arrival.** New, live, and unrecorded until this
  refresh. **Verified 2026-09-16 against the four open Dependabot PRs**, not inferred.

  Seven npm entries name directories that the root `package.json` also lists in
  `workspaces` — `/apps/launch-ops`, `/apps/control-tower`, `/apps/mcp-tools`,
  `/apps/data-api`, `/apps/directline-token`, `/apps/cost-ingest`,
  `/apps/shared/spec-renderer`. A per-directory entry bumps that member's `package.json` and
  **does not update the root `package-lock.json`**, which is the only lockfile root `npm ci`
  reads. Every job that starts with `npm ci` then dies:

  > `npm error code EUSAGE` · `` `npm ci` can only install packages when your package.json and package-lock.json … are in sync `` · `npm error Missing: @azure/monitor-opentelemetry-exporter@1.0.0-beta.45 from lock file`

  | PR | Dependabot entry | Files changed | Outcome |
  |---|---|---|---|
  | **#261** | `/apps/data-api` — a workspace member | `apps/data-api/package.json` only | **6 checks FAIL**, root `npm ci` EUSAGE |
  | **#262** | `/apps/mcp-tools` — a workspace member | its `package.json` + its *own* lockfile | **6 checks FAIL**, root `npm ci` EUSAGE |
  | **#264** | `/` — the root entry | `apps/data-api/package.json` **+ root `package-lock.json`** | **green, 24 / 0** |

  **#264 is the control that proves it.** It bumps *the same package* as #261, and it is green
  purely because the root entry maintains the root lockfile. The per-directory entries are
  both redundant with the root entry and broken; the root entry already covers every workspace
  member.

  **Do not fold PR #263 into this finding — it fails for a different, already-understood
  reason.** #263 is the **root** group bump. It correctly updates the root `package.json`, the
  root lockfile and seven member manifests, so root `npm ci` is fine. It fails two checks
  because `apps/mcp-tools` carries a **standalone** `package-lock.json` that nothing at the
  root maintains, and #263 left it behind — caught by `verification/tests/lockfile-sync.Tests.ps1`
  (`apps/mcp-tools's lockfile is stale`) and again by the mcp-tools container build. That class
  is documented at length in that test's own header, including the trap that causes it:
  `npm install --package-lock-only` inside a workspace member updates the **root** lockfile
  unless you pass `--no-workspaces`. Two adjacent lockfile defects, one fix each.

  **No test reads `.github/dependabot.yml` for this shape.** That is the gap worth closing —
  *"a class paid for once becomes a check, not just a finding"* — and
  `verification/tests/failure-classes.Tests.ps1` is where it belongs.

- **F182's leading hypothesis about V6.2 was WRONG, and F196 says so.** This file previously
  presented that hypothesis as live. It is not.

  F182 recorded V6.2 failing on the rebuilt estate with one sentence offering two readings and
  committing to neither — *"the query returned no result (HTTP error, or the Reader identity
  cannot query this workspace)"* — and named a leading, explicitly unproven hypothesis: that
  V6.2 retries past the federated assertion's five-minute lifetime and reports the resulting
  auth failure as "no result".

  **The code disproves it.** `Invoke-MlsAz` matches the expired-assertion error and **throws**,
  deliberately, even under `-AllowFailure`, with a comment explaining that swallowing it is how
  *"an expired credential becomes 'the lakehouse has no tables'"*. An expired assertion reaches
  a criterion as `check threw: … could not authenticate`, never as `no result`. Whatever V6.2
  is hitting, it is not that.

  **What was actually fixed (F196, 2026-09-05)** is the thing F182 asked for regardless of
  which hypothesis won. On the failure path only — an extra token call on every pass would
  spend the very assertion lifetime this reasons about — V6.2 now asks whether this identity
  can mint a Log Analytics token: **no token → `SKIP`**, stating that reachability is
  unobservable and that this is *not* evidence about the workspace or its role assignments;
  **token obtained → `FAIL`**, pointing at workspace RBAC, which is a different fix by a
  different person.

  **V6.2 is not claimed fixed, and it still has no current verdict.** F196 is explicit that the
  next real L6 run is what decides. **There has been no L6 run since 2026-09-02** — the fix has
  never executed. Running `layer-06-platform` is a cheap, high-information action and it is
  probably the single best-value audit anyone can run today.

- **BLOCKER-B is still HALF CLOSED, and has not moved since 2026-09-03.** The eval's result
  reaches the audit: F183 is fixed and `layer-08-agent-eval` uploads. What replaces it is the
  sharper question — the eval reports 0/10 with zero tool calls and **cannot tell an unhealthy
  agent from an eval that is not allowed to reach a healthy one** (F184). Next: can the eval
  authenticate as a user, and if not, should it report UNOBSERVABLE rather than a grade of
  zero. **Nothing has been attempted on this in thirteen days**, and it is one of the phase-3
  gaps the shutdown deadline is now pressing on.

  A second gap sits beside it and is independent of the agent's health: the import job prints
  **"L8 — imported, NOT yet live"**, lists seven manual steps, and **reports success
  regardless**. A green L8 does not mean a live agent, and nothing currently asserts the
  difference.

- **BLOCKER-A is CLOSED (2026-09-03)**, and the closure is confirmed by L4's verdict standing
  since. `mls-verifier` holds `Exchange.ManageAsApp` and **Global Reader** — read-only,
  deliberately not the Compliance Administrator role `mls-purview` carries, because a Verifier
  credential that can *write* labels would itself be a finding.

  **Performing it surfaced F178, which is the more useful outcome and is still a live hazard.**
  `az ad app permission admin-consent` **RECONCILES** rather than adds: it removed three
  `Telemetry.Probe` grants and created nothing. Those three roles are how the authenticated
  DAST gets past Easy Auth. Repaired by re-running `layer-03-entra.yml`, and g0-bootstrap step
  11d now uses a direct additive POST with a warning block. **Never run `admin-consent` against
  `mls-verifier` — and if someone has, re-run L3.**

- **BLOCKER-E is CLOSED (2026-09-03), by sponsor decision.**
  `scripts/bootstrap/02-fabric-capacity.ps1` defaulted `-ResourceGroup` to
  `<prefix>-rg-platform`, which teardown deletes and nothing recreates. The default is now
  `<prefix>-rg-fabric`, outside the four groups the teardown deletes by name. Teaching
  `infra-up.yml` to recreate it was rejected: that puts a paid capacity creation on every
  rebuild, which is a G2 spend action happening automatically. A test asserts the default is
  never one of the four, derived from `naming.bicep` so a rebrand cannot move it back inside
  the blast radius.

  **`mls-rg-identity` is the same pattern applied a second time**, for the AWS trust identity —
  and it carries the same obligation: something outside the blast radius must be deleted
  deliberately. It is on the shutdown checklist above.

- **Open sub-items, none of them blocking:**
  - V8.3 still needs a Dataverse read role for `mls-verifier`.
  - **F190 is open and worked around**: the vuln-lab cannot be re-armed through a pull
    request, because code-scanning merge protection blocks the very alert the reseed exists to
    raise. Less pressing since PR #237 made the lab non-load-bearing, but the documented path
    still cannot complete.
  - V11.3–V11.5 have never reported. The shutdown teardown is the last chance.
  - **An id collision in this file's own history**: BLOCKER-D cited "F126" for *self-healing
    has no subject*, while the 2026-09-03 register's F126 is *the self-heal notice named a
    remedy that was already done (fixed 2026-09-01)*. Two different findings, one id. The
    register is the archive and is not edited; this note is here so the next reader is not
    misled by the collision.

---

## HOW TO USE THIS DOCUMENT

- **This file is the working surface, and it is short on purpose.** If you have just been
  handed this repository, or your conversation has been compacted: read the tables above,
  pick the highest blocker you can actually act on, and **check its evidence yourself
  before acting on it**. That is not ceremony — the register records several confident
  diagnoses that a second sample disproved, and this refresh found one more: F182's account
  of V6.2, which this very file had been presenting as live for twelve days after F196
  disproved it.
- **Read the freshness column before the status column.** A green verdict from 2026-09-03 and
  a green verdict from this morning are not the same claim. Three layers (L3, L10, L12) were
  measured within the last day; everything else on this page is last-known-good from the
  rebuild, and says so. **"Not re-run — no current verdict" is a legitimate row**, and it is
  more useful than a stale green one.
- **The history is in [findings/2026-09-03-finding-register.md](findings/2026-09-03-finding-register.md)
  and [findings/2026-09-04-finding-register.md](findings/2026-09-04-finding-register.md)**,
  dated and complete through F200. Nothing was removed from either when findings closed,
  including the diagnoses that turned out to be wrong. Open them when you want to know *how*
  something came to be true, or what a green check once hid. Do not mistake an entry from
  2026-08-29 for current state — that is what this file is for.
- **A finding with a test is closed. A finding with only prose is open.** Finding ids
  (`F1`–`F201`) are greppable across `docs/`, `CLAUDE.md`, the layer runbooks under
  `docs/runbooks/layers/`, and `verification/tests/`.
- **A layer is done when the Verifier says so, not when the deploy is green.** The
  2026-09-03 rebuild found three places where a green job had verified nothing at all —
  F170, F175 and F177. Read the criterion table, not the job status.
- **The clock is the new constraint.** With shutdown around 2026-09-27, prefer work that
  either captures evidence that becomes unobtainable afterwards, or proves a claim the
  outbrief will make. A capability demonstrated over empty data demonstrates nothing, and a
  screenshot is a claim — but an unrun audit on a live estate is a claim nobody can make at
  all once the estate is gone.

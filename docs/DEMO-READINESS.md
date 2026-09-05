# Demo readiness — what is verified, what is broken, and what the audits cannot see

**The live state of the estate, and the only file here that claims to be current.** Every
verdict below came from a run against the deployed estate. Where something has not been
re-verified, this file says so rather than reusing an older verdict — a verdict recorded at
one moment and carried forward after the system changed underneath it is the single most
common defect this project has recorded.

A layer is done when the independent auditor says so, not when a deploy exits zero. Read
the criterion tables, not the job status.

The history — every defect found while building this, in order, including the diagnoses
that turned out to be wrong — is a dated archive:
**[2026-08-22 → 09-03](findings/2026-09-03-finding-register.md)** and
**[2026-09-04](findings/2026-09-04-finding-register.md)**, which carries F190–F194 and the
one still open. Nothing was removed from either.

---

## THE SCORECARD

*Standing section. Update it when a status changes; do not let it drift. A new agent, or a
conversation that has been compacted, should be able to read only this and the blocker tree
below and know what to do next.*

`docs/BRIEF.md` commits to **four showpieces** and **twelve layers**.

### The teardown-and-rebuild, measured 2026-09-03

This is the claim the repository exists to make, so it goes first.

**Two full cycles were run on 2026-09-03.** The second existed because the fixes from the
first had never been through a teardown — and it found four more defects, two of them in
the repairs the first cycle produced.

| | |
|---|---|
| Teardowns | **clean, ~14 minutes each** — identical both times. All stages green |
| Rebuild wall clock | **87 minutes** for the full ordered run |
| Deploy work inside that | **~30 minutes** |
| Verification inside that | **~84 minutes** |
| Resources before / after | **30 / 30 / 30** across both cycles — four resource groups, one region, reproduced exactly each time |
| Container apps | **6 / 6**, same names and ingress shape |
| ACA domain suffix | regenerates every rebuild, so no stored FQDN survives (F129's class) |
| Log Analytics workspace | **three distinct identities across three builds** — `5c967cf4` → `87f95e84` → `e26c9dcb`. F107's purge holding across repeated cycles rather than once |
| Managed identities | **all recreated with new principal ids**, e.g. the SQL server's `031dbb19` → `5e231db9` and data-api's client id `3dadafd7` → `ba91c8ea`. This is the condition F172 exists for, and the reason cycle 2 was worth running |

**The estate deploys in half an hour and takes three times that to verify.**
`docs/runbooks/kill-rebuild.md` § 5 budgets "~8–10 min" for the audits and attributes the
wall clock to the deploys; measured, that is inverted. Two audits — L5 at 31.2 min and L7
at 50.6 min, both on their *failing* run — were 94% of the audit time. The `<60-minute`
claim in § 5 is not currently met and the margin is eaten by audit retry windows, which
that section's model does not represent at all.

### The four showpieces

| # | Showpiece | Status | Evidence |
|---|---|---|---|
| **2** | **Control tower** — Dev/Sec/Ops on Well-Architected pillars | ✅ **working, and re-proven on the rebuilt estate** | **V7.6 PASSES**: the data API answers with rows, not merely a status code. This is the criterion that exists because an empty estate once signed off 5/5; it failed on the rebuild, was root-caused and fixed in the deploy path, and now passes. **Not re-opened in a browser since the rebuild** — the API is verified, the pixels are inferred |
| **4** | **Compliance platform** — NIST 800-171 | 🟡 **shipped, and its state is five days stale** | `verification/layer-12-audit.ps1` reported 4 PASS + 2 SKIP on 2026-09-01 and **has not been re-run since the rebuild**. `compliance/state/` holds exactly two snapshots, newest **2026-08-29**, because F120 is still open — PR #147 has carried newer state since 2026-09-01 with **zero checks** and cannot merge. Committed figures: 110 requirements, **0 COMPLIANT**, 15 PARTIAL, 1 GAP, 94 NOT_ASSESSED; provenance **0 machine-verified**, 16 asserted |
| **1** | **Copilot service** — Ask tab over Direct Line | 🟡 **agent survives the rebuild; the eval cannot yet grade it** | **F183 fixed and merged, so the eval finally runs**: it read the Direct Line secret as an identity holding no Key Vault role, reported the secret ABSENT rather than UNOBSERVABLE, and suppressed its own artifact — V8.2/V8.4/V8.5 skipped and L8 stayed green over an ungraded agent for the life of the project. **`layer-08-agent-eval` now uploads**, reporting 0/10, p95 4.0s, **0 tool calls**, no transport errors. **That result is not yet interpretable (F184)**: the eval connects with the Direct Line secret and no user token, and this agent authenticates manually (Entra ID V2, see F128), so a healthy agent may decline tools to an unauthenticated caller and produce exactly this signature. **The agent itself survives the rebuild** — sponsor-confirmed; the browser failure was an expired minted token with the sign-in button correctly offered, which is F142/F150 working. Next: can the eval authenticate as a user, and if not, should it report UNOBSERVABLE rather than 0/10 |
| **3** | **Self-healing code** | ✅ **it healed something, on 2026-09-04, for the first time** | **Copilot Autofix wrote a real fix and the chain merged and deployed it unattended.** Seeded alert #2 `js/command-line-injection` → Autofix `status=success` → PR #226 → 18-check gauntlet → auto-merge `d77aabf` → witness revision `--0000003` stamped with that commit → alert `state=fixed`. **74 seconds from merge to closed alert.** Autofix replaced `cp.exec` on an interpolated shell string with `cp.execFile("git", [...])` on an argv array — the textbook fix, which we did not write. It had never run before because it *could not*: **F188**, no `schedule` arm in the lane picker, so Autofix was skipped on every scheduled run the repository has ever made. Three more defects were stacked behind it (**F188** tool filter, **F188b** missing labels, **F188c** the witness path) — see the blocker tree. The **Dependabot** lane still has no subject (**F126**, unresolved). **V10.1's verdict has not been re-run**, so this is an evidence trail, not a Verifier sign-off |

### The twelve layers

**Re-verified on the rebuilt estate (2026-09-03):**

| Layer | Status | Note |
|---|---|---|
| L2 landing zone | ✅ verified | deploy 8.3 min + verify 0.5 min. The runbook calls this an "idempotent no-op, ~1–2 min"; it is a no-op logically and still costs nine minutes of wall clock |
| L3 Entra | ✅ verified | 4 of 4. Verify went **45.9 min → 0.9 min** once the drift sweep stopped inheriting a propagation window it could never need (F169) |
| L5 Fabric | ✅ verified | **4 of 4**, first clean sign-off since F104/F105/F114. Seed took 4.0 min against a claimed 20–25 |
| L6 platform | 🟡 **6 of 8, V6.2 failing on the rebuilt estate** | V6.1, V6.5, V6.7, V6.8 PASS; V6.3 and V6.4 PENDING by design (24 h cost-export window, 75 min SQL auto-pause). **V6.2 — a KQL query against the workspace — fails, twice, three hours apart (F182).** It reports *"the query returned no result (HTTP error, or the Reader identity cannot query this workspace)"*, which is two different diagnoses in one sentence and commits to neither. Its sibling V6.3, in the same file, names the likely mechanism exactly: the CI federated assertion expires after ~5 minutes and these audits run 14–16. **Unproven, deliberately** — see F182. V6.8 still confirms Key Vault references resolve and V6.7 that the Function Apps hold code |
| L7 apps | ✅ **verified 7 of 7, and it is the session's strongest result** | Including **V7.6** — the data API answers with rows — against a data-api identity whose client id had just changed from `3dadafd7` to `ba91c8ea`, with **Directory Readers holding zero members**. The old path needed that privilege, bound to an identity destroyed with its resource group every teardown (F172). The fix removed the dependency rather than automating it, and the step whose job is to announce a failed grant **skipped**, where in cycle 1 it fired. A change is finished when a rebuild reproduces it; this one now is |
| L8 Copilot Studio | 🟡 partial, and for a different reason than before | **V8.1 PASS**; V8.2–V8.5 still short of a verdict, but **no longer for want of an artifact** — F183 is fixed and `layer-08-agent-eval` now uploads, having never done so once. The eval reports 0/10 with **zero tool calls**, which **F184 says is not yet interpretable**: it connects with the Direct Line secret and no user token against an agent that authenticates manually. Also true regardless: the import job prints **"L8 — imported, NOT yet live"** with seven manual steps and reports **success** anyway, so a green L8 has never meant a live agent |

**Blocked, and honestly so:**

| Layer | Status | Note |
|---|---|---|
| L4 Purview labels | ✅ **verified 2026-09-03 — the first verdict it has ever had** | `[PASS] V4.1` the four labels with expected GUIDs · `[SKIP] V4.2` survival across a kill/rebuild, deferred to L11 by design · `[PASS] V4.3` the label policy publishes the taxonomy. **2 PASS + 1 by-design SKIP.** The labels were always real; nothing could prove it. Three defects stacked behind one another and each hid the next — **F175** (the guard read a `verify` secret from a `demo` job, so the job went green in six seconds having skipped the audit), **F176** (`Connect-IPPSSession`'s `-CertificateThumbprint` is Windows-only, so on ubuntu the call died at binding), and **F177** (`mls-verifier` held neither `Exchange.ManageAsApp` nor any directory role). The first two were fixed in the repo; the third needed a human tenant grant, authorised by the sponsor and performed 2026-09-03 as g0-bootstrap step 11d. See **F179**. **V4.2 is still unproven by machine** — it is deferred to L11, whose V11.2 is the criterion that had never had evidence |

**Not re-run since the rebuild — no current verdict:**

| Layer | Last known | Note |
|---|---|---|
| L1 repo / IaC / OIDC | ✅ | `oidc-login` passed inside the rebuild (V1.1); the full L1 audit has not been re-run |
| L9 DevSecOps chain | 🟡 partial | **The DAST was re-run on the rebuilt estate and is real**: six targets *derived from Azure*, three of them authenticated, **zero High-risk alerts**. V9.5 remains the gap (needs a Defender toggle round-trip, a G2 action) |
| L10 self-healing | ✅ **the chain completed end to end on 2026-09-04 — the first time in this repository's history** | All seven stages, on the seeded vuln-lab flaw, each read from an independent API: alert **#2** `js/command-line-injection` in `apps/vuln-lab/seeds/component-history.js` → **Copilot Autofix** `status=success` (run 33872767439) → **PR #226** labelled `security,self-heal` → 18-check gauntlet green → **auto-merged by automation** 12:35:39Z, merge commit `d77aabf` → witness revision `mls-vuln-lab-demo-ca--0000003` created 12:36:19Z carrying `MLS_HEAL_COMMIT=d77aabf` → alert **`state=fixed`** 12:36:53Z. Autofix's own diff replaced `cp.exec` on an interpolated shell string with `cp.execFile("git", [...])` on an argv array. **Four defects stacked behind one another and each hid the next** — **F188** (no `schedule)` arm in the lane picker, so `if: kind == 'code-scanning'` was false on every scheduled run and Autofix had *never* been invoked; V10.1 was unreachable, not merely failing), **F188** second half (the listing did not filter `tool_name=CodeQL`, and 37 of 44 open alerts are Trivy, which Autofix does not cover), **F188b** (`gh pr create --label` validates labels *before* opening anything and neither `security` nor `self-heal` had ever existed, so the first working run stranded a real fix on a branch), and **F188c** (only `apps/vuln-lab/**` merges re-stamp the witness, so stage 6 was unreachable for a heal anywhere else — proven by PR #225, a correct Autofix heal in `apps/mcp-tools` that merged itself and still could not complete a trail). **V10.1's own verdict has not been re-run since**, so this is an evidence trail, not a Verifier sign-off |
| L11 teardown / rebuild | ✅ **V11.1 and V11.2 both PASS — V11.2 for the first time ever** | The criterion proving a teardown did not cross the G3 tenant-object line has finally reported. **It took three attempts and three distinct causes**: F170 (guard read a `verify` secret from a `demo` job), F180 (`cond && '' || '-Skip…'` can never yield the empty string, so the flag was always passed), and F180's own fix (an explanatory comment inside an `args: |` literal block reached the script as argv). Each was invisible without performing a teardown. V11.3–V11.5 remain unreported — the up-phase audit has not completed a run |
| L12 compliance | ✅ (2026-09-01) | Not re-run since the rebuild |

### The mission itself

*"Fully agent-instantiated … destroyed and rebuilt on demand … the repo is the product."*

**Demonstrated.** The estate was destroyed and rebuilt from a cold dispatch on 2026-09-03,
in layer order, with independent sign-off at each step, and came back with the same 30
resources. Four fixes that had never been through a teardown were tested by it and all four
survived: the derived DAST targets, the Entra probe roles, the Log Analytics purge (F107),
and an Easy Auth audience that was correctly *erased* because the template no longer
produces it.

**What the rebuild cost, and this is the honest part.** It failed twice before it passed.
It surfaced eight findings (F167–F177), of which the three most valuable were not bugs in
the estate but **green checks that were verifying nothing** — L4's audit, V11.2, and a
grant-failure reporter that reported success. A rebuild is the only thing that finds those.

---

## THE BLOCKER TREE

*Ordered by how much each unblocks.*

- **BLOCKER-A is CLOSED (2026-09-03).** `mls-verifier` now holds `Exchange.ManageAsApp`
  and **Global Reader** — read-only, deliberately not the Compliance Administrator role
  `mls-purview` carries, because a Verifier credential that can *write* labels would itself
  be a finding. The sponsor authorised the grant; it was performed as g0-bootstrap step 11d
  and read back. L4 returned 2 PASS + 1 SKIP.

  **Performing it surfaced F178, which is the more useful outcome.** The step as written
  told the operator to run `az ad app permission admin-consent`, which **removed three
  `Telemetry.Probe` grants and created nothing** — it reconciles against the app
  registration's declared permissions rather than adding to what is there. Those three roles
  are how the authenticated DAST gets past Easy Auth, so a documentation step would have
  silently reverted L9's scan to scanning a login page. Repaired by re-running
  `layer-03-entra.yml` — the deploy path fixing damage done from a terminal — and step 11d
  now uses a direct additive POST with a warning block.

- **BLOCKER-B is HALF CLOSED (2026-09-03).** The eval's result now *reaches* the audit:
  F183 is fixed, `layer-08-agent-eval` uploads for the first time ever, and V8.2/V8.4/V8.5
  can stop skipping on "no eval artifact". What replaces it is a sharper question — the
  eval reports 0/10 with zero tool calls, and **cannot tell an unhealthy agent from an eval
  that is not allowed to reach a healthy one** (F184). Next: can the eval authenticate as a
  user, and if not, should it report UNOBSERVABLE rather than a grade of zero.

  A second gap sits beside it and is independent of the agent's health: the import job
  prints **"L8 — imported, NOT yet live"**, lists seven manual not-solution-aware steps
  (publish, Entra ID V2 auth, MCP connection, generative orchestration, channel security,
  sharing), and **reports success regardless**. A green L8 does not mean a live agent, and
  nothing currently asserts the difference.

- **BLOCKER-C — the nightly compliance state cannot merge (F120).** PR #147, open since
  2026-09-01, **zero checks**, blocked. A `GITHUB_TOKEN` push triggers no workflow runs, so
  no required check ever reports. `compliance/state/` is five days stale, which undercuts
  showpiece #4's "the history is a git history" claim directly.

- **BLOCKER-D — self-healing has no subject (F126).** Dependabot opens no *security* PR for
  the three seeded CVEs, so the lane has nothing to adopt. Ruled out: the repo setting,
  patched-version availability, ignore conditions, lingering branches. Leading candidate:
  `open-pull-requests-limit: 0` on `/apps/vuln-lab`, whose exemption for security updates
  is asserted in a comment and has never been verified. **Do not edit that limit casually**
  — raising it also enables version-update PRs that would disarm the seed.

  **This described the DEPENDABOT lane, and it hid a larger fact about the other one
  (2026-09-04).** The CodeQL lane had a subject the whole time — seven open CodeQL alerts,
  one of them the seeded vuln-lab flaw the criterion was written for — and never once
  looked at it. The chain completed end to end that day, on that alert, and the layer row
  above carries the trail. Four defects, each hiding the next:

  - **F188.** The lane picker's `case "${EVENT}"` had arms for `workflow_dispatch` and
    `repository_dispatch` and **none for `schedule`**, which is the workflow's normal
    trigger. Every scheduled run fell through to the `kind="dependabot"` initialiser, so
    `if: kind == 'code-scanning'` was false and **Copilot Autofix was never invoked, on any
    run, since the repository was created**. V10.1 was unreachable, not failing.
  - **F188, second half.** The code-scanning listing did not filter `tool_name=CodeQL`.
    That surface also carries Trivy's uploaded SARIF — 37 of 44 open alerts on `main` — and
    Autofix covers CodeQL only, so the lane could pick an alert it can never fix and report
    "no autofix suggestion" forever, which is indistinguishable from the capability being
    absent.
  - **F188b.** `gh pr create --label` validates labels **before** opening anything, and
    neither `security` nor `self-heal` had ever existed in this repository. The first run
    that reached Autofix got a real fix, committed it to a branch, then exited 1 and
    stranded it. The workflow now creates both itself with `--force`, because doing it by
    hand fixes one clone and the rebuild walks straight back into it.
  - **F188c.** Only a merge touching `apps/vuln-lab/**` re-stamps the deployment witness,
    so V10.1 stage 6 is unreachable for a heal anywhere else. **PR #225 proved it**: a
    correct Autofix patch in `apps/mcp-tools`, gauntlet green, merged itself, and still
    could not complete a trail. The lane now prefers an alert whose heal can finish —
    F137's rule, applied to the second lane.

  **Nothing about any of this was red.** A skipped job is not a failed one, and every run
  went green on the lane it did take. It surfaced because a human looked at a notification
  and asked why the job named after the product said "Skipped".

- **F187 — the L10 audit crashed instead of reporting, and the guard was dead code.**
  `Get-RevisionAfter` declared `[AllowNull()][datetime]$MergedUtc` and guarded its body with
  `if ($null -eq $MergedUtc)`. `[AllowNull()]` waives null *validation* but not type
  *coercion*, and `$null` does not convert to a value type — so the binder threw before the
  guard could run, and that guard had never executed since the day it was written. The
  state that triggers it is the chain's most ordinary one: a PR armed for auto-merge and not
  merged yet. Both trails had already diagnosed every other stage, and the exception text
  replaced all of it. `verification/tests/failure-classes.Tests.ps1` now sweeps for the
  shape — carrying its own detector test, because the first draft of that sweep **passed
  against the very line it was written to catch** (a variable assigned in a Pester
  `Describe` body is set during discovery and gone before the `It` runs).

- **BLOCKER-E is CLOSED (2026-09-03), by sponsor decision.**
  `scripts/bootstrap/02-fabric-capacity.ps1` defaulted `-ResourceGroup` to
  `<prefix>-rg-platform`, which teardown deletes and nothing recreates — so on the paid path
  an ordinary teardown destroyed the capacity, stranded the workspace, and made the *next*
  teardown fail suspending a dead ARM id. It armed on the first teardown after the G2 move to
  paid F2, i.e. the moment the estate starts costing money.

  The default is now `<prefix>-rg-fabric`, outside the four groups the teardown deletes by
  name, which makes `kill-rebuild.md` § 1's long-standing claim that the capacity *persists*
  true rather than aspirational. Teaching `infra-up.yml` to recreate it was rejected: that
  puts a paid capacity creation on every rebuild, which is a G2 spend action happening
  automatically. A test asserts the default is never one of the four, derived from
  `naming.bicep` so a rebrand cannot move it back inside the blast radius.

- **One open sub-item, not a blocker:** V8.1 now passes, but V8.3 still needs a Dataverse
  read role for `mls-verifier`.

---

## HOW TO USE THIS DOCUMENT

- **This file is the working surface, and it is short on purpose.** If you have just been
  handed this repository, or your conversation has been compacted: read the tables above,
  pick the highest blocker you can actually act on, and **check its evidence yourself
  before acting on it**. That is not ceremony — the register records several confident
  diagnoses that a second sample disproved, including two of mine from the 2026-09-03
  rebuild.
- **The history is in [findings/2026-09-03-finding-register.md](findings/2026-09-03-finding-register.md)**,
  dated and complete. Nothing was removed from it when findings closed, including the
  diagnoses that turned out to be wrong. Open it when you want to know *how* something came
  to be true, or what a green check once hid. Do not mistake an entry from 2026-08-29 for
  current state — that is what this file is for.
- **A finding with a test is closed. A finding with only prose is open.** Finding ids
  (`F1`–`F177`) are greppable across `docs/`, `CLAUDE.md`, the layer runbooks under
  `docs/runbooks/layers/`, and `verification/tests/`.
- **A layer is done when the Verifier says so, not when the deploy is green.** The
  2026-09-03 rebuild found three places where a green job had verified nothing at all —
  F170, F175 and F177. Read the criterion table, not the job status.

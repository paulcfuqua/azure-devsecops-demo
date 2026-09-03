# Demo readiness — what is verified, what is broken, and what the audits cannot see

**Re-baselined 2026-09-03, against an estate that was torn down and rebuilt that morning.**
Every figure below was produced by a run on the rebuilt estate, not carried forward. Where
something has not been re-verified since the rebuild, this file says so rather than
reusing the previous verdict — because doing exactly that is what F167 was.

This file is the **live** state. The history — every finding in order, including the
diagnoses that turned out to be wrong — is
**[findings/2026-09-03-finding-register.md](findings/2026-09-03-finding-register.md)**.
Nothing was removed from it.

---

## THE SCORECARD

*Standing section. Update it when a status changes; do not let it drift. A new agent, or a
conversation that has been compacted, should be able to read only this and the blocker tree
below and know what to do next.*

`docs/BRIEF.md` commits to **four showpieces** and **twelve layers**.

### The teardown-and-rebuild, measured 2026-09-03

This is the claim the repository exists to make, so it goes first.

| | |
|---|---|
| Teardown | **clean, 14 minutes** (01:58:37 → 02:12:23Z). All stages green |
| Rebuild wall clock | **87 minutes** for the full ordered run |
| Deploy work inside that | **~30 minutes** |
| Verification inside that | **~84 minutes** |
| Resources before / after | **30 / 30** — four resource groups, one region, reproduced exactly |
| Container apps before / after | **6 / 6**, same names and ingress shape |
| ACA domain suffix | `happymeadow-9e15a087` → `graywave-0cb7cffc` — regenerates every rebuild, so no stored FQDN survives (F129's class) |

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
| **1** | **Copilot service** — Ask tab over Direct Line | 🟡 **survives a rebuild; the audit cannot confirm the answers** | **L8 re-ran clean after the rebuild**: the solution imported, the golden-question eval job over Direct Line went green, and **V8.1 PASSES** (F145's fix — it could never pass before). But **V8.2, V8.4 and V8.5 all SKIP with `no eval artifact`**: the eval ran and the audit cannot see its output, so nothing independently re-derives the answers. It was demonstrated by a signed-in human on 2026-09-02 and **has not been re-demonstrated since the rebuild** |
| **3** | **Self-healing code** | 🟡 **chain works, nothing to heal** | The token half is done and proven; V10.3 passes and the Dependabot lane runs. What is missing is a **subject**: Dependabot opens no *security* PR for the three seeded CVEs (**F126**, cause unresolved). It does open version-update PRs — #173 and #174 are open now — so the distinction is specifically about security advisories. **Not re-run since the rebuild** |

### The twelve layers

**Re-verified on the rebuilt estate (2026-09-03):**

| Layer | Status | Note |
|---|---|---|
| L2 landing zone | ✅ verified | deploy 8.3 min + verify 0.5 min. The runbook calls this an "idempotent no-op, ~1–2 min"; it is a no-op logically and still costs nine minutes of wall clock |
| L3 Entra | ✅ verified | 4 of 4. Verify went **45.9 min → 0.9 min** once the drift sweep stopped inheriting a propagation window it could never need (F169) |
| L5 Fabric | ✅ verified | **4 of 4**, first clean sign-off since F104/F105/F114. Seed took 4.0 min against a claimed 20–25 |
| L6 platform | ✅ verified | 5 PASS + 2 PENDING, both PENDING by design (24 h cost-export window, 75 min SQL auto-pause). V6.8 confirms Key Vault references actually resolve; the vault recovered from soft-delete with its secrets and no human flipped anything |
| L7 apps | ✅ verified | **7 of 7**, including V7.6. Deploy 3.8 min against a claimed 10–15 |
| L8 Copilot Studio | 🟡 partial | **V8.1 PASS**; V8.2/V8.3/V8.4/V8.5 SKIP. Three of those skip on `no eval artifact` — the eval job succeeds and its result never reaches the audit |

**Blocked, and honestly so:**

| Layer | Status | Note |
|---|---|---|
| L4 Purview labels | ✅ **verified 2026-09-03 — the first verdict it has ever had** | `[PASS] V4.1` the four labels with expected GUIDs · `[SKIP] V4.2` survival across a kill/rebuild, deferred to L11 by design · `[PASS] V4.3` the label policy publishes the taxonomy. **2 PASS + 1 by-design SKIP.** The labels were always real; nothing could prove it. Three defects stacked behind one another and each hid the next — **F175** (the guard read a `verify` secret from a `demo` job, so the job went green in six seconds having skipped the audit), **F176** (`Connect-IPPSSession`'s `-CertificateThumbprint` is Windows-only, so on ubuntu the call died at binding), and **F177** (`mls-verifier` held neither `Exchange.ManageAsApp` nor any directory role). The first two were fixed in the repo; the third needed a human tenant grant, authorised by the sponsor and performed 2026-09-03 as g0-bootstrap step 11d. See **F179**. **V4.2 is still unproven by machine** — it is deferred to L11, whose V11.2 is the criterion that had never had evidence |

**Not re-run since the rebuild — no current verdict:**

| Layer | Last known | Note |
|---|---|---|
| L1 repo / IaC / OIDC | ✅ | `oidc-login` passed inside the rebuild (V1.1); the full L1 audit has not been re-run |
| L9 DevSecOps chain | 🟡 partial | **The DAST was re-run on the rebuilt estate and is real**: six targets *derived from Azure*, three of them authenticated, **zero High-risk alerts**. V9.5 remains the gap (needs a Defender toggle round-trip, a G2 action) |
| L10 self-healing | ❌ chain never executed | See showpiece 3 |
| L11 teardown / rebuild | 🟡 **down half verified, V11.2 never had evidence** | V11.1 PASSED (all resource groups absent). **V11.2 recorded SKIP** — and had done on every teardown ever run, because of F170. The criterion that proves a teardown did *not* cross the G3 tenant-object line has never once reported. Fixed 2026-09-03; **untested, because no teardown has happened since** |
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

- **BLOCKER-B — L8's eval result never reaches its audit.** The golden-question eval runs
  and goes green; V8.2, V8.4 and V8.5 all report `no eval artifact`. Three criteria that
  would independently re-derive the agent's answers are therefore silent, and the
  showpiece rests on a job's exit code. This is F102's shape.

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

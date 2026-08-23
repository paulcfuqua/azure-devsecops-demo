# Demo Script — Meridian Launch Systems

The stage flow a presenter follows, end to end: cold open on an empty subscription,
rebuild kickoff, the three showpieces in order, and the kill demo with the idle-cost
view. Audience: launch-industry engineering/security/ops leaders — the narrative is
"the repo is the product; the environment is a build artifact."

Total stage time: **~105 minutes** for the full cold-start proof (Variant A). A
**~50-minute** condensed variant (B) is noted at the end for slots that cannot absorb
a live rebuild. All timings are [derived] estimates — the master plan pins only the
<60-minute rebuild; segment budgets follow from it.

---

## Pre-demo checklist (T-60 → T-0, off stage)

Run through in order; every box must be checked before the audience sits down.

| # | Check | How | Pass state |
|---|---|---|---|
| 1 | **Environment torn down** (this demo opens cold) | `az group list --query "[?starts_with(name,'mls-rg-')]"` | Empty — the cold open depends on it |
| 2 | **Tenant objects intact** | quick re-run of `verification/layer-03-audit.ps1` + `layer-04-audit.ps1` | PASS — rebuild will no-op through L2–L4 as rehearsed |
| 3 | **Capacity state known** | trial: confirmed active trial window; paid F2: `Paused` now, **G2 filed** for the rebuild's resume (the rebuild resumes it — do not resume manually) | Recorded |
| 4 | **Seed data contract verified** (from the last green cycle) | last `verification/reports/L05-*.md` shows `launches = 1,200` and table set green | PASS report ≤ 7 days old |
| 5 | **vuln-lab re-seeded** | `pwsh apps/vuln-lab/reseed.ps1` → PR merged; `gh api .../dependabot/alerts` shows the seeded alerts `open` | ≥ 3 open alerts on `apps/vuln-lab/` |
| 6 | **ANTHROPIC_API_KEY valid** | copilot eval smoke question in mock-free mode (one question, off the record) | Answer + valid spec returned |
| 7 | **All layer audits green** | latest `verification/reports/L*.md` set | All PASS, ≤ 7 days old |
| 8 | **Budget headroom** | Azure portal → Cost Management → budget `$75/month` | < 80% consumed, no unacknowledged alerts |
| 9 | **Browser prepped** | tabs: Azure portal (Resource groups + Cost analysis), GitHub Actions, GitHub Security, launch-ops URL placeholder tab, control-tower URL placeholder tab, copilot UI | Logged in, MFA done — never authenticate on stage |
| 10 | **Fallback pack** | screenshots of every showpiece state + the last committed `rebuild-proof.md` | On local disk |

Notes for step 5: re-seed at T-60, not earlier in the week — freshly-open alerts make
the self-healing segment's timestamps read cleanly ("this alert appeared an hour
ago"). Steps 3–4 exist because the three classic demo-killers are a paused capacity,
a broken seed, and an un-armed vuln-lab.

---

## Segment 1 — Cold open: the empty subscription (5 min)

**Stage picture:** Azure portal, Resource groups blade, filtered to `mls`.

- Show: zero resource groups. "This is the entire Azure footprint of Meridian
  Launch Systems right now. Idle cost: under five dollars a month — OneLake
  storage, log retention, a Key Vault."
- Flip to Cost analysis: the idle run-rate flatline.
- One sentence on what persists and why: identities, Conditional Access, sensitivity
  labels — tenant-level objects that take 15–45 minutes to propagate, so they stay;
  everything that costs money dies. "Deliberate line: money is disposable,
  identity is not."
- Show the repo README for two beats: "Everything you're about to watch come alive
  is in this one public repository."

## Segment 2 — Rebuild kickoff (5 min)

**Stage picture:** terminal + GitHub Actions side by side.

- Run:

  ```
  pwsh scripts/up.ps1
  ```

- Show `infra-up.yml` fan out in the Actions graph. Call the shot: "Under sixty
  minutes from nothing to fully verified — an independent auditor agent signs off
  every layer against the live APIs, and we'll check its wall-clock report at the
  end."
- Point at L2–L4 completing in seconds: "Identity layers no-op — create-if-absent.
  That's why the rebuild is fast."

## Segment 3 — While it builds: the repo tour (35–45 min, elastic)

This segment is the schedule's shock absorber — it stretches or shrinks to match
the rebuild's actual pace. Talk track, in order:

1. **Working agreements + gates (5 min):** `CLAUDE.md`, the five gates (G0–G4).
   Land the punchline: RG-scoped teardown is gate-free *by design* — the kill demo
   at the end needs no approval.
2. **The agent team (5 min):** Orchestrator/Verifier mutual accountability, four
   workstream leads, ICs in worktrees, PR-only merges. Show a real merged PR with
   its layer-tagged conventional commit.
3. **Verifier reports (10 min):** open `verification/reports/` — committed audit
   evidence: exact queries, observed vs expected, PASS/FAIL. Show L05's
   `launches = 1,200 ± 0` line: "Deterministic seed `20260822` — the auditor knows
   the *exact* row count the generators must produce."
4. **DevSecOps chain as code (10 min):** `codeql.yml`, Dependabot config, Trivy
   gate, ZAP, SBOM workflow, the Defender toggle script with its G2 cost note.
5. **Watch the board (remainder):** return to Actions periodically; narrate layers
   going green; when L7 completes, load `launch-ops` and `control-tower` into the
   placeholder tabs and warm them (one request each — absorbs the scale-from-zero
   cold start off the record).
- **Timing hinge:** when `infra-up.yml` completes and the Verifier's synchronous
  audits are green, show the wall-clock number, then move on. If the rebuild is
  still running at T+55 of this segment, keep touring — the showpieces need L8
  green.

## Segment 4 — Rebuild confirmed + self-heal trigger (5 min)

- Show the run summary: all layers green, wall-clock < 60 min (cite the
  `rebuild-proof.md` from L11 for the formally measured proof).
- **Arm showpiece #3 now** so it completes while you present the other two: the
  vuln-lab alerts from pre-demo step 5 are open; show
  `self-heal.yml` already running (or trigger the chain's next step if it has
  been idle-held): "Three known-vulnerable dependencies are live in this estate.
  The pipeline noticed. We'll come back to what it did about them."

## Segment 5 — Showpiece #1: the copilot (10 min)

**Stage picture:** copilot UI full screen.

- **Canonical question (the anchor):** type

  > "Which day of the week has the most launches?"

  Expected on stage: the answer **Saturday**, rendered as a bar chart component
  spec — with the generated SQL visible in the trace panel. Beat: "The model wrote
  SQL against the lakehouse, ran it, and returned a *JSON component spec* — never
  generated UI code. The renderer is fixed; the answer is data."
- **Cross-domain follow-ups (pick 2–3, all from the golden eval suite so answers
  are pinned):**
  - "Which day of the year has the most scrubs?" (golden answer per the eval
    fixture — cross-checks the scrub-cascade messiness)
  - "What did the `launch-ops` app cost us last week?" (exercises
    `get_cost_series` — FinOps tool)
  - "Any critical security findings right now?" (exercises
    `get_github_security` — segues to showpiece #3)
- Close: five tools, allowlisted, audited — "the Verifier re-executes the
  copilot's SQL itself and confirms the numbers. 9 of 10 golden questions minimum,
  p95 under 20 seconds."

## Segment 6 — Showpiece #2: control tower (10 min)

**Stage picture:** `control-tower` app, walking the three tabs — framed on
Well-Architected pillars.

- **Dev tab (3 min):** open vulns (the vuln-lab alerts feature here — plant the
  callback), dependency status, SBOM presence, PR/pipeline status. "Everything on
  this tab is the GitHub Security API, live."
- **Sec tab (4 min):** Defender secure score, findings by severity, NIST 800-53
  posture from Azure Policy (audit mode — honest about it), Entra sign-in risk
  (E5 trial feature — say so; enterprise-real includes licensing-real).
- **Ops tab (3 min):** resource health, throughput/latency from App Insights,
  replica counts ("most of these say zero — that's the idle-cost story"),
  cost-per-app-over-time from the daily export → lakehouse pipeline.

## Segment 7 — Showpiece #3: self-healing close-out (10 min)

**Stage picture:** GitHub — Security tab + the heal PR.

Walk the trail armed in Segment 4, stage by stage (this is V10.1's six-stage chain,
presented live):

1. The Dependabot alert — real CVE, real vulnerable pin in `apps/vuln-lab`.
2. The PR the pipeline opened — with Claude's triage comment explaining the vuln
   and the patch.
3. The CI gauntlet on the PR: CodeQL, tests, Trivy, ZAP — all green.
4. Merged by `github-actions[bot]` — auto-merge on green; no human clicked merge.
5. The new container revision deployed.
6. The alert: state **fixed**, closed by the deploy.

- Beat: "No approval prompt anywhere in that trail — inside this demo environment,
  that's deliberate. The PR trail *is* the human oversight."
- If a chain is still mid-gauntlet, show the completed chain from pre-demo
  rehearsal alongside the live one in flight — two-of-three completing is the
  audited pass line, and an in-flight chain is itself a good stage picture.

## Segment 8 — The kill demo + idle-cost view (8 min)

**Stage picture:** terminal + portal split.

- Run, live:

  ```
  pwsh scripts/down.ps1
  ```

  "No approval gate. Deleting the demo estate is the *most* rehearsed operation in
  this repo."
- Watch the four RGs — `mls-rg-platform`, `mls-rg-apps`, `mls-rg-data`,
  `mls-rg-ops` — enter `Deleting`; show the Fabric workspace `mls-operations`
  emptied; capacity paused.
- While deletes drain, show what did **not** die: users, groups, CA policies,
  labels — re-run the one-liner from the L3 audit for effect.
- Close on Cost analysis: the run-rate stepping back to the <$5/month idle line,
  backstopped by the $75 budget with alerts at 50/80/100%.
- Final line: "Everything you watched exists as code. Kill it, rebuild it, audit
  it — under an hour, under five dollars a month at rest."

## Segment 9 — Q&A buffer (10 min)

Likely questions and where the receipts live:

- *"What does this cost for real?"* → master plan cost envelope table; worst-case
  ≈ $40–60/month in-trial with 4 demo days + weekly rebuilds.
- *"What's licensed vs free?"* → `docs/runbooks/g0-bootstrap.md` § B (E3 vs E5
  table).
- *"What if the auto-merge merges something bad?"* → the gauntlet is the gate;
  revert PRs ride the same gauntlet (L10 playbook, Rollback).
- *"How do I know the agent team didn't rubber-stamp itself?"* → Verifier's
  separate read-only credential (`mls-verifier`), committed audit reports, and the
  two-failure G4 escalation rule.

---

## Variant B — condensed (~50 min, no live rebuild)

For short slots: run `up.ps1` before the audience arrives (T-90), verify audits
green, and replace Segments 2–4 with a 7-minute walkthrough of the committed
`verification/reports/rebuild-proof.md` — the wall-clock evidence stands in for the
live wait. Cold open still works: show the *proof report's* down-state audit
instead of a live empty subscription, or open on the built environment and lead
with the kill demo, rebuilding after the audience leaves. Segment budget: cold
open/proof 7, copilot 10, control tower 10, self-heal 10, kill + idle cost 8, Q&A
5. The full-proof Variant A is the stronger show whenever the slot allows — the
rebuild wait, narrated well, is the credibility.

# Demo Script — Meridian Launch Systems

The stage flow a presenter follows, end to end: cold open on an empty subscription,
rebuild kickoff, the four showpieces in order, and the kill demo with the idle-cost
view. Audience: launch-industry engineering/security/ops leaders — the narrative is
"the repo is the product; the environment is a build artifact."

Total stage time: **~115 minutes** for the full cold-start proof (Variant A) — 105 plus
the ten-minute compliance segment added with showpiece #4 on 2026-08-26. A
**~60-minute** condensed variant (B) is noted at the end for slots that cannot absorb
a live rebuild. All timings are [derived] estimates — the master plan pins only the
<60-minute rebuild; segment budgets follow from it.

> **Changed 2026-08-24 (Copilot Studio amendment).** Two segments move. Showpiece #1 is
> no longer a separate copilot UI: it is the **Ask** tab *inside* the control tower,
> talking over Direct Line to a Copilot Studio agent that answers in Adaptive Cards — so
> segments 5 and 6 are now one browser tab and one app switch disappears. Showpiece #3
> no longer shows a bespoke triage comment: the PR is written by **GitHub Copilot
> Autofix** (for the code finding) and by **Dependabot** (for the dependency findings),
> which is a *stronger* line on stage — "we didn't write the healer either." Net stage
> time is unchanged: the app switch you save, you spend warming the agent.

> **Changed 2026-08-26 (compliance platform).** One segment is **added**, not moved:
> **Segment 8, showpiece #4** — the NIST SP 800-171 board, drilled into a gap, asked
> about through the agent, and its collection history shown as a `git log`. Nothing is
> displaced: segments 1–7 are unchanged and the kill demo and Q&A shift to 9 and 10.
> The stage direction that matters is that this segment's punchline is a screen that is
> **mostly not green**, and the presenter has to set that up rather than apologise for
> it. Budget +10 min (Variant A ~115, Variant B ~60).

---

## Pre-demo checklist (T-60 → T-0, off stage)

Run through in order; every box must be checked before the audience sits down.

| # | Check | How | Pass state |
|---|---|---|---|
| 1 | **Environment torn down** (this demo opens cold) | `az group list --query "[?starts_with(name,'mls-rg-')]"` | Empty — the cold open depends on it |
| 2 | **Tenant objects intact** | quick re-run of `verification/layer-03-audit.ps1` + `layer-04-audit.ps1` | PASS — rebuild will no-op through L2–L4 as rehearsed |
| 3 | **Capacity state known** | trial: confirmed active trial window; paid F2: `Paused` now, **G2 filed** for the rebuild's resume (the rebuild resumes it — do not resume manually) | Recorded |
| 4 | **Seed data contract verified** (from the last green cycle) | last `verification/reports/L05-*.md` shows `launches = 1,200` and table set green | PASS report ≤ 7 days old |
| 5 | **vuln-lab re-armed** (both tracks) | `pwsh apps/vuln-lab/reseed.ps1` → PR merged; `gh api .../dependabot/alerts` and `gh api .../code-scanning/alerts` both show seeded alerts `open` | ≥ 3 open Dependabot alerts **and** ≥ 1 open CodeQL alert on `apps/vuln-lab/` |
| 6 | **Agent published and answering** | Copilot Studio shows the agent published from the last pipeline import; ask one golden question in the control tower's **Ask** tab (off the record) | Answer + Adaptive Card rendered; note which path is live — Fabric data agent or tools-only |
| 7 | **All layer audits green** | latest `verification/reports/L*.md` set | All PASS, ≤ 7 days old |
| 8 | **Budget headroom** | Azure portal → Cost Management → budget `$75/month` | < 80% consumed, no unacknowledged alerts |
| 9 | **Browser prepped** | tabs: Azure portal (Resource groups + Cost analysis), GitHub Actions, GitHub Security (**Code scanning** and **Dependabot** views), launch-ops URL placeholder tab, control-tower URL placeholder tab (Ask + Dev/Sec/Ops all in this one), Copilot Studio (for the "here's the agent, in a solution, in the repo" beat), compliance-board URL placeholder tab | Logged in, MFA done — never authenticate on stage, with **one deliberate exception: do not pre-authenticate the compliance board.** Its Easy Auth redirect is a beat in Segment 8 |
| 10 | **Fallback pack** | screenshots of every showpiece state + the last committed `rebuild-proof.md` | On local disk |
| 11 | **Compliance board serves the current snapshot** | open the board, read its "Collected `<date>` from commit `<short>`" line and compare with `git log -1 --format=%h -- compliance/state/` | The two match. If they differ the image predates the latest collection — re-run `app-compliance-ci.yml`, which is path-filtered on `compliance/state/**` precisely so this cannot happen quietly |

Notes for step 5: re-seed at T-60, not earlier in the week — freshly-open alerts make
the self-healing segment's timestamps read cleanly ("this alert appeared an hour
ago"). Steps 3–4 exist because the three classic demo-killers are a paused capacity,
a broken seed, and an un-armed vuln-lab.

Note for step 6: this replaces the old LLM-key check, and it is doing more work than that
one did. It confirms three things at once — the agent is *published* (an unpublished
agent has no Direct Line surface), the Direct Line secret in Key Vault is still good, and
the MCP server's FQDN in the agent still resolves (the one thing a rebuild can quietly
break). If the estate was rebuilt since the last demo, do not skip this.

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
5. **The compliance platform's source (3 min, optional — plants Segment 8):** open
   `compliance/` in the editor: `catalog/nist-800-171r2.json` (110 requirements, reference
   data, asserts nothing about this estate), `assessment/` (nineteen authored records),
   `lib/MlsCompliance.psm1` (the pure derivation — no file, no clock, no environment) and
   `state/state-latest.json` (the committed artifact the board renders). One line to land:
   "The board you'll see later has no backend. It renders that file, and that file is in
   git." Skip this if the rebuild is running hot — Segment 8 stands on its own.
6. **Watch the board (remainder):** return to Actions periodically; narrate layers
   going green; when L7 completes, load `launch-ops` and `control-tower` into the
   placeholder tabs and warm them (one request each — absorbs the scale-from-zero
   cold start off the record). When L8 completes, **warm the agent too**: open the Ask
   tab and send one throwaway question (~2 min). This opens the Direct Line conversation
   and wakes the MCP container from zero replicas, so the first question the audience
   sees is not the slowest one of the day. This is the beat that replaced the old
   app-switch between the copilot UI and the control tower.
- **Timing hinge:** when `infra-up.yml` completes and the Verifier's synchronous
  audits are green, show the wall-clock number, then move on. If the rebuild is
  still running at T+55 of this segment, keep touring — the showpieces need L8
  green.

## Segment 4 — Rebuild confirmed + self-heal trigger (5 min)

- Show the run summary: all layers green, wall-clock < 60 min (cite the
  `rebuild-proof.md` from L11 for the formally measured proof).
- **Arm showpiece #3 now** so it completes while you present the other two: the
  vuln-lab alerts from pre-demo step 5 are open; show `self-heal.yml` already running
  (or trigger the chain's next step if it has been idle-held): "Three known-vulnerable
  dependencies and one genuinely unsafe code path are live in this estate. The pipeline
  noticed. We'll come back to what it did about them."
- Say the timing honestly if asked: Copilot Autofix generation is asynchronous with no
  published SLA, which is exactly why it is armed here and closed out in Segment 7
  rather than run live in front of the audience.

## Segment 5 — Showpiece #1: the copilot (10 min)

**Stage picture:** `control-tower` full screen, **Ask** tab. Say what it is before the
first question, in one sentence: "This is a custom **Copilot Studio** agent, embedded in
our own app over Direct Line. It is not a chatbot we hand-rolled — it's a Microsoft
platform agent, and it lives in this repo as a Power Platform solution."

- **Canonical question (the anchor):** type

  > "Which day of the week has the most launches?"

  Expected on stage: the answer **Saturday**, rendered as a bar-chart **Adaptive Card**.
  Beat: "That answer came back as declarative Adaptive Card JSON — Microsoft's own UI
  contract. The agent never writes UI code. Our renderer draws the app's dashboards; the
  agent hands back a card. Either way, generated markup never reaches a browser."
- **Where the answer came from** — say whichever is true today, and be straight about it:
  - *Fabric data agent path:* "Fabric turned that English into SQL against the lakehouse
    itself — native NL2SQL over OneLake, read-only by design. That integration is in
    preview, and I'll say so rather than pretend."
  - *Tools-only path:* "That went through our MCP server — the same five tools, running
    SQL this repo owns, against the lakehouse SQL analytics endpoint. The Fabric data
    agent needs a paid F2 capacity; we're on the trial, so we're on the fallback the
    playbook documents. The answers are identical either way — the eval suite proves it."
- **Cross-domain follow-ups (pick 2–3, all from the golden eval suite so answers
  are pinned):**
  - "Which day of the year has the most scrubs?" (golden answer per the eval
    fixture — cross-checks the scrub-cascade messiness)
  - "What did the `launch-ops` app cost us last week?" (exercises
    `get_cost_series` — FinOps tool)
  - "Any critical security findings right now?" (exercises
    `get_github_security` — segues to showpiece #3)
- **The repo beat (30 s, optional but strong):** flip to the Copilot Studio tab and show
  the agent, then flip to `infra/copilot-studio/` in the repo. "Same agent. The pipeline
  exported it, we review it in pull requests, the pipeline imports it. If someone edits
  it in the browser, the auditor fails the layer."
- Close: five tools, allowlisted, audited — "the Verifier re-derives every one of those
  numbers from the lakehouse itself, independently, and compares. Nine of ten golden
  questions minimum, p95 under 20 seconds." Cost line if asked: "one cent per credit,
  pay-as-you-go on the same Azure subscription, and nothing at all while nobody's
  asking."

## Segment 6 — Showpiece #2: control tower (10 min)

**Stage picture:** same browser tab, now walking the three posture tabs — framed on
Well-Architected pillars. No app switch and no cold start: you are already here, which is
itself the point worth making — "the copilot isn't a separate product, it's a tab."

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

**Stage picture:** GitHub — Security tab + the heal PRs.

Walk the trails armed in Segment 4. There are **two**, because GitHub heals the two
finding kinds two different ways, and showing both is the honest version.

**Track A — the code fix, by Copilot Autofix (V10.1, ~6 min).** Lead with this one; it is
the newer and better story.

1. The **code scanning** alert — a real unsafe code path CodeQL found in
   `apps/vuln-lab`.
2. The fix **GitHub's AI wrote**: show the Autofix suggestion and its explanation on the
   alert. Beat: "We did not write this fix, and we did not write the thing that wrote it.
   Our pipeline asked GitHub's Autofix API for a patch, committed what came back to a
   branch, and opened a PR. This is free on public repositories."
3. The PR: head commit is the Autofix commit; the body carries Autofix's own explanation.
4. The CI gauntlet on the PR: CodeQL, tests, Trivy, ZAP — all green.
5. Merged by `github-actions[bot]` — auto-merge on green; no human clicked merge.
6. The new container revision deployed.
7. The alert: state **fixed**, closed by the deploy.

**Track B — the dependency fixes, by Dependabot (V10.2, ~3 min).** Faster, familiar,
and it makes the coverage point.

- Three known-CVE pins → three Dependabot patch PRs, raised unassisted → same gauntlet →
  auto-merged → alerts closed on merge. "Autofix handles code findings; Dependabot
  handles dependency findings. We wired both into one gauntlet rather than pretending one
  tool does everything."

- Closing beat (~1 min): "No approval prompt anywhere in either trail — inside this demo
  environment, that's deliberate. The PR trail *is* the human oversight. And note what we
  removed: there used to be a bespoke AI triage script here. Deleting it made the demo
  more enterprise-real, not less."
- If a chain is still mid-gauntlet, show the completed chain from pre-demo rehearsal
  alongside the live one in flight — an in-flight chain is itself a good stage picture.
- If Autofix declined this alert (it is documented as non-deterministic and it does
  refuse some findings), say so and lean on Track B plus the rehearsal screenshots. A
  demo that admits an AI declined is more credible than one that never shows the edge.

## Segment 8 — Showpiece #4: the compliance board that isn't green (10 min)

**Stage picture:** a new browser tab, the compliance board (`mls-compliance-demo-ca`).
You will be asked to sign in — let the audience watch that happen.

This is the segment that answers the question the room actually has to answer to its own
auditors, and the only one whose punchline is a **bad-looking screen**. Set that up
before you open it, in one sentence:

> "Showpiece #3 proved we can fix a vulnerability. This one asks a harder question: can
>  this estate stand up against a standard? I'm going to show you a compliance dashboard
>  that is mostly not green, and I'd like you to notice that that's the feature."

**1. Open on the honest board (3 min).** Sign in — "that redirect is Container Apps Easy
Auth. This board is human-facing, but a NIST control-family board is not something to
leave anonymously reachable, and the app itself has no auth code: it's a static bundle
behind a platform gate."

Then land the four numbers, in this order:

- **110 requirements** — NIST SP 800-171 Rev 2, every one of them present. "Nothing is
  omitted. A requirement nobody has said anything about is on this board as
  `NOT_ASSESSED`, not missing from it."
- **95 of the 110 are `NOT_ASSESSED`.** Say why plainly: the register covers only the
  controls a real pre-publication security review raised findings against.
- **Zero are `COMPLIANT`.** This is the beat. "Not one. And that is not because this
  estate is badly built — it's because *nothing here has been deployed*. There is no
  tenant behind this board today. Watch what it says about itself."
- Point at the collector panel and read the `verification-suite` line **out loud**:
  *"Nothing in this estate has been deployed, so there are no reports to read."*
  "The tool told you the most damaging thing about its own data, on its own front page,
  without being asked."

Then the line that makes the whole segment land:

> "Every compliance product you've been shown this year was demoed against a
>  purpose-built happy path. If I ran one of those against this estate it would show you
>  green boxes, because most of them will render a green box for a control nobody ever
>  checked. This one structurally cannot."

**2. The provenance cross-tab (2 min).** Show *By provenance and status*. Fifteen
controls carry a status; all fifteen are `asserted`, none `machine-verified`.

- "`asserted` means a human wrote it down and this platform checked nothing. That is a
  weaker claim, so it gets a different word, in a different column."
- "The strongest thing a human is allowed to write in our register is `CLOSED` — *no
  known open finding stands against this control*. That is not the same as *the control
  is met*, so it derives to `PARTIAL`, never to `COMPLIANT`. `COMPLIANT` is reachable
  from a machine-checked criterion and nowhere else. That's a property test, not a
  code-review convention."
- If someone asks for the percentage — and someone will — this is the strongest answer
  in the demo: **"There isn't one, deliberately, anywhere in the artifact or the UI. A
  single number blending fifteen controls a human asserted with ninety-five nobody
  looked at is the number you'd put in front of an auditor, and it's the number that
  would be wrong. Counts by status, counts by provenance, and the cross-tab of the two.
  That's it."**

**3. Drill into a gap (3 min).** Click a `GAP` row — **`3.1.5` (least privilege)** is the
best one on stage.

- The detail panel shows the derived status, the provenance, the working the derivation
  returned (`statusBasis`), the authored recommendation *verbatim*, and the evidence
  references into `compliance/findings/2026-08-26-prepublication-review.md`.
- "Every one of those citations is a line in a real finding from a real pre-publication
  security review of this repository — 24 findings, with severity, `file:line` and the
  attack path. The compliance record doesn't paraphrase it; it points at it, in git."
- Flip the framework switcher to **CMMC 2.0** for one beat: "Same 110 records,
  relabelled. CMMC Level 2 *is* 800-171 Rev 2 — an identity mapping, not a crosswalk we
  invented. The 800-53 mappings ship as Appendix D of 800-171 itself."

**4. Ask the agent about it (1 min).** Switch to the control tower's **Ask** tab and type:

> "What's our status on NIST 3.1.5, and what would close it?"

- The agent calls `query_compliance` — the sixth tool on the same MCP server — and reads
  back the **authored** recommendation. "It is not writing compliance advice. It is
  quoting the record. Confident wrong compliance advice is the worst failure mode
  available to a system like this, so the tool hands the agent authored text and the
  agent's instructions tell it not to extrapolate."
- The answer carries the whole estate's counts alongside the one control, so a narrow
  question never hides the wider picture.

**5. The trend — and what it honestly shows today (1 min).** Open the **Trend** tab.

- **Say what is actually on the screen.** On a fresh estate it reads: *"One collection so
  far… A trend needs at least two dated collections to compare against each other — this
  is one collection, no trend yet, not an empty chart and not an error."* Read it out.
  "Same discipline as the rest of the board: it would rather tell you it has one data
  point than draw you a line."
- Then show where the trend *comes from*, which is the part that survives scrutiny:
  `git log compliance/state/` in the terminal. "Every collection is a committed JSON
  artifact in this repository. So 'when did we become compliant, and when did we
  regress' has a `git log` answer, which is not something most GRC tooling can say. Once
  the nightly job has run twice this tab draws it — and every transition it draws is a
  commit you can `git show`."
- Closing beat: "And when this estate *is* deployed, the numbers here move for exactly
  one reason: the Verifier's audit reports start landing in the repo and the collectors
  read them. Deploying doesn't make the board greener. Being auditable does."

**If a segment has to be cut for time, this is not the one to cut.** It is the only one
whose subject is the audience's own compliance obligation, and the only one that gets
stronger the more sceptical the room is.

## Segment 9 — The kill demo + idle-cost view (8 min)

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

## Segment 10 — Q&A buffer (10 min)

Likely questions and where the receipts live:

- *"What does this cost for real?"* → master plan cost envelope table; worst-case
  ≈ $40–60/month in-trial with 4 demo days + weekly rebuilds. The agent adds ≈ $1–3 per
  demo day and **$0 idle** — Copilot Credits at a cent each, billed to this same Azure
  subscription.
- *"What's licensed vs free?"* → `docs/runbooks/g0-bootstrap.md` § B (E3 vs E5
  table, plus the Copilot Studio licensing findings — authoring is licence-free via the
  *Copilot Studio authors* role; the "free maker licence" is the trap, because it
  requires buying a credit pack first).
- *"Is any of this preview?"* → yes, one thing, and it is named in the risk register:
  the **Fabric data agent → Copilot Studio** integration. Microsoft validated that
  combination for Teams, not for a Direct Line embed. The playbook carries a tools-only
  fallback that answers the same questions, and the eval suite pins both paths to the
  same golden answers.
- *"Where does the AI in the pipeline come from — did you build it?"* → no: GitHub
  Copilot Autofix and Dependabot, both GitHub platform features, both free on a public
  repo. There is no LLM API key anywhere in this system.
- *"What if the auto-merge merges something bad?"* → the gauntlet is the gate;
  revert PRs ride the same gauntlet (L10 playbook, Rollback).
- *"How do I know the agent team didn't rubber-stamp itself?"* → Verifier's
  separate read-only credential (`mls-verifier`), committed audit reports, and the
  two-failure G4 escalation rule.
- *"So what percentage compliant are you?"* → **there is no such number, on purpose.**
  Counts by status and by provenance, and the cross-tab of the two. A figure blending
  fifteen controls a human asserted with ninety-five nobody has looked at is the number
  you would quote to an auditor and the number that would be wrong. CI greps the emitted
  bytes for a score-shaped field and fails the run if one appears
  (`.github/workflows/compliance.yml`).
- *"Are you claiming this estate is 800-171 compliant?"* → no, and the board will not let
  us. Zero controls are `COMPLIANT`, nothing has been deployed, and the strongest word in
  our register — `CLOSED` — means only *no known open finding stands against this
  control*, which derives to `PARTIAL`. `compliance/README.md` § **Register vocabulary**
  is the written contract for that distinction.
- *"Where did the gaps come from — are they made up?"* → a real pre-publication security
  review of this repository: 24 findings with severity, confidence, `file:line`, attack
  path and fix, in `compliance/findings/2026-08-26-prepublication-review.md`. Sixteen of
  the nineteen register records now assert `CLOSED`; three are still open, and they are
  the three `GAP` rows on the board.
- *"Could I run this against my own estate?"* → the collectors are pluggable and the
  catalog is reference data, so yes in shape — but read `L12.md` first: it states which
  leg of its deploy/teardown/audit triplet is missing (there is no
  `verification/layer-12-audit.ps1` yet), rather than letting you find out later.

---

## Variant B — condensed (~60 min, no live rebuild)

For short slots: run `up.ps1` before the audience arrives (T-90), verify audits
green, and replace Segments 2–4 with a 7-minute walkthrough of the committed
`verification/reports/rebuild-proof.md` — the wall-clock evidence stands in for the
live wait. Cold open still works: show the *proof report's* down-state audit
instead of a live empty subscription, or open on the built environment and lead
with the kill demo, rebuilding after the audience leaves. Segment budget: cold
open/proof 7, copilot 10, control tower 10, self-heal 10, compliance 10, kill + idle
cost 8, Q&A 5. The full-proof Variant A is the stronger show whenever the slot allows —
the rebuild wait, narrated well, is the credibility.

Two Variant-B-specific notes since the amendment: (a) warm the agent during the T-90
setup, not on stage — the Ask tab's first question after a rebuild is the slowest of the
day; (b) arm the self-heal chain at T-90 too, because Autofix generation is asynchronous
and a condensed slot has no shock absorber to wait in. If the chain has not completed by
showtime, run Segment 7 off the rehearsal trail and say so.

A third note since 2026-08-26: **Segment 8 is the cheapest segment to run in Variant B**
and the one to protect if the slot shrinks further. It needs no rebuild, no warm-up and
no asynchronous chain — the board renders an artifact that was baked into its image at
build time, so it is as fast on a cold estate as on a warm one. If the slot cannot fit
both, cut Segment 6 (control tower) to five minutes rather than cutting this.

# Demo Script — Meridian Launch Systems

> ## THIS SCRIPT CAN BE PERFORMED — as **Variant B**, on the live estate (2026-09-17)
>
> The box that stood here was written **2026-09-01** and said the demo could not be run at
> all. Three of its five rows were false by 2026-09-03 and it was never revised, so the
> warning outlived the condition and became the thing to distrust. Kept honest instead:
>
> | Showpiece | State, and when it was last measured |
> |---|---|
> | **#1 Copilot / Ask tab** | ✅ The eval grades **9/10** (bar 9, `unobservable: 0`) over Direct Line, `layer-08-copilot-studio` run `35166952968`, 2026-09-17 00:37Z. It now answers from **two clouds and says which is which** |
> | **#2 Control tower** | ✅ **V7.1–V7.7 all PASS**, run `35160458879`, 2026-09-17 00:38Z — including V7.6, *the data API answers with rows, not a status code* |
> | **#3 Self-healing** | ✅ **V10.1–V10.4 all PASS**, run `35172433866`, 2026-09-17 01:56Z. It failed an hour earlier on F203 and is green again; see § *If showpiece #3 is red on the morning* |
> | **#4 Compliance board** | ✅ Platform green — **V12.1/2/4/6 PASS**, run `35168252498`. The *content* is thin (0 machine-verified of 110) and that is the segment's argument, not its defect |
> | **#5 Cross-cloud lakehouse** | ✅ New 2026-09-16, and not in the original script at all. **V8.6 + V8.7 PASS.** See § *Segment 5b* |
>
> **The one thing this script can no longer do unrehearsed is Variant A.** The estate is
> **up** — **29 resources across the four teardown RGs plus `mls-rg-identity` outside them**,
> rebuilt 2026-09-21 — so the cold open in
> Segment 1 and the live rebuild in Segment 2 would need a teardown first, and the
> cross-cloud link **has now survived one** — V8.6 and V8.7 passed on the 09-21 rebuild,
> which the 09-17 readiness page predicted would degrade to SKIP. Run **Variant B** and keep
> the kill demo at the end, where it already is.
>
> *Corrected 2026-09-22. The sentence this replaces said the link had never survived a
> teardown, which was true when written and is the demo's strongest single upgrade since.*
>
> See [docs/DEMO-READINESS.md](../DEMO-READINESS.md), refreshed 2026-09-22. Revise
> this box when a row changes; do not delete it because it is flattering, either.


The stage flow a presenter follows, end to end: cold open on an empty subscription,
rebuild kickoff, the showpieces in order, and the kill demo with the idle-cost
view. Audience: launch-industry engineering/security/ops leaders — the narrative is
"the repo is the product; the environment is a build artifact."

Total stage time: **~120 minutes** for the full cold-start proof (Variant A) — 105, plus
the ten-minute compliance segment added with showpiece #4 on 2026-08-26, plus the
five-minute cross-cloud segment added 2026-09-17. A **~65-minute** condensed variant (B) is
at the end for slots that cannot absorb a live rebuild, **and it is the one being run on
2026-09-17** — it now carries a running order rather than a paragraph of substitutions. All
timings are [derived] estimates — the master plan pins only the <180-minute rebuild; segment
budgets follow from it.

> **On "the four showpieces".** `docs/BRIEF.md` commits to four. There are now **five**
> things worth showing: the fifth is the **cross-cloud lakehouse link** (Segment 5b), which
> the brief never described because it did not exist. It is not a replacement for any of the
> four and it is not in the brief's scorecard — say so if asked rather than quietly counting
> to five.

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

## Pre-demo checklist — **VARIANT B, live estate** (T-45 → T-0, off stage)

**This is the one to run on 2026-09-17.** The Variant A checklist below it opens on a torn
down subscription and does not apply. Times are measured, not estimated.

**Step 0 — resolve the URLs. Do this first; everything below needs them.**

```bash
az containerapp list -g mls-rg-apps \
  --query "[?properties.configuration.ingress.fqdn].{app:name,url:properties.configuration.ingress.fqdn}" -o tsv
```

**No URL is written down in this file on purpose.** The Container Apps domain suffix
regenerates on every rebuild, so a stored FQDN is wrong the first time the estate is
rebuilt and *looks* right until someone clicks it — that is F129's class, and it has
already cost this project a shipped image that could not reach its own token endpoint.
Derive them, paste them into the browser tabs in step 9, and do not commit them back here.

That command returns **five** rows. Only **four are browsable** — `mls-data-api-demo-ca`'s
FQDN carries an **`.internal.`** segment and is reachable only from inside the Container
Apps environment, which is deliberate (it is the app the dashboards proxy to server-side).
*Corrected 2026-09-22: this sentence used to end "`mls-vuln-lab-demo-ca` has no ingress at all and does not appear", which implied that app exists. It does not — PR #255 deleted it and its workflow on 2026-09-07. Five apps is the whole estate.* Verified against the live estate 2026-09-22: the command returns exactly these five, and only `mls-data-api-demo-ca` carries `.internal.`.

| # | Check | How | Pass state |
|---|---|---|---|
| 1 | **The estate is up and is the estate you think it is** | `az containerapp list -o table` | **5/5 `Running`**: compliance, control-tower, data-api, launch-ops, mcp. *Corrected 2026-09-22: this said **6/6** including `vuln-lab` until the 09-21 rebuild made the drift visible. There is no `vuln-lab` container — L10 stopped needing a witness when PR #237 retired the seeded-CVE plant. `apps/vuln-lab` the **source directory** is still in the repo and still carries its three policy-excluded alerts (row 7); only the deployment is gone* |
| 2 | **Every app is on a `sha-` tag, not `:latest`** | `az containerapp list --query "[].{n:name,i:properties.template.containers[0].image}" -o tsv` | Every image ends `:sha-<7>`. A `:latest` anywhere means an L7 deploy has erased the commit provenance V10.2 reads — **that is F203, and it turns showpiece #3 red about four hours later.** Do not run `layer-07-apps.yml` on demo morning |
| 3 | **Warm the two browser apps** — this is not optional | `curl -so /dev/null -w '%{time_total}\n' https://<control-tower-fqdn>/` twice | First call **~23 s**, second **~0.15 s** (measured 2026-09-17 01:55Z). A **401 is the correct answer** to curl — Easy Auth challenges a client that sends no `Accept` header. You are warming the container, not testing auth |
| 4 | **Warm the agent** — the single biggest stage risk | Ask tab, one throwaway question | The eval's **p95 is 34.18 s against V8.5's 20 s budget**, driven entirely by an un-warmed first question. Spend it off the record |
| 5 | **Confirm the 7th MCP tool is ON, by arithmetic** | Ask: *"how many rows are in the launches table?"* | The answer must contain **two** numbers: **1,200** (Fabric) and a second, far larger one from AWS — **334,296 when measured 2026-09-22**. **Check that the AWS number is not 1,200, not that it equals any particular figure**: the AWS table is live and growing, so a literal expected value goes stale between rehearsal and stage. **1,200 alone means the AWS tool is switched off in Copilot Studio** — that is **F202**, and neither the tool count nor the orchestration setting distinguishes it from a working one. Only the numbers do. Fix: Copilot Studio → toggle every tool on → **publish** |
| 6 | **MCP server itself is healthy** | `curl -s https://<mcp-fqdn>/healthz` | `"tools":7`, `"auth":{"enforced":true}`, and `AthenaLakehouseSqlBackend` among the adapters. **Ignore the container's own startup log, which says `5 tools`** — that is F215, a diagnostic that lies in exactly the place you would look |
| 7 | **Alert surface is readable** | `gh api repos/:owner/:repo/dependabot/alerts` | Four open: `esbuild` (low, root) and three in `apps/vuln-lab` excluded by policy. **An empty backlog is a PASS for the demo, not a gap** — the story is the operations cycle |
| 8 | **Compliance board serves the current snapshot** | Open the board, read its *Collected `<date>` from commit `<short>`* line; compare `git log -1 --format=%h -- compliance/state/` | The two match. If they differ, the image predates the collection — re-run `app-compliance-ci.yml` |
| 9 | **Browser prepped** | Tabs: Azure portal (Resource groups + Cost analysis), GitHub Actions, GitHub Security (Code scanning **and** Dependabot), control tower (Ask + Dev/Sec/Ops), Copilot Studio, compliance board | Logged in, MFA done — never authenticate on stage, with **one deliberate exception: do not pre-authenticate the compliance board.** Its Easy Auth redirect is a beat in Segment 8 |
| 10 | **Fallback pack** | Screenshots of every showpiece + the latest rebuild figures | On local disk. The current cycle is **2026-09-21** — teardown 30m51s, rebuild 152.2 min; 2026-09-03's ~14 min / 87 min is the older one. Both are history, not current state — say which one you are citing. *Note `verification/reports/rebuild-proof.md` does not exist (see `kill-rebuild.md` § 9); § Variant B row 1 and `kill-rebuild.md` § 5 are where the figures actually live* |

**What is deliberately NOT on this list:** re-seeding `apps/vuln-lab` (retired by PR #237;
re-arming it is F190), and resuming a Fabric capacity (none exists, so nothing is on the
paid path and no G2 is pending).

### If showpiece #3 is red on the morning

Check it rather than assume it: `gh run list --workflow=self-heal.yml --limit 1`, then read
the **criterion table** in the `verify L10` job, not the job's status. If V10.2 reports
*"could not establish whether the running image carries this heal"*, the cause is item 2
above — an app is on `:latest`. The heal chain is not broken; the estate changed underneath
the criterion. `self-heal` runs at **01:13, 07:13, 13:13 and 19:13 UTC**, so a morning slot
has already had two chances; `gh workflow run self-heal.yml` forces another in ~3 minutes.

---

## Pre-demo checklist — **VARIANT A, cold open** (T-60 → T-0, off stage)

*For the full cold-start proof only. Not the 2026-09-17 run.*

Run through in order; every box must be checked before the audience sits down.

| # | Check | How | Pass state |
|---|---|---|---|
| 1 | **Environment torn down** (this demo opens cold) | `az group list --query "[?starts_with(name,'mls-rg-')].name"` | Exactly `["mls-rg-identity"]` — *corrected 2026-09-22: this expected the list to be empty, which it cannot be. `mls-rg-identity` (one managed identity, behind the cross-cloud AWS link) sits outside the teardown's four-group list by design. An empty result would mean something deleted more than `down.ps1` does* |
| 2 | **Tenant objects intact** | quick re-run of `verification/layer-03-audit.ps1` + `layer-04-audit.ps1` | PASS — rebuild will no-op through L2–L4 as rehearsed |
| 3 | **Capacity state known** | trial: confirmed active trial window; paid F2: `Paused` now, **G2 filed** for the rebuild's resume (the rebuild resumes it — do not resume manually) | Recorded |
| 4 | **Seed data contract verified** (from the last green cycle) | last `verification/reports/L05-*.md` shows `launches = 1,200` and table set green | PASS report ≤ 7 days old |
| 5 | ~~**vuln-lab re-armed**~~ **RETIRED — do not re-seed** | The plant is removed by the sponsor-approved design of 2026-09-05 (PR #237); re-arming is F190. Instead confirm the chain has real findings to work with: `gh api .../dependabot/alerts` and `gh api .../code-scanning/alerts` | Alert surface **readable** (a denial must never read as "nothing to heal" — V10.3). Zero open findings is a PASS for the demo, not a gap: the story is the operations cycle, not a planted CVE |
| 6 | **Agent published and answering** | Copilot Studio shows the agent published from the last pipeline import; ask one golden question in the control tower's **Ask** tab (off the record) | Answer + Adaptive Card rendered; note which path is live — Fabric data agent or tools-only |
| 7 | **All layer audits green** | latest `verification/reports/L*.md` set | All PASS, ≤ 7 days old |
| 8 | **Budget headroom** | Azure portal → Cost Management → budget `$75/month` | < 80% consumed, no unacknowledged alerts |
| 9 | **Browser prepped** | tabs: Azure portal (Resource groups + Cost analysis), GitHub Actions, GitHub Security (**Code scanning** and **Dependabot** views), launch-ops URL placeholder tab, control-tower URL placeholder tab (Ask + Dev/Sec/Ops all in this one), Copilot Studio (for the "here's the agent, in a solution, in the repo" beat), compliance-board URL placeholder tab | Logged in, MFA done — never authenticate on stage, with **one deliberate exception: do not pre-authenticate the compliance board.** Its Easy Auth redirect is a beat in Segment 8 |
| 10 | **Fallback pack** | screenshots of every showpiece state + the latest rebuild figures (`kill-rebuild.md` § 5 — **not** `rebuild-proof.md`, which has never been committed) | On local disk |
| 11 | **Compliance board serves the current snapshot** | open the board, read its "Collected `<date>` from commit `<short>`" line and compare with `git log -1 --format=%h -- compliance/state/` | The two match. If they differ the image predates the latest collection — re-run `app-compliance-ci.yml`, which is path-filtered on `compliance/state/**` precisely so this cannot happen quietly |

Notes for step 5: ~~re-seed at T-60~~ — **do not re-seed at all.** The plant is retired
(PR #237). Do not manufacture a finding to demo against: the segment's story is the
operations cycle — *no findings; one arrives; it is healed; back to no findings* — and an
empty backlog demonstrates that, where a planted CVE only ever demonstrated the plant. If
a real finding happens to be in flight, show it; if not, show the trail of the last one. Steps 3–4 exist because the three classic demo-killers are a paused capacity,
a broken seed, and an un-armed vuln-lab.

Note for step 6: this replaces the old LLM-key check, and it is doing more work than that
one did. It confirms three things at once — the agent is *published* (an unpublished
agent has no Direct Line surface), the Direct Line secret in Key Vault is still good, and
the MCP server's FQDN in the agent still resolves (the one thing a rebuild can quietly
break). If the estate was rebuilt since the last demo, do not skip this.

---

## Segment 1 — Cold open: the empty subscription (5 min)

**Stage picture:** Azure portal, Resource groups blade, filtered to `mls`.

- Show: one resource group, `mls-rg-identity`, holding a single managed identity.
  "This is the entire Azure footprint of Meridian Launch Systems right now — one
  identity, no compute, no data plane. Idle cost: under five dollars a month —
  OneLake storage, log retention, a Key Vault."
  *Corrected 2026-09-22: this said "zero resource groups", and the blade filtered to
  `mls` will not show zero. Claiming zero while one is on the screen behind you is a
  worse opening than the truth, which is a stronger line anyway — the one thing that
  survives is an identity, which is exactly the persistence point made two bullets down.*
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

- Show `infra-up.yml` fan out in the Actions graph. Call the shot: "Under three
  hours from nothing to fully verified — the last measured cycle was two and a half
  — an independent auditor agent signs off every layer against the live APIs, and
  we'll check its wall-clock report at the end."
  *Corrected 2026-09-22: this said "under sixty minutes", which no cycle has ever
  achieved (87 min on 09-03, 152.2 min on 09-21) and which the sponsor replaced with
  a 180-minute gate the same day. Calling the old shot on stage guarantees the
  wall-clock reveal at the end of Segment 4 contradicts you in front of the room.*
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

- Show the run summary: all layers green, wall-clock < 180 min (cite the run's own
  V11.4 line for the formally measured proof — **not** `rebuild-proof.md`, which L11
  still owes and has never committed; see `kill-rebuild.md` § 9).
- **Showpiece #3 needs no arming — that model was retired (PR #237).** There is nothing to
  plant and nothing to trigger: `self-heal.yml` runs on a schedule (01:13 / 07:13 / 13:13 /
  19:13 UTC) over whatever the repository's **real** backlog holds. Show the most recent run
  and say: "That is not a fixture. It is the actual finding backlog for this repository,
  judged against SLOs declared in a file in the repo. We'll come back to what it did." If
  you want a run mid-gauntlet on stage, `gh workflow run self-heal.yml` at this point.
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
  - *Tools-only path (**this is the live path today** — `mcp-tools-only`, run
    `35166952968`):* "That went through our MCP server — **seven tools**, running SQL this
    repo owns, against the lakehouse SQL analytics endpoint. The Fabric data agent needs a
    paid F2 capacity; we're on the trial, so we're on the fallback the playbook documents.
    The answers are identical either way — the eval suite proves it."
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
- Close: **seven** tools, allowlisted, audited — "the Verifier re-derives those numbers
  from the lakehouse itself, independently, and compares. Nine of ten golden questions
  minimum, p95 under 20 seconds." **Two honest caveats if pressed:** the last graded run
  scored **9/10** and the one it missed it missed by *declining to answer*, not by being
  wrong; and its **p95 was 34 s**, because the first question of a run pays the cold
  start — which is exactly why you warmed it at T-45. Cost line if asked: "one cent per
  credit, pay-as-you-go on the same Azure subscription, and nothing at all while nobody's
  asking."

## Segment 5b — The cross-cloud lakehouse (5 min, and it is the best five minutes)

**Stage picture:** same Ask tab. No app switch, no setup. Shipped 2026-09-16 and not in
this script before 2026-09-17.

Ask, verbatim:

> "How many rows are in the launches table?"

The agent answers **both**, unprompted, and says why:

> *"There are two different `launches` tables … Meridian's operations lakehouse
> (synthetic): **1,200** rows. AWS launch-intelligence lakehouse (real launch-industry
> data): **334,296** rows. I queried both because the question is ambiguous."*

*The AWS figure moves — it was 286,473 when this script was written and 334,296 on
2026-09-22, because that table is live and growing. **Do not memorise it and do not
correct the agent if it says something else.** The only thing that must be true on stage
is that the second number is not 1,200; see pre-demo check 5.*

Then land the three beats, in this order — the last is the one the room will remember:

1. **It is a second cloud, not a second database.** "That second number came from
   **Amazon Athena**, querying a Glue catalog in an AWS account we do not own. Nothing was
   copied. The query runs *there*; only the result rows cross."
2. **There is no AWS credential anywhere in this system.** "It authenticates by OIDC
   federation — `AssumeRoleWithWebIdentity`, an Entra-minted token traded for short-lived
   AWS credentials. The same trust model the Azure side already uses, extended across a
   cloud boundary. A repo-wide test asserts no AWS credential is stored, anywhere."
3. **The disambiguation is the product, not a flourish.** "Nobody told it the question was
   ambiguous. Both lakehouses have a `launches` table and plausible vehicle names — so the
   *only* thing that distinguishes them is the numbers. It noticed that and refused to pick
   one for you."

**What to say if asked "is this verified, or is it a demo?"** — "Two criteria. **V8.6** asserts
the AWS lakehouse returns rows rather than a status code. **V8.7** refuses to call a denial an
empty dataset, which is the specific way this estate has been lied to before. Both pass —
and both **survived a teardown and rebuild on 2026-09-21**, which is the thing that turns an
observation into a property."

> *Corrected 2026-09-22. This answer used to end "they have passed **once**, on an estate
> that has not been torn down since they existed — so today that is an observation, not yet
> a property." That was true when written and the 09-21 rebuild retired it. It is the
> strongest single upgrade to this segment, so do not read the old caveat out of habit.*

**Do not claim** the control tower's 7/7 covers this. **No L7 criterion touches AWS.** The
green board and the AWS row count are two independent facts that look like one, and merging
them on stage is the exact error this repository spends its verification budget preventing.

**Cost line if asked, and say it unprompted if the room is technical:** "Athena bills per
terabyte scanned, that spend is on the sponsor's AWS account, and **nothing in this estate
observes it.** I am not going to tell you this link is free."

## Segment 6 — Showpiece #2: control tower (10 min)

**Stage picture:** same browser tab, now walking the three posture tabs — framed on
Well-Architected pillars. No app switch and no cold start: you are already here, which is
itself the point worth making — "the copilot isn't a separate product, it's a tab."

- **Dev tab (3 min):** open vulns, dependency status, SBOM presence, PR/pipeline status.
  "Everything on this tab is the GitHub Security API, live." **Plant the callback to
  Segment 7 here** — the `apps/vuln-lab` alerts are visible on this tab and *excluded from
  the heal backlog by policy*, so if anyone asks why they are not being healed, the answer
  is on the Sec tab's own terms: excluded by declaration, with a reason, not ignored.
- **Sec tab (4 min):** Defender secure score, findings by severity, NIST 800-53
  posture from Azure Policy (audit mode — honest about it), Entra sign-in risk
  (E5 trial feature — say so; enterprise-real includes licensing-real).
- **Ops tab (3 min):** resource health, throughput/latency from App Insights,
  replica counts ("most of these say zero — that's the idle-cost story"),
  cost-per-app-over-time from the daily export → lakehouse pipeline.

## Segment 7 — Showpiece #3: self-healing close-out (10 min)

**Stage picture:** GitHub — Security tab + the heal PRs.

> **REWRITTEN 2026-09-17. The showpiece this segment described no longer exists.** PR #237
> (sponsor-approved, 2026-09-05) retired the seeded-CVE plant: `apps/vuln-lab` is a manual
> demonstration generator, excluded from the backlog by policy, and **re-arming it is F190.**
> The criteria below are also renumbered — the old script called Autofix "V10.1" and
> Dependabot "V10.2", and both labels are now wrong.
>
> **What replaced it is a better demo, and the reason is worth saying on stage:** a planted
> CVE only ever demonstrates the plant. What is shown now is the **operations cycle over the
> real backlog**, governed by `.github/self-heal-policy.json` and judged by four criteria:
>
> | | |
> |---|---|
> | **V10.1** | the backlog drains — no healable finding sits past its declared SLO, per lane and per severity |
> | **V10.2** | every closure is traceable — each finding closed in the window carries a complete heal trail, or an explicit record of being closed another way |
> | **V10.3** | the chain could actually **read** the alert surface — a denial is never recorded as "no alerts to heal" |
> | **V10.4** | `pending-solution` is not a dumping ground — nothing is parked there that an upstream fix exists for |
>
> **All four PASS** as of run `35172433866`, 2026-09-17 01:56Z.

Open on the **policy file**, not the Security tab — it is the thing that makes this a cycle
rather than an anecdote:

- Every exclusion carries a **reason**, and where it is a deferral, an **expiry**. "An
  exclusion that cannot expire is a dumping ground, so ours cannot not-expire. V10.4 is the
  criterion that enforces that, one level up."
- Name the live one: the `container-image` lane's deferral **expires 2026-10-07**, because
  ACR Tasks is not permitted on this subscription. "That date is in a file. When it passes,
  the criterion goes red by itself and somebody has to decide again."
- And the honest one: the single real Dependabot alert, `esbuild`, **reaches its 30-day SLO
  on 2026-09-27**. It is transitive with no direct pin. "This is what V10.1 is standing on,
  today, and I would rather show you the clock than a green box."

Then walk whichever trail is live. **If the backlog is empty, that is a PASS, not a gap** —
show the trail of the last closure instead and say so: *"no findings; one arrives; it is
healed; back to no findings"* is the cycle, and an empty backlog is the cycle working.

**Track A — the code fix, by Copilot Autofix (~5 min).** Lead with this one if a code
scanning finding is in flight; it is the better story.

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

**Track B — the dependency fixes, by Dependabot (~3 min).** Faster, familiar, and it makes
the coverage point.

- A real Dependabot PR, raised unassisted → same gauntlet → auto-merged → alert closed on
  merge. "Autofix handles code findings; Dependabot handles dependency findings. We wired
  both into one gauntlet rather than pretending one tool does everything."
- **Do not describe these as planted.** They are whatever the repository actually has that
  morning. If nothing is in flight, `gh pr list --author app/dependabot` and walk a merged
  one from the log.

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
- **94 of the 110 are `NOT_ASSESSED`.** Say why plainly: the register covers only the
  controls a real pre-publication security review raised findings against.
- **Zero are `COMPLIANT`.** This is the beat, and **since 2026-09-03 it is a much stronger
  one than this script used to claim.** The old line was *"that's because nothing here has
  been deployed"*. That is no longer true and it was the weaker argument anyway. Say this
  instead:

  > "Not one control is compliant. And this is not an empty estate — everything you have
  >  watched for the last hour is deployed, running, and independently audited by a
  >  read-only identity that is not the thing that deployed it. Thirty resources. Seven of
  >  seven on the control tower. Four of four on self-healing. **Still zero.** Because
  >  `COMPLIANT` on this board is reachable from a machine-checked criterion and nowhere
  >  else, and nobody has wired one to a control yet. The board will not round up for us."

- Point at the collector panel and **read what is on the screen out loud** — do not recite
  it from here, because the emitter derives that line and this script would drift from it.
  Each collector states what it could and could not observe. "The tool told you the most
  damaging thing about its own data, on its own front page, without being asked."

Then the line that makes the whole segment land:

> "Every compliance product you've been shown this year was demoed against a
>  purpose-built happy path. If I ran one of those against this estate it would show you
>  green boxes, because most of them will render a green box for a control nobody ever
>  checked. This one structurally cannot."

**2. The provenance cross-tab (2 min).** Show *By provenance and status*. **Sixteen**
controls carry a status — 15 `PARTIAL` and 1 `GAP` — all sixteen `asserted`, **none**
`machine-verified`.

- "`asserted` means a human wrote it down and this platform checked nothing. That is a
  weaker claim, so it gets a different word, in a different column."
- "The strongest thing a human is allowed to write in our register is `CLOSED` — *no
  known open finding stands against this control*. That is not the same as *the control
  is met*, so it derives to `PARTIAL`, never to `COMPLIANT`. `COMPLIANT` is reachable
  from a machine-checked criterion and nowhere else. That's a property test, not a
  code-review convention."
- If someone asks for the percentage — and someone will — this is the strongest answer
  in the demo: **"There isn't one, deliberately, anywhere in the artifact or the UI. A
  single number blending sixteen controls a human asserted with ninety-four nobody
  looked at is the number you'd put in front of an auditor, and it's the number that
  would be wrong. Counts by status, counts by provenance, and the cross-tab of the two.
  That's it."**

**3. Drill into a gap (3 min).** Click the `GAP` row — **`3.5.3`, multifactor
authentication**. There is exactly **one** GAP row on the board, and it is this.

> **Corrected 2026-09-17.** This script said to click **`3.1.5` (least privilege)** and
> called it "the best one on stage". **`3.1.5` is `PARTIAL`, not `GAP`** — F19 moved 3.1.1,
> 3.1.2 and 3.1.5 from GAP to PARTIAL when the seventh workload RBAC grant closed, and the
> enforced-MFA work added `3.5.3` as the assessed GAP. A presenter following the old text
> would hunt for a GAP row that is not there, in front of an audience.

**`3.5.3` is the better beat anyway, and here is why — get this right, it is checkable.**
The estate declares **three** Conditional Access policies. Exactly **one is `enabled`** —
`mls-ca-require-mfa-dashboards`, which really does enforce MFA, and V3.3 confirms it. The
**two that would close 3.5.3** — `mls-ca-require-mfa-admins` and `mls-ca-block-legacy-auth`
— are **deliberately `enabledForReportingButNotEnforced`**.

That is the whole segment on one row:

- "We enforce MFA on the dashboards. We have **not** enforced it on privileged accounts, and
  the board says so, in red, on an estate we built ourselves."
- "It is report-only **on purpose**. The apply script *refuses* to enable a policy without a
  validated break-glass account — because a locked-out tenant is a worse outcome than a
  report-only policy, and because an enforced admin-MFA policy on a recovery path that
  cannot recover anything is a control that is right until the day it matters."
- "So closing this is a one-word manifest edit **and a decision that belongs to whoever owns
  the tenant** — which is why it is left open rather than defaulted on."
- The authored recommendation on screen also names what *nothing here checks*: "no criterion
  asserts MFA was actually **satisfied at a sign-in**." Read that out. "That is the
  difference between a policy being configured and a second factor having been presented,
  and our own record is the thing that told you."

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

- **UPDATED 2026-09-17: the trend now draws.** This script used to say the tab would report
  *"one collection so far… not an empty chart and not an error"*, because there was one.
  There are now **fifteen dated collections**, `2026-08-28 → 2026-09-17`, all committed to
  `main`. Say what is actually on the screen — but the line to land is the **gap in it**:

  > "You can see a hole in that series — it runs 28 and 29 August, then nothing until
  >  5 September. **Six collections missing.** That is real. The nightly job was pushing its
  >  artifact to a branch and opening a pull request that could never merge, because a
  >  `GITHUB_TOKEN` push triggers no workflow runs, so no required check ever reported. The
  >  job stayed green the whole time. We found it, we fixed it, and **we left the hole in
  >  the chart**, because the chart is the record and a record you tidy up is not one."

  *Six, counted from `compliance/state/` on 2026-09-17. `DEMO-READINESS.md` calls this gap
  "nine days"; the dates missing from the series are 30 Aug – 4 Sep, which is six. Quote the
  six — it is the number on the screen.*
- Then show where the trend *comes from*, which is the part that survives scrutiny:
  `git log compliance/state/` in the terminal. "Every collection is a committed JSON
  artifact in this repository. So 'when did we become compliant, and when did we
  regress' has a `git log` answer, which is not something most GRC tooling can say. Once
  the nightly job has run twice this tab draws it — and every transition it draws is a
  commit you can `git show`."
- Closing beat — **this estate IS deployed, so say the stronger version:** "These numbers
  have not moved while everything you watched today was built, torn down, rebuilt and
  audited. They move for exactly one reason: when the Verifier's audit reports land in the
  repo where the collectors read them and a control gets wired to a machine-checked
  criterion. **Deploying doesn't make the board greener. Being auditable does** — and we
  haven't finished making it auditable, which is why it isn't."

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
- Final line: "Everything you watched exists as code. Kill it in half an hour,
  rebuild and audit it in two and a half, under five dollars a month at rest."
  *Corrected 2026-09-22: this said "under an hour". The measured cycle is teardown
  30m51s and rebuild 152.2 min (2026-09-21) against a 180-minute gate — and the
  measured numbers are the better closing line anyway, because they are the ones in
  the proof.*

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
  sixteen controls a human asserted with ninety-four nobody has looked at is the number
  you would quote to an auditor and the number that would be wrong. CI greps the emitted
  bytes for a score-shaped field and fails the run if one appears
  (`.github/workflows/compliance.yml`).
- *"Are you claiming this estate is 800-171 compliant?"* → no, and the board will not let
  us. Zero controls are `COMPLIANT` **on a fully deployed and independently audited
  estate**, and zero are machine-verified. The strongest word in our register — `CLOSED`
  — means only *no known open finding stands against this control*, which derives to
  `PARTIAL`. `compliance/README.md` § **Register vocabulary**
  is the written contract for that distinction.
- *"Where did the gaps come from — are they made up?"* → a real pre-publication security
  review of this repository: 24 findings with severity, confidence, `file:line`, attack
  path and fix, in `compliance/findings/2026-08-26-prepublication-review.md`. **Nineteen of
  the twenty register records now assert `CLOSED`; one is still open — `3.5.3` — and it is
  the single `GAP` row on the board.** (Counted 2026-09-17. This answer read "sixteen of
  nineteen … three GAP rows" until then, and was wrong in all three numbers: findings kept
  closing and the script did not.)
- *"Could I run this against my own estate?"* → the collectors are pluggable and the
  catalog is reference data, so yes in shape — but read `L12.md` first: it states which
  leg of its deploy/teardown/audit triplet is missing (there is no
  `verification/layer-12-audit.ps1` yet), rather than letting you find out later.

---

## Variant B — condensed (~65 min, no live rebuild) — **THE 2026-09-17 RUNNING ORDER**

The estate is already up, so nothing is built on stage. Run this order:

| # | Segment | Min | Note |
|---|---|---|---|
| 1 | **Cold open, from the proof** | 7 | You cannot show an empty subscription — show the figures below and the **down-state audit** instead. (**`rebuild-proof.md` is not a file you can open** — it has never been committed; see `kill-rebuild.md` § 9. Cite § 5 of that runbook, or the Actions run itself.) Be explicit which cycle the figures come from. **Most recent, 2026-09-21:** teardown **30m51s** clean, rebuild **152.2 min**, 29 → 0 → 29 in the blast radius with `mls-rg-identity` standing throughout. **2026-09-03:** teardown ~14 min, rebuild 87 min, 30 → 0 → 30 — a six-app estate, which is why the resource count differs. *History, not a live claim* |
| 2 | **Repo tour** | 8 | Compressed Segment 3: working agreements + the five gates, the agent team, `verification/reports/`, the DevSecOps chain as code. Land *"RG-scoped teardown is gate-free by design"* — it sets up segment 8 |
| 3 | **Showpiece #1 — the copilot** | 10 | Segment 5, warm |
| 4 | **Showpiece #5 — cross-cloud** | 5 | **Segment 5b. Do not cut this one.** Same tab, no setup, and it is the newest thing here |
| 5 | **Showpiece #2 — control tower** | 8 | Segment 6, trimmed. No app switch |
| 6 | **Showpiece #3 — self-healing** | 8 | Segment 7, the policy-first version |
| 7 | **Showpiece #4 — compliance** | 10 | Segment 8. **Protect this one if the slot shrinks** — no rebuild, no warm-up, no async chain |
| 8 | **Kill demo + idle cost** | 8 | Segment 9, live. This is where the credibility Variant A gets from the rebuild comes from instead |
| 9 | **Q&A** | 5 | Segment 10 |

**The kill demo carries this variant.** In Variant A the rebuild wait is the credibility;
here it is the teardown — so run it live, narrate it, and make the persistence point
properly: users, groups, CA policies and labels survive; the four resource groups do not.

> **Read this before running `down.ps1`.** *Rewritten 2026-09-22 — the rebuild this box
> asked for happened on 2026-09-21 and settled most of it.* The estate is still scheduled
> for shutdown around **2026-09-27**.
>
> **What the 09-21 cycle converted from an observation into a property:** V8.6 and V8.7
> **passed on the rebuilt estate**, so the cross-cloud link has now survived a teardown —
> the prediction below that a teardown would return both criteria to `SKIP` did not come
> true. V11.4 reported too, recording the **152.2-minute** rebuild (a FAIL against the
> then-60-minute budget, inside the 180 adopted 2026-09-22).
>
> **What this box asserted and can no longer be read as current:** that V8.6/V8.7 had never
> survived a teardown, and that "V11.3, V11.4 and V11.5 have *never reported at all*" —
> V11.4 plainly has. **Closed 2026-09-22: V11.3 and V11.5 have both reported too.** V11.3
> returned FAIL on the 09-21 up-phase (child audits could not start, F227) and PASS on the
> 09-22 re-run once they could; V11.5 returned FAIL, observing "897 consumption line items,
> none carrying a readable cost" — a real verdict, and a real gap in the cost data rather
> than a criterion that never ran. So the "never reported at all" claim is retired in full;
> all five L11 criteria have now produced verdicts. V11.5 remains next-day consumption data
> and is excluded from the rebuild clock by definition.
>
> Still true and still worth doing before any further teardown:
> 1. **Fix F203 first** (`layer-07-apps.yml` defaults `image_tag` to `latest`), *then* run
>    L7 — otherwise that L7 run re-breaks showpiece #3.
> 2. **Confirm the Key Vault grant in `infra/bicep/apps/modules/key-vault-secret-role.bicep`
>    is in the template's deploy path**, rather than assuming it. It was hand-applied when
>    this box was first written; the 09-21 passes suggest it survived, but "the thing works"
>    is not "a rebuild reproduces it", and that distinction is the one this repo keeps paying
>    for.

Two notes carried from the amendment: (a) warm the agent during setup, not on stage — the
Ask tab's first question is the slowest of the day; (b) the self-heal chain is
policy-driven now, so there is nothing to "arm" — check it is green at T-45 and show
whatever is actually in flight.

**Variant A is the stronger show whenever the slot allows** — the rebuild wait, narrated
well, is the credibility. It needs a torn-down estate at T-0, so it is a *decision made the
night before*, not a choice made on the morning.

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

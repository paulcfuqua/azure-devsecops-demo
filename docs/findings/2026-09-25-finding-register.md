# Finding register — 2026-09-25

The final teardown-and-rebuild cycle before shutdown. Continues
[2026-09-20](2026-09-20-finding-register.md) (F218–F238).

**Four findings, F239–F242.** None is broken infrastructure. Every standalone layer audit on
the rebuilt estate passed; the four are criteria that judged it wrongly, or could not judge
it at all, and three of the four are the same rule this repository keeps relearning: **an
auditor that could not see a thing must say so, in either direction.**

## The cycle, measured

| | |
|---|---|
| Teardown | `infra-down` run `36091001637`, **30.5 min** (03:35:51 → 04:06:23 UTC). V11.1 PASS, V11.2 PASS. Only `mls-rg-identity` survived, by design |
| Rebuild | `infra-up` run `36095279150`, `l11_up_audit=true`, started 04:38:52 UTC |
| **V11.4 wall clock** | **PASS — 154.5 min** against the 180-minute gate (152.2 min on 2026-09-21) |
| V11.2 tenant objects | PASS |
| Standalone layer audits | **L2 3/3 · L3 4/4 · L4 PASS · L5 PASS (1,200 rows; RLS enforces) · L6 PASS incl. V6.2, V6.7, V6.8 · L7 7/7** |
| L8 | V8.1, V8.3, **V8.6, V8.7 PASS** (the AWS lakehouse answers with rows on a rebuilt estate). V8.4 FAIL — F241. V8.5 FAIL — see below |
| V11.3 | FAIL — F239, F240 |
| V11.5 | PENDING — F242 |

**V8.5** read p95 **40.4 s** against 20 s. That is one number: the first, cold question took
40.4 s and the other nine took 5.6–10.3 s. Over ten samples p95 is the maximum, so the
criterion measures the cold start and nothing else. This is the un-warmed first-call effect
already recorded (F216), not a new finding, and warming before a demo remains mandatory.
All ten answers were correct.

---

## F239 — V11.3's child audits started, then ran without their layers' inputs, and one that saw nothing counted as green

*2026-09-25, run `36095279150`.*

F227 fixed the children that **could not start** for want of a required parameter. This
cycle they all started, and seven of ten FAILed on inputs their own layer workflows supply
and the L11 job does not:

| Layer | What the child observed |
|---|---|
| L1, L9 | `gh` exit 4, *"set the GH_TOKEN environment variable"* — the job holds `MLS_VERIFIER_GH_TOKEN`, not `GH_TOKEN`. V1.1 then retried this for its full **30-minute** window |
| L5 | `'Invoke-Sqlcmd' is not available` — SqlServer 22+ is installed by the L5 verify job, not the L11 job |
| L6 | *"Cannot bind argument to parameter 'SubscriptionId' because it is an empty string"* |
| L7 | *"no deploy manifest supplied"*, *"no canary PR number supplied"* |
| L9, L10 | no layer-09 run id; the self-heal readability value empty |

Every one of those layers had **passed** its standalone audit earlier in the same run.

**The worse half is L8.** Its child reported **8 of 8 SKIP** — no environment URL, nothing
observed — and V11.3 recorded it as **`L8=PASS`**. That is F235's shape a second time: F235
was a narrowed *set* of layers claiming the whole; this is a layer that examined nothing
claiming green. The rule is the symmetric one — an auditor that cannot see a control must not
report it present — and it held for the set and not for the member.

The job also spent **175 minutes** auditing, most of it inside retry windows waiting on
errors no retry can fix.

**Fixed in PR #329, and never exercised against a live estate.** It merged after the last
rebuild, so the first `infra-up` with `l11_up_audit=true` is its first real test.

**How V11.3 judges a layer now.** It reads each child's JSON report instead of its exit code,
and gives every layer one of three verdicts:
- **FAIL:** a criterion failed on something it read.
- **UNOBSERVABLE:** any of the following —
  - the child exited 2 or 3;
  - it produced no PASS at all (the L8 8/8 SKIP case);
  - it had no readable report;
  - its only FAILs were criteria that could not look.
- **PASS:** at least one PASS and no FAIL of either kind.

V11.3 cannot pass while any layer is UNOBSERVABLE. Its Observed line now leads with
`FAILING: … ; UNOBSERVABLE: …` and gives one short entry per layer, sized to fit the report
column even with all ten layers failing.

**What the children now receive.** The L11 job passes them what their own verify jobs get:
- `GH_TOKEN`
- the SqlServer module
- the SQL endpoint and the L6 completion time
- this run's L7 deploy manifest and L8 eval artifact
- the Log Analytics workspace id and the MCP URL, resolved as `mls-verifier`
- the MCP token

A configuration error is no longer retried. A missing tool or missing `gh` authentication
fails at once, marked unobservable, instead of spending a 30-minute window.

**A real defect surfaced on the way.** V6.7 and V6.8 read the raw `$SubscriptionId`
parameter instead of the resolved subscription, so they were blind whenever the id came from
the environment. That always happens for an L11 child. A repository-wide test now fails on
any audit that uses a raw parameter after resolving it.

**Still unobservable inside a rebuild proof, by design:**
- **V9.2–V9.4** need a `layer-09-devsecops` run, which `infra-up` does not include. Borrowing
  the latest one would be evidence from outside the rebuild.
- **V10.3** needs a self-heal run's output.
- **V7.4** needs `MLS_L7_CANARY_PR`.
- **V8.1** needs the Power Platform environment URL variable.

So V11.3 can still FAIL on these layers, but it now names them as unobservable rather than
as broken.

---

## F240 — V2.2's evidence window cannot contain a rebuild proof

*2026-09-25, same run.*

V2.2 confirms the untagged-canary policy denial by finding a `RequestDisallowedByPolicy`
event in the Activity Log **within the last two hours**. L2 wrote the canary at about 04:47
UTC; the V11.3 child ran V2.2 at 07:54. The event existed and was out of range, so the child
reported *"events matched: 0"* — a policy that denied correctly, reported as one that did not.

A fixed lookback is right for a standalone audit that runs minutes after its deploy. It is
wrong for any caller that runs later, and the rebuild proof always does. The window should
begin at the instant the evidence was produced, which the rebuild already records.

**Fixed in PR #329.** `layer-02-audit.ps1` takes `-ActivityLogStartUtc`, with
`MLS_REBUILD_START_UTC` as a fallback, and L11 passes the recorded rebuild start to every
child. The Activity Log is searched from that instant to now, with both ends explicit: given
only `--start-time`, `az` stops six hours later. A start that cannot be parsed is refused, not
silently replaced by the two-hour window. A standalone run keeps its two-hour lookback.

---

## F241 — V8.4 failed the agent for answering in prose, on ten questions whose right answer is prose

*2026-09-25, same run.*

V8.4 asserts that **every visual answer** is a valid Adaptive Card. It reported FAIL,
*"no Adaptive Card payload in any of 10 question(s)"*, with detail pointing at the agent's
answer path.

All ten golden questions ask for **a single figure** — a count, a rate, a single winner. The
agent's own instructions (rule 3) require a card for comparisons, rankings, time series,
tables or more than three related figures, and **plain text otherwise**. All ten answers were
correct, and prose was the correct form for every one of them.

The eval contains **no visual question**, so V8.4 has never had anything to observe. It
failed the agent on the absence of evidence it had no way to collect — the F102/F103/F105
class, in the criterion that F228 had already found reading the wrong fields and F233 had
found reading the wrong transport.

This is not F238. F238 is about how *often* the agent chooses a card when one is called for,
and it stands. F241 is that the eval never calls for one.

**Fixed in PR #328.** Every golden question now declares `presentation: "card" | "text"`,
and the eval records it in the artifact. All ten are `text`. V8.4's two halves are judged
separately:
- **On evidence, over every response:** any card that did arrive is validated against the
  pinned 1.6 profile, and the scan for generated HTML/JS/JSX still runs. Either failing is a
  FAIL, whatever the question declared.
- **The card requirement:** it applies only to questions declared `card`. When none was
  asked, V8.4 records **SKIP with `UNOBSERVABLE:`** and says it is not a claim that the agent
  failed. It never PASSes a requirement it did not observe.

**Still open:** V8.4 becomes observable only when a `card`-declared golden question is added.
That question has to carry `referenceSql` executed against live Fabric, because of V8.2.

---

## F242 — V11.5 cannot be measured on the last cycle an estate will have

*2026-09-25, same run.*

V11.5 — run-rate returns to the idle profile — reads consumption from **cycle + 1 day to
cycle + 2 days**, and its deadline is 2026-09-27 10:02 UTC. This rebuild was followed by the
final teardown the same day. After that, the idle profile would be measured on an estate that
no longer exists, and would pass trivially. That is the wrong evidence for the claim, so
V11.5 was **not re-run**, and remains **PENDING — never measured**.

Its one attempt timed out: `az consumption usage list` did not return within 300 s. A
measurement that needs two quiet days after a rebuild has only ever been possible on an estate
that was left running, and none was.

**Status:** OPEN, and recorded as unmeasured rather than closed.

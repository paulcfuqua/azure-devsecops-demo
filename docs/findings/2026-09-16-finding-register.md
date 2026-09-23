# Finding register — 2026-09-16 / 2026-09-17

Findings recorded on 2026-09-16 and the small hours of 2026-09-17, the day the estate
reached a **second cloud**: a live link from the Azure-hosted agent to the sponsor's real
AWS Athena lakehouse (`launch-intel`), over OIDC federation, with no data copied and no AWS
credential stored anywhere.

The earlier registers are [2026-09-03](2026-09-03-finding-register.md) (F1–F189) and
[2026-09-04](2026-09-04-finding-register.md) (F190–F200). This file continues them rather
than replacing them, and **none of the three is pruned** — including the diagnoses that
turned out to be wrong, which are the reason the archive is worth keeping.

**F201 was first written down in [`docs/DEMO-READINESS.md`](../DEMO-READINESS.md)'s blocker
tree on 2026-09-16 and is restated here in full**, because that file is a live scorecard
that gets rewritten and this one is a dated archive that does not.

| | | |
|---|---|---|
| **F201** | Dependabot's per-directory npm entries for npm *workspace members* are dead on arrival | open |
| **F202** | A newly discovered MCP tool arrives **disabled**, and a disabled tool is indistinguishable from an absent one | fixed in the runbooks 2026-09-17; the portal state is manual by nature |
| **F203** | An L7 deploy re-tags every app to `:latest` and erases the commit provenance L10's V10.2 depends on | fixed in the deploy path 2026-09-17; red in the estate until a deploy re-tags the three affected apps |
| **F204** | The ledger said three Glue tables; the live catalog had five, two of them views | fixed 2026-09-16 |
| **F205** | A *deferred minor* about deploy identity was the cause of a silent, unreportable write failure two tasks later | fixed 2026-09-16 |
| **F206** | An IAM condition on a key the service never supplies for that action granted **nothing while reading as a tighter version of itself** | caught in review |
| **F207** | `mapfile` is a bash 4 builtin; under `set -u` its absence silently discards every check after it | caught in review |
| **F208** | Two tests written into the plan were wrong in a way that would have **degraded correct code to satisfy them** | fixed in flight |
| **F209** | An HTTP 429 from `az containerapp exec` looks exactly like an empty value | fixed by classification |
| **F210** | A shell rewrites a leading-slash ARM path and the failure **names the wrong system** | closed by a repo-wide sweep |
| **F211** | Two agents in one worktree corrupted a full-suite result, not just the tidiness | closed by ruling |
| **F212** | `pac copilot publish` reports a stale publish timestamp and must never be used as evidence | open (upstream tool) |
| **F213** | The documented agent instructions had silently drifted from the shipped ones since F138 | closed by a byte-for-byte test |
| **F214** | A *filtering* reader of the tool allowlist would have broken `npm run eval` permanently, with nothing edited to show for it | caught before it landed |
| **F215** | The MCP container's startup banner logs a hardcoded tool count that is wrong | open, minor |
| **F216** | The eval that could not grade anything now grades — and the number it produced breaches a criterion nobody has run | open |
| **F217** | Root AWS credentials on the development machine make a carefully scoped IAM policy decorative | open, larger than this plan |

---

### F201 — Dependabot's per-directory npm entries for npm *workspace members* are dead on arrival *(open)*

**What happened.** `.github/dependabot.yml` declares seven npm entries naming directories
that the root `package.json` also lists in `workspaces`: `/apps/launch-ops`,
`/apps/control-tower`, `/apps/mcp-tools`, `/apps/data-api`, `/apps/directline-token`,
`/apps/cost-ingest`, `/apps/shared/spec-renderer`. A per-directory entry bumps that member's
`package.json` and **does not update the root `package-lock.json`**, which is the only
lockfile root `npm ci` reads. Every job that begins with `npm ci` then dies:

> `npm error code EUSAGE` · `` `npm ci` can only install packages when your package.json and package-lock.json … are in sync `` · `npm error Missing: @azure/monitor-opentelemetry-exporter@1.0.0-beta.45 from lock file`

**Confirmed by contrast, not by inference**, which is what makes this entry worth its space:

| PR | Dependabot entry | Files changed | Outcome |
|---|---|---|---|
| **#261** | `/apps/data-api` — a workspace member | `apps/data-api/package.json` only | 6 checks FAIL, root `npm ci` EUSAGE |
| **#262** | `/apps/mcp-tools` — a workspace member | its `package.json` + its *own* lockfile | 6 checks FAIL, root `npm ci` EUSAGE |
| **#264** | `/` — the root entry | `apps/data-api/package.json` **+ root `package-lock.json`** | **green, 24 / 0** |

**#264 is the control.** It bumps *the same package as #261* and it is green purely because
the root entry maintains the root lockfile. The per-directory entries are both redundant
with the root entry and broken; the root entry already covers every workspace member.

**Do not fold PR #263 into this** — it failed for a different, adjacent reason. #263 was the
root group bump: it correctly updated the root manifest, the root lockfile and seven member
manifests, so root `npm ci` was fine. It failed two checks because `apps/mcp-tools` carries
a **standalone** `package-lock.json` that nothing at the root maintains. The trap behind
that is documented at length in `verification/tests/lockfile-sync.Tests.ps1`'s own header:
`npm install --package-lock-only` inside a workspace member updates the **root** lockfile
unless you pass `--no-workspaces`. Two lockfile defects, one fix each. (#263 has since been
closed; **#273 is the same root group bump and fails the same two checks today** — the
standalone-lockfile half is unfixed.)

**Status as of 2026-09-17: open, and the fix is known.** #261 and #262 are still open and
still red. **No test reads `.github/dependabot.yml` for this shape**, which is the real gap
— *a class paid for once becomes a check, not just a finding* — and
`verification/tests/failure-classes.Tests.ps1` is where it belongs.

---

### F202 — a newly discovered MCP tool arrives DISABLED, and a disabled tool is indistinguishable from an absent one

**Found by the sponsor testing through the control tower's Ask tab before a demo**, which is
the only place it could have been found, because nothing automated asserts the thing that
was broken.

**What happened.** Asked *"which launch providers have the most launches?"*, the agent
returned vehicle counts summing to **exactly 1,200** — Fabric's row count, pinned by V5.3 —
and cited *"the launches table joined to the vehicles table"*, a table that does not exist
in the AWS Glue catalog. A follow-up *"how many rows are in the launches table"* returned
**1,200** against AWS's **286,473**. The answer was correct, confident, well-sourced, and
from the wrong lakehouse.

**The diagnosis offered two branches and both were wrong.** The controller reasoned: six
tools listed means a stale connector needing refresh; seven listed means generative
orchestration is off. The truth was a third state nobody considered — **seven were listed,
and the new one was present and switched OFF.** The sponsor toggled it on and saved; the
save did not reach the published agent. A **publish** did.

**Why it was invisible.** This is F119's class in another system: a thing that exists but is
not enabled produces behaviour identical to a thing that is absent. Neither the tool list's
*length* nor the orchestration setting distinguishes the two states.

**The claim that made it possible.** `infra/copilot-studio/agent-definition.md` § 4.1 said
*"the tool list refreshes dynamically from the server, so adding a sixth tool does not
require re-authoring the agent"*, and `docs/runbooks/layers/L08.md` repeated it under V8.3.
That was recorded when `query_compliance` became the sixth tool — **which happened before
the MCP connector was ever built**, so the claim had never once been exercised by adding a
tool to an *existing* connection. 2026-09-16 was its first real test and it failed. A
statement that has never been in a position to be falsified is not a verified statement.

**What makes it a rebuild problem rather than a one-time nuisance.** A rebuild re-imports
the solution, `layer-08-copilot-studio.yml` prints *"L8 — imported, NOT yet live"* and exits
`success` anyway, and the manual post-import steps — seven of them —
**mentioned enabling a discovered tool zero times** (grep count: 0 on 2026-09-16). A tool
that must be hand-enabled after a rebuild is a reproducibility gap in showpiece #1.

**The discriminating question is the reusable artefact.** *"Which providers have the most
launches"* cannot separate the two lakehouses by shape: both have a `launches` table and
both return plausible vehicle names, because the synthetic data deliberately uses real
public vehicle names. **Only the arithmetic discriminates** — 1,200 versus 286,473. Any
future check of this link asserts a number, never a plausible-looking answer.

**Fixed 2026-09-17, in the three places the claim lived**: the false sentence is replaced
in `agent-definition.md` § 4.1 and in L08.md's V8.3; `infra/copilot-studio/README.md` § 6
step 4 now says *toggle every tool on, then publish*; the import job's run summary carries
the same step plus an eighth, *confirm by arithmetic*; and L08.md's deploy procedure gains
step 3a.

**Bounded by measurement, and the bound matters.** A subsequent solution re-import (run
`35166952968`, 2026-09-17T00:32Z) did **not** disable the tool again — the eval five minutes
later returned live AWS figures (286,473 launches, 57,622 for the modal weekday) that appear
nowhere in the agent's prompt. So the hazard is a **newly discovered** tool arriving
disabled, not every import resetting every tool. The step is required after a tool-set
change and cheap otherwise.

**Worth carrying into the outbrief, and it is the strongest single item the day produced.**
Not because the link works — because a green-looking answer with a correct-looking source
was wrong, a human caught it by adding up the numbers, and the failure sat in the one layer
nothing automated asserted. V8.6 exists to make that layer machine-checked.

**REOPENED AND RE-CLOSED 2026-09-22, and the bound above was wrong in one direction.**

The 09-17 note bounded the hazard: *"a subsequent solution re-import did not disable the tool
again — so the hazard is a **newly discovered** tool arriving disabled, not every import
resetting every tool."* That measurement was correct and the conclusion was too narrow.

**A third trigger exists: refreshing the tool list in the maker portal re-disables it.** Found
by the sponsor on 2026-09-22, the same way and in the same place as the original — asking the
agent a question through the Ask tab and getting Copilot Studio's Escalate topic instead of an
answer. Toggling the tool on, then refreshing the list to check, put it straight back to off.

**And the published sequence was missing a step.** `infra/copilot-studio/README.md` § 6 step 4
said *"toggle every tool on, then publish"*. Toggling and publishing is not enough: the toggle
has to be **SAVED** first. A publish without a save captures the previously saved state, which
is exactly what happened — three separate probes returned Escalate after a publish, and the
sponsor's own diagnosis was the right one: *"I might not have hit save before publishing."*

**The sequence that works, in order:**

1. toggle the tool **on**
2. **save**
3. **publish**
4. do **not** refresh the tool list afterwards — that undoes step 1

**Confirmed by arithmetic, as this finding requires.** After save-then-publish, the agent
answered *"There are 334,296 rows in the launches table in the AWS launch-intelligence
lakehouse"* in 9.2 seconds — matching a direct MCP `tools/call` to the same tool exactly
(334,296 in 2.9 s), and nowhere near Fabric's 1,200.

**The discriminating number has moved, and any future check must not pin it.** This finding
recorded 286,473 on 2026-09-16; the live count on 2026-09-22 is **334,296**. It is real
launch-industry data and it accumulates. A check that asserts the literal figure will fail for
the wrong reason within weeks. **Assert "not 1,200"** — that is the number that means the
wrong lakehouse answered, and it is pinned by V5.3.

### Two things that were NOT the cause, recorded because each was chased

- **The MCP server.** `tools/list` — the call the agent actually makes — returned all seven
  tools including `query_aws_lakehouse_sql` throughout. The server was never at fault.
- **The container's own startup log**, which prints `5 tools` while `/healthz` on the same
  revision reports 7. That is **F215**, still open, and it is cosmetic here: two different
  code paths, and the registry the agent reads is the correct one. It is a standing trap for
  the next person debugging this, because it looks exactly like the cause.

A third false lead is worth recording for method rather than content: the MCP container was
checked for AWS tool-call log lines, found none, and the absence was briefly treated as
meaningful. **The server has no per-call logging at all**, so that check could never have
produced evidence either way — silence read as a signal, in the middle of an investigation
about exactly that error.

### Reproducibility, which is the half that outlives the demo

`infra/copilot-studio/solution/.../topic.MeridianOpsTools/data` listed six tools until
2026-09-22 — `query_aws_lakehouse_sql` was never committed, so the sponsor's hand-toggle
existed only in the estate and F159's rule applied: a change is finished when a **rebuild**
reproduces it. The committed solution now enables all seven, and
`verification/tests/failure-classes.Tests.ps1` compares that list against the `-AllowedTool`
default in `layer-08-audit.ps1` — **read from the script rather than copied**, so the two
cannot drift apart again. Run against the pre-fix file it names `query_aws_lakehouse_sql`
exactly.

**Nothing went red for the six days this was broken.** V8.6 and V8.7 passed throughout,
because the Verifier calls the MCP server directly — which proves the link works and says
nothing about whether the agent can use it. V8.1 compares component names; V8.3 reads the
server's declared tools and the solution's components. Three criteria in the area, none
reading the one field that decides whether the demo question can be answered. **The only
thing that found it, twice now, was a person asking the agent a question.**

---

### F203 — an L7 deploy re-tags every app to `:latest` and erases the commit provenance V10.2 depends on *(open, and red right now)*

**What happened.** The scheduled `self-heal` run at 2026-09-17T00:56Z — run
`35168595017` — **failed V10.2** after twelve consecutive green runs:

```
[PASS] V10.1   [FAIL] V10.2   [PASS] V10.3   [PASS] V10.4
432 closure(s) in 30d - explained: 1, closed by image rebuild (lane 3): 429,
closed outside the chain: 1, unexplained: 1
| #9 code-scanning js/trivial-conditional fixed but mls-mcp-demo-ca: could not
  establish whether the running image carries this heal - the running image
  'ghcr.io/…/mcp-tools:latest' carries no sha- tag, so the commit it was built
  from is unknown
```

**Root cause, and it is a collision between two layers.** F197 fixed V10.2 by asking whether
the **running image contains the merge commit**, which works because app CI tags images
`sha-${GITHUB_SHA:0:7}` — *"the running image names its own commit."* But
`.github/workflows/layer-07-apps.yml` declares `image_tag` with `default: latest` and
applies it to **all five apps**. The two L7 runs on 2026-09-16 (21:12Z and 23:01Z, deploying
the AWS identity wiring) therefore replaced `mcp-tools:sha-…` with `mcp-tools:latest`, and
the commit binding V10.2 reads went with it.

Confirmed by reading the live estate, 2026-09-17:

| app | running image | deployed by |
|---|---|---|
| `mls-compliance-demo-ca` | `compliance:sha-c1b7c91` | its own app CI |
| `mls-control-tower-demo-ca` | `control-tower:sha-7945931` | its own app CI |
| `mls-mcp-demo-ca` | `mcp-tools:**latest**` | `layer-07-apps` |
| `mls-data-api-demo-ca` | `data-api:**latest**` | `layer-07-apps` |
| `mls-launch-ops-demo-ca` | `launch-ops:**latest**` | `layer-07-apps` |

The estate is in a **mixed** tagging state, and which half an app is in depends only on
which workflow last deployed it.

**V10.2 is behaving correctly and that is the point.** F197 deliberately chose *"a tag that
resolves to nothing, or a comparison that cannot be read, reports `could not establish` and
stays red; it never converts silence into 'the heal never ran'."* That is the right rule —
an auditor that cannot see must not be able to claim either way — and it means the honest
consequence of an L7 deploy is a **red showpiece #3 for the remaining life of the 30-day
closure window**. Deploying showpiece #2 turns showpiece #3 red, silently, with nothing in
either layer's documentation connecting them.

**The class.** A deploy path that degrades *traceability* rather than *function*. Every
V7 criterion passed on the same revision — 7 of 7 — because none of them asks what commit
the image came from. The damage is only visible from another layer's audit, four hours
later, on a schedule.

**Not fixed when first recorded.** The obvious repair is for `layer-07-apps.yml` to resolve
a concrete `sha-` tag rather than defaulting to a floating one, which is the same rule as
*prefer a value the template derives over one a human stores* (F129). It is a workflow
change, not a documentation change, and it was recorded rather than performed.

**Fixed in the deploy path, 2026-09-17.** `layer-07-apps.yml` now resolves the requested tag
to a digest against GHCR's registry API and then finds the `sha-` tag pointing at *that same
digest*, per app, before anything is deployed. The bytes are identical to what `latest` would
have shipped — app CI pushes both names to one digest in a single `build-push-action` call —
so nothing about the running application changes; only the name it is deployed under, and
that name is the evidence. Anonymous pull token, no credential, five apps in about ten
seconds against the live registry.

The fallback matters as much as the resolution. When GHCR cannot be read, or no `sha-` tag
shares the digest, the requested tag is used **unchanged** and the step emits a warning that
names V10.2 and says what will go red. Refusing the deploy over a traceability problem would
be the wrong trade; leaving it silent is what let this finding exist for a day, so the
connection between an L7 deploy and an L10 failure is now printed at the moment it is made.

**The coupling is now a test, not a memory.** `verification/tests/failure-classes.Tests.ps1`
reads the tag pattern V10.2 parses out of `verification/layer-10-audit.ps1` and the pattern
the deploy path resolves to out of `layer-07-apps.yml`, retypes neither, and fails when they
disagree about any sample tag — plus asserts the resolver is wired, the warning names the
criterion, and every `app-*-ci.yml` still deploys the tag that names its commit. All four
reversions were mutation-tested red. One of them initially passed: the first draft asserted
the *absence* of one spelling of the defect, and a revert wearing a different spelling walked
straight through it. Assert what makes the deploy safe, not one shape of its opposite.

**Still red until the estate catches up.** The fix is in the deploy path, not in the estate:
three apps are still *running* `:latest` from the 2026-09-16 deploys. V10.2 stays red for
those apps until an L7 deploy or an app CI run re-tags them, and no deploy is performed here.

---

### F204 — the ledger said three Glue tables; the live catalog had five, two of them views *(fixed 2026-09-16)*

**What happened.** Every document in this plan — the spec, the plan, the sponsor runbook,
and the ledger entry recording the sponsor's own answers — carried
`MLS_GLUE_TABLES=launches,agencies,schedule_events`. The live Glue catalog holds **five**:
those three plus `launches_latest` and `agencies_latest`, both `VIRTUAL_VIEW`s.

**Why three would have failed, and failed in the expensive way.** `02-athena-role.sh` builds
one `arn:aws:glue:…:table/<db>/<name>` per entry. A Glue view is a catalog object in its own
right and needs `glue:GetTable` on **its own ARN**; the base table's grant does not reach
it. A role built from three names answers **every base-table question perfectly** and
`AccessDenied`s the views. That is a *partial* failure, which reads like a data problem
rather than a policy one — the most expensive kind to diagnose in front of an audience.

**Caught by resolving against the live catalog rather than trusting the written list**, the
same rule that caught the Entra URI format and the token version on the same day. It paid
for itself twice: `launches_latest` returns **7,969** rows, and during the demo the agent
enumerated all five tables live, which is a better demonstration than any single count.

**`MLS_DATA_PREFIXES` stays at three**, deliberately — a view holds no S3 objects of its
own, so widening the S3 grant to match would grant prefixes that do not exist. The two
variables are separate so they can legitimately differ, and this is the case that proves it.

---

### F205 — a *deferred minor* about deploy identity caused a silent write failure two tasks later *(fixed 2026-09-16)*

**What happened.** Task 1's live deploy ran under an ambient `admin@` Global Admin Graph
token instead of CI's OIDC deployer identity. It was disclosed, it was forced by uncommitted
changes being unreachable by workflow dispatch, and it was recorded as a **deferred minor**
assumed to close itself once the work merged and subsequent deploys ran through CI.

Two tasks later, `infra/entra/manifest.json` declared `requestedAccessTokenVersion: 1`,
`apply-entra.ps1` sent it, and the tenant kept returning **null**. The L3 run got
`403 Authorization_RequestDenied` PATCHing that **one** app while every other write
succeeded.

**Cause.** `mls-github-deployer` holds `Application.ReadWrite.OwnedBy` — narrowed
deliberately by F8 — and the `aws-athena` app **had no owner**, because it was created out
of band under `admin@`. The four apps L3 created all list the deployer; this one listed
nobody.

**Why nothing could have told us.** `apply-entra.ps1` is convergent: an app already in the
desired state issues **no PATCH at all**. So L3 had never been able to write this object and
had never had occasion to try. The failure surfaced only because a *new* field made the app
diverge for the first time.

**Fixed, and the theory proven rather than inferred.** The sponsor added the deployer as an
owner; L3 re-ran from the PR branch (deliberately not from `main`, so a failure could not
leave `main` red) and `requestedAccessTokenVersion` returned **1** where it had returned
null. Ownership was both necessary and sufficient — the field carried no separate
requirement.

**The class, and it is one level up from F125.** Not a value that cannot be seen, but a
**permission that was never held, on an object nobody noticed was unowned**, invisible
because the tool that would have exercised it had no reason to. A deferred minor about
*identity* is not the same kind of deferred minor as a stale comment.

**The implementer refused to hand-patch it under `admin@`**, correctly: that makes the check
green and leaves the real defect exactly as hidden as before (F159).

---

### F206 — an IAM condition on a key the service never supplies granted nothing while reading as tighter *(caught in review)*

`s3:ListBucketMultipartUploads` was scoped with a `s3:prefix` condition. S3 supplies
`s3:prefix` for `ListBucket` — **not for that action**. The condition can therefore never
match, so the statement **granted nothing at all, while reading as a more carefully scoped
version of itself.**

A reviewer reading for tightness sees a tightened statement and moves on; a reviewer reading
for *effect* has to know which context keys the service populates for which action. Nothing
in the repository could have caught it: there is no test that can execute someone else's IAM
policy.

Found because the review was instructed to read the IAM JSON as if it were production code,
on the grounds that nobody on this side could execute it and a defect would cost the sponsor
a round trip out of an eleven-day window.

---

### F207 — `mapfile` is a bash 4 builtin, and under `set -u` its absence discards every later check *(caught in review)*

`03-verify.sh` used `mapfile`, which macOS ships no version of (bash 3.2). Under `set -u`
the target array simply stays unset and the **next** line aborts the script — so every check
after that point is silently lost.

That is precisely the failure mode the script was written to avoid: *a run against a live
account is an expensive, rate-limited observation, so it reports everything it saw and exits
non-zero only at the end.* The idiom chosen to collect the results was the thing that would
have reintroduced fail-fast into the one script whose whole design is fail-late.

---

### F208 — two tests written into the plan were wrong in a way that would have degraded correct code *(fixed in flight)*

Both were the controller's own, and both were caught by implementers who pushed back rather
than complied.

1. **The audience URI.** The plan specified `api://${prefix}-aws-athena-${env}`. This
   tenant's default app-registration policy rejects it —
   `InvalidUniqueTenantIdentifierAsPerAppPolicy` requires a verified domain, tenant id or
   app id in the URI. The first adaptation used the **app id**, which was accepted and then
   **reversed on review**: an app id is reassigned every time the registration is recreated,
   so an AWS trust policy conditioned on it survives no Entra teardown — the exact failure
   mode the design's own blast-radius section exists to prevent, one object over. The
   shipped value embeds the **tenant id**, which is the one thing a rebuild never recreates.
2. **The dialect assertion.** The plan asserted `DIALECTS.trino.idioms` does
   `.not.toContain("strftime")`. The idioms prose legitimately contains the bare word — it
   says strftime and DATEPART *"do not exist here"*, exactly as the tsql profile does. The
   plan's test would have forced **weakening correct documentation to satisfy a bad
   assertion**. Switched to the callable forms `"strftime("` / `"DATEPART("`, matching the
   convention the sibling test in that same file already used.

**The shape worth remembering:** a test that is wrong does not merely fail, it exerts
pressure on correct code to become wrong. Both were caught only because the implementer
treated the brief as a claim rather than an instruction.

---

### F209 — an HTTP 429 looks exactly like an empty value *(fixed by classification)*

`az containerapp exec` rate-limits at **HTTP 429 with `retry-after: 600`** after roughly
three calls, and a throttled response is indistinguishable from a command that returned
nothing. A first sweep recorded two environment variables as **absent** on that basis;
re-reading after the throttle showed both present.

Corrected to **UNOBSERVABLE-with-cause** rather than absent — F105's class, caught by the
implementer on itself. It is now encoded: V8.7's verdict table classifies a throttle as
UNOBSERVABLE rather than as a result, because *"Athena and STS refuse under load the same
way."*

---

### F210 — a shell rewrites a leading-slash ARM path and the failure names the wrong system *(closed by a repo-wide sweep)*

**Three separate failures in one session, in three unrelated subsystems.** The last was a
Key Vault role assignment that failed three times with **`MissingSubscription`** — an error
naming the *subscription*, which was fine, rather than the *shell*, which was not. Git Bash
(MSYS) rewrites a bare `/subscriptions/...` argument into a Windows path before `az` ever
sees it. `MSYS_NO_PATHCONV=1` on the invocation fixes it; so does doubling the leading
slash. The same class produced the AWS `file://` policy-document failures earlier the same
day.

**The expensive part is not the fix, it is the error message.** It names a remote service, so
it sends you to look in Azure — at subscription context, at `az account set`, at the role
assignment's scope string — none of which is wrong.

**Closed as a check, not as prose.** `verification/tests/failure-classes.Tests.ps1` now
sweeps the repository for a leading-slash ARM path handed to a native CLI without the guard
(`Describe 'a leading-slash ARM path is never handed to a native CLI unguarded'`), and the
matcher was tightened after a first version that accepted `MSYS_NO_PATHCONV` *anywhere in
the span* passed its own mutation test for the wrong reason.

---

### F211 — two agents in one worktree corrupted a full-suite result *(closed by ruling)*

**What happened.** Two agents were dispatched into `C:\Users\paulc\Dev\azure-devsecops` at
overlapping times, and **both were told nobody else was working there**. Three hours earlier
the controller had recorded a ruling — after colliding with an agent itself — that it would
not run git commands in a worktree while an agent worked in it. The letter of that ruling
was honoured and its purpose was not: last time the controller collided with one agent, this
time it caused two agents to collide with each other.

**What it cost, and only the second item is interesting.** One agent checked out `main` and
branched mid-task, so the other's commit landed on *their* branch and needed a rebase. That
is tidiness. The real cost: **one full-suite run reported 3 failures in three unrelated
files** because Pester was reading a tree another agent was writing. Only a stash-and-rerun
against clean `main` proved it was contamination rather than regression.

**A green suite is worth nothing if the tree moves underneath it — and so is a red one.**
The failure mode is not that the suite breaks; it is that it produces a *plausible* result
attributable to the work under test.

**Ruling: one worktree, one agent, no exceptions — and the allocator allocates explicitly
rather than asserting exclusivity it has not checked.** Both dispatches claimed exclusivity
and both claims were false when written.

---

### F212 — `pac copilot publish` reports a stale timestamp *(open, upstream tool)*

`pac copilot publish` printed `9/16/2026` as `9/2/2026` — a publish timestamp two weeks
stale, on a publish that had just succeeded. The portal showed `Published 9/16/2026`,
disproving the CLI's own output.

**The correct surface is Dataverse.** When the instructions fix was published, the
implementer confirmed independently that `bot.publishedon` advanced **23:41 → 23:51 UTC**
rather than trusting the CLI line. That is the right treatment of a tool whose self-report is
known unreliable: read the state that decides behaviour, not the tool's account of it.

Related and equally load-bearing: **`pac copilot clone` writes MIXED line endings** — CRLF
header, LF body — so splitting on either corrupts the other.

---

### F213 — the documented agent instructions had silently drifted from the shipped ones *(closed by a byte-for-byte test)*

**Found unasked, while fixing something else.** `infra/copilot-studio/agent-definition.md`
§ 2 is the documented source of truth for showpiece #1's system prompt. The solution's
botcomponent is what actually imports into Copilot Studio. **Only the second one reaches the
agent**, so the first can be wrong indefinitely without anything failing — and it was: the
money-precision rule and the whole `cost_daily` vs `get_cost_series` rule had lived in the
solution since 2026-09-02 (F138) and had **never been written into the doc**.

**A specification that does not have to match the artefact is a comment.**

Closed properly: `infra/copilot-studio/tests/agent-instructions.Tests.ps1` now asserts the
two copies are character-identical, with 14 assertions, **9 of which fail against the
pre-change files**. The change protocol had assumed this drift away; it is now checked.

---

### F214 — a *filtering* reader of the tool allowlist, caught before it landed

Registering a seventh tool meant widening `ALLOWED_TOOL_NAMES`. A mandated grep for every
reader of that list found `evals/run.ts` computing `expected = [...ALLOWED_TOOL_NAMES]` — a
**filtering** reader, the dangerous kind. Widening the constant to seven while the local
server still served six would have **permanently broken `npm run eval` in CI**, and nothing
about that file would have been edited to show for it.

**That is F145's exact shape, caught before landing rather than after days of red.** F145
cost this project days because V8.1's expected component set was built from one of three
files that declare components, and widening it silently changed the meaning of V8.3, which
filtered the same list.

Fixed by deriving `expected` from `ToolRegistry(createLocalBackends())` rather than from the
raw constant. Two more readers were found in the same sweep — `allowlist.test.ts`'s length
assertion and `layer-08-audit.ps1`'s `-AllowedTool` default — and a **new cross-check now
compares the PowerShell default against the TypeScript source**, verified to fail on
divergence, so the two can never drift silently again.

---

### F215 — the MCP container's startup banner logs a hardcoded tool count *(open, minor)*

The container logs **`5 tools`** at startup while `/healthz` on the same revision reports
**7**. A stale hardcoded literal in a log line that an operator reads *while debugging
exactly the class of problem F202 describes* — it was very nearly chased as the cause.

Small, and worth fixing for that reason alone: a diagnostic that lies costs more than one
that is absent.

---

### F216 — the eval that could not grade now grades, and the number it produced breaches a criterion nobody has run *(open)*

**The good half.** For the life of this project, `layer-08-agent-eval` returned **0/10 with
zero tool calls**, and F184 recorded that it could not distinguish an unhealthy agent from an
eval that was not allowed to reach a healthy one. On 2026-09-17T00:37:22Z it returned
**9/10, pass bar 9, `unobservable: 0`**, path `mcp-tools-only`, over Direct Line against the
deployed agent (run `35166952968`). It grades.

**The half that is a finding.** That same artifact records **`p95LatencySeconds: 34.177`
against V8.5's 20 s budget** — and the eval harness prints the comparison itself. Three
things about it:

- **The p95 is the maximum.** Ten questions; the slowest was the **first**, at 34.18 s
  against 3.3–11 s for the other nine. That is the cold-start signature L08.md's *"one
  discarded warm-up question precedes the timed set"* note exists to remove, and the warm-up
  did not happen.
- **The honest answer costs about twice the work of the wrong one.** The disambiguation fix
  shipped hours earlier makes an ambiguous question query **both** lakehouses. That is
  correct behaviour and it eats this budget.
- **None of this is a verdict.** V8.2 and V8.5 both reported `(not selected)` in that run's
  audit, which was a filtered `-OnlyCriterion` run for V8.6/V8.7. **An eval artifact is a
  claim; the criterion is what makes it evidence**, and no unfiltered L8 audit has run.

**The single failure is worth naming.** `worst-supplier` failed by **declining** — *"I'm
sorry, I'm not sure how to help with that"* — which is the ungrounded-responses-Off fallback,
not a wrong answer. The honest reading is "the agent did not reach the data", not "the agent
stated a false supplier". A grade of 9/10 conceals that distinction; the artifact does not.

---

### F217 — root AWS credentials on the development machine *(open, larger than this plan)*

`aws sts get-caller-identity` on the machine that ran the trust-anchor scripts returns
`arn:aws:iam::<account>:root`.

`BOOTSTRAP.md`'s careful scoping of `launch-intel-agent` — roles constrained to
`role/launch-intel-*`, a managed policy deliberately named outside the agent's own
self-modify reach — **constrains nothing whatsoever against a root principal**. The scoping
is real and it is also decorative for as long as the same machine holds root access keys.

**Recorded rather than acted on**, because it is the sponsor's account and larger than this
link. It is stated here because a document arguing that this estate holds no standing
credentials should not be silent about the one machine that holds the most powerful
credential in a second cloud.

---

### What the day cost, and what it bought

Nine of nine plan tasks landed. The link works: an Azure-hosted agent, holding no AWS
credential, answering from data in S3 — and, by the end of the night, **volunteering the
distinction** between a fictional company's synthetic records and real launch-industry data
without being asked to.

**Six of the seventeen findings above are a check or a diagnosis being confidently wrong**
— F202's two-branch diagnosis that missed a third state, F205's deferred minor assumed
self-closing, F206's statement that read tighter than it granted, F208's two plan-authored
tests, F209's throttle read as emptiness, and F214's filtering reader caught one commit
before it would have broken CI silently. Those are the entries worth the archive.

**Three of them were caught by a human adding up numbers, not by a machine.** F202 most of
all. The corrective is in the runbooks now, and V8.6 is the criterion that makes it
machine-checked — but the order of events is the honest part and should stay on the record:
the estate's own checks were green throughout.

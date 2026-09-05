# Finding register — 2026-09-04

Findings recorded on 2026-09-04, the day the self-healing chain first ran end to end and
the day the demo was given. The 2026-08-22 → 2026-09-03 register is
[2026-09-03-finding-register.md](2026-09-03-finding-register.md); this file continues it
rather than replacing it, and neither is pruned.

Findings **F187, F188, F188b, F188c and F189** were recorded on the day in
[`docs/DEMO-READINESS.md`](../DEMO-READINESS.md)'s blocker tree, where the L10 story reads
in one piece. They are cross-referenced here and not restated.

| | |
|---|---|
| **F190** | The vuln-lab cannot be re-armed through a pull request |
| **F191** | V10.1's "no human merged this" read a field that says the same thing either way |
| **F192** | The chain window depended on a variable nobody had set, so an in-flight chain read as failed |
| **F193** | The nightly compliance artifact still cannot merge, and F120's fix is not the reason *(open, hypothesis in flight)* |
| **F194** | CODEOWNERS claimed a review gate the repository has never enforced |
| **F195** | Both L10 criteria counted a *skipped* check as a failed one |
| **F196** | V6.2 fixed — and F182's leading hypothesis was wrong |

---

### F190 — the vuln-lab cannot be re-armed through a pull request *(open, worked around)*

**What happened.** The 2026-09-04 cycle healed the seeded flaw in
`apps/vuln-lab/seeds/component-history.js`, which is the point. `apps/vuln-lab/reseed.ps1`
exists to restore it, and ends by telling the operator:

> *"Open a PR with these changes; never push to main directly (CLAUDE.md). The merge is
> what re-raises both the Dependabot alerts and the CodeQL alerts."*

That documented path **cannot complete**. PR #230 restored the flaw, every required status
check passed, and GitHub refused the merge: *"the base branch policy prohibits the merge."*
The only failing check was `CodeQL`, which is not a required context.

**Why.** Code scanning merge protection blocks a pull request that introduces an alert at
or above a severity threshold. The reseed introduces `js/command-line-injection` at
**critical** — exactly the alert it exists to raise.

**This is stated as a strong inference, not a verified fact.** The setting is not exposed
by the rulesets API and was not read directly. What *was* verified: every required check
passed, `required_approving_review_count` is 0 so no review was outstanding, `strict` was
satisfied, and three other pull requests merged cleanly under the identical ruleset within
the same hour. The alert is the only distinguishing feature.

**The shape of it.** The gate that makes the demo meaningful is the same gate that stops
the lab being re-armed. **The lab can be healed but never re-seeded** — so the second cycle
onward is blocked for anyone who forks this repository after their first heal.

**Worked around, not fixed.** #230 was merged with `gh pr merge --admin`, with the reason
posted on the pull request first so the override is on the record rather than an
unexplained bypass. `apps/vuln-lab` is never imported by a deployed app, never
containerised, and its seeds are unstarted server factories; a single logged override on an
isolated synthetic fixture has a smaller blast radius than lowering the severity threshold
for every future pull request in the repository.

**Still open.** A durable answer — a path exemption, a documented override step inside
`reseed.ps1`, or accepting that re-arming is a human act — has not been chosen.

---

### F191 — the "no human merged this" check read a field that says the same thing either way *(fixed 2026-09-04)*

**What it asserted.** V10.1 stage 5: `mergedBy.login -eq 'github-actions[bot]'`. The
governing claim, from `self-heal.yml`'s own header, is that merging machine-written code
without human approval is defensible partly because *"V10.1 explicitly FAILS the audit if
`mergedBy.login` is a human. A hand-assisted chain is a failed chain."*

**Why it could never pass.** The chain arms auto-merge with `SELF_HEAL_TOKEN`, a personal
access token owned by a person, so GitHub attributes the merge to **that person**. PR #232
— selected, patched by Copilot Autofix, gauntlet-green and merged with no human involved at
any point — reported `mergedBy: paulcfuqua` and failed the criterion whose entire job is to
detect a human.

**Why the obvious fix was the wrong one.** Allowing the token owner's login would have made
the criterion pass and assert **nothing**: a genuine hand-merge produces an identical
`mergedBy`. Verified directly — of the eight merges before this was written, #232/#226/#225
had no human involved and #231/#230/#229/#228/#227 were merged by hand, and all eight are
byte-identical in that field. That is this repository's own documented failure class: the
artefact that usually accompanies the capability, asserted in place of the capability.

**What actually separates the two states is WHEN the decision was made.** Auto-merge stamps
`autoMergeRequest.enabledAt` before the gauntlet finishes and the platform merges on green;
a discretionary click happens after the result is known and leaves no `autoMergeRequest` at
all. On #232: armed `18:25:39Z`, merged `18:29:02Z`. The decision preceded the outcome by
three minutes and twenty-three seconds, and `autoMergeRequest` survives the merge, so it is
readable after the fact.

`Test-MergeProvenance` now asserts that the merge was pre-authorised, that the arming
preceded it, and that the identity which armed it is the identity credited with it.

**Known limit, stated rather than discovered.** A human who arms auto-merge on a heal PR
before the checks finish passes. Stages 1–3 independently require the head commit to have
come from the Autofix API on a `self-heal/` branch, so the bar is high — but it is not
zero. **The durable fix is infrastructural**: run the chain as a GitHub App, whose
installation token merges as `<app>[bot]`, and the original literal assertion becomes
honest again with no reinterpretation.

---

### F192 — the chain window depended on a variable nobody had set *(fixed 2026-09-04)*

**What happened.** The self-heal workflow runs the L10 audit in the same run that arms
auto-merge, so it reads the trail minutes before the gauntlet finishes. Run **33905789865**
verified at `18:26:07` a merge that landed at `18:29:02`, and recorded **FAIL** for a chain
that was working perfectly and completed 175 seconds later.

**Why.** An in-flight chain is exactly what the PENDING window exists for, and the window's
start came only from `-ReseedMergedUtc` / `$env:MLS_L10_RESEED_MERGED_AT`. Nobody had set
it. Unset meant "no window", and no window meant every incomplete trail was a failure. The
workflow printed a warning saying so on every run, and the warning had become the normal
state — which is how a check stops being read.

**Fixed** by deriving the window from the heal PR's own `autoMergeRequest.enabledAt` when
no re-seed timestamp is supplied: the moment the chain committed to *this* heal, which is
on the pull request and needs nobody to remember anything. A supplied value still wins, and
the report names which clock it used, because the two measure different things — the
derived one times this heal's attempt, the supplied one times the whole demo cycle.

**The general shape:** a window that only works when a human remembers to set a variable is
a window that is usually absent, and "absent" had silently been given the harshest possible
meaning.

---

### F193 — the nightly compliance artifact still cannot merge *(OPEN — hypothesis in flight)*

**What is true.** PR **#147** has been open since 2026-09-01 and carries **zero** status
checks. Every compliance run pushes to the `compliance-state` branch and spawns eight
workflow runs that immediately conclude `action_required`; GitHub names
`github-actions[bot]` as both `actor` and `triggering_actor`. Nine days of compliance state
have never reached `main`, and this is the source of essentially all the noise in the run
history.

**F120's fix is in place and works.** The workflow pushes the branch with
`SELF_HEAL_TOKEN` precisely so its pull-request checks will run, and run **33906128904**
printed `Branch pushed with SELF_HEAL_TOKEN, so its pull-request checks will run.` The
secret is a repository secret and the job declares no environment, so it is visible. **The
originally diagnosed cause is not the current cause**, and recording that matters more than
the fix would: the register would otherwise carry a closed finding for a symptom that never
went away.

**Hypothesis, explicitly not a diagnosis.** The one thing still claiming to be the bot is
the commit identity, hardcoded to `github-actions[bot]` regardless of which credential
pushes. GitHub holds workflow runs it attributes to Actions for approval, which is the
observed state. The commit identity is now set to the token owner when a PAT is present.

**How it will be settled.** The next nightly run. The evidence is the run's
`triggering_actor`: if runs still arrive `action_required` with the bot as actor, the cause
is elsewhere — a repository approval policy — and the comment in `compliance.yml` says so
rather than being left as though it worked. **Do not close this finding on the absence of
noise; close it on a `pull_request` run that reports a conclusion.**

**SETTLED 2026-09-05, AND THE HYPOTHESIS WAS WRONG.** The identity fix did exactly what it
was written to do and changed nothing that mattered. On head `426c00c5`: the commit's
author **and** committer are `paulcfuqua`, the pull request's own author is `paulcfuqua`,
and the branch was pushed with the PAT. GitHub still reports `actor:
github-actions[bot]`, `triggering_actor: github-actions[bot]`, and holds every run at
`action_required`. #147 still carries zero checks.

**A push made from inside a workflow run is attributed to Actions whichever credential
performs it**, and the resulting `pull_request` runs are held for approval. That is GitHub
behaviour the workflow cannot talk its way out of, and no amount of token or identity
juggling will change it.

**The other route is closed by this repository's own ruleset**, which the direct push
states exactly:

    remote: error: GH013: Repository rule violations found for refs/heads/main.
    remote: - Changes must be made through a pull request.
    remote: - 12 of 12 required status checks are expected.

So the emitter is caught between two rules with no automated path between them: it may not
push to `main`, and the pull request it is therefore forced to open can never acquire the
checks that `main` requires.

**Still open, and now grounded rather than guessed.** Three candidates, none of them a bug
fix: a ruleset **bypass actor** for the emitter — the only fully automated route, and a
real widening, because bypass is actor-scoped rather than path-scoped and would permit
pushing anything; running the emitter as a **GitHub App**, whose runs may not be gated the
same way; or accepting that the compliance history reaches `main` by a human action.

**This is a governance decision.** It belongs with the mode declared in
`.github/governance-mode.json` and with whoever owns that, not with whoever next edits the
workflow.

**DIAGNOSTIC, 2026-09-05: approval is the sole blocker, and the artifact passes.** The
eight held runs on head `426c00c5` were approved by hand. PR #147 went from **zero checks
to eighteen**, and **16 concluded `success`** with the remaining 7 still running when they
were orphaned. Nothing else was in the way: with the runs released, the compliance artifact
behaves like any ordinary pull request and clears the gauntlet on its own merits. That
settles the premise — a fix that stops the runs being held is sufficient, and **no gate
needs weakening to land this**.

**And the diagnostic exposed a SECOND mechanism nobody had named.** Merging an unrelated
pull request triggered the compliance workflow, which **force-updates `compliance-state` on
every run**. The branch moved `426c00c5` → `0510ba21`, every one of those 18 checks was
orphaned, eight fresh runs were held on the new head, and #147 was back to zero checks
within minutes.

So manual approval is not merely toil, it is a **race the emitter runs against itself**: an
approval only survives if nothing lands on `main` before the gauntlet finishes, and the
emitter is triggered by exactly that. This is why "just approve it" has never worked and
never will.

**The complete fix is therefore two things, not one:**

1. **Remove the approval gate** — run the emitter as a GitHub App, whose token is not
   attributed to `github-actions[bot]`. This is also F191's durable fix: an installation
   token merges as `<app>[bot]`, restoring V10.1's original literal assertion. It **retires**
   `SELF_HEAL_TOKEN` rather than adding a credential.
2. **Arm auto-merge on the compliance pull request**, so it merges the moment it is green
   instead of requiring a human to be watching in the one window where the branch has not
   just been force-updated.

Neither weakens a gate. The pull request still runs the full gauntlet and still has to pass,
which is the whole point of preferring this over a ruleset bypass.

---

### F194 — CODEOWNERS claimed a review gate the repository has never enforced *(fixed 2026-09-04)*

**What it said**, for the life of the repository:

> *"Paired with branch protection requiring review, this is the control that stops a
> workflow, a role grant or a compliance record changing without the person accountable for
> it seeing the diff. NIST SP 800-171 Rev 2 3.4.3 … and 3.1.5 … both lean on this being
> real rather than aspirational."*

**What was true.** `main`'s ruleset sets `required_approving_review_count: 0`. No approval
has ever been required, and **every merge in the repository's history was self-approved** —
including to `/.github/workflows/`, `/infra/entra/`, `/compliance/` and `/verification/`,
the four paths the file singles out as the ones where an unreviewed change does the most
damage. `require_code_owner_review: true` is inert at a count of zero.

A control asserted in prose, citing two NIST requirements, enforced nowhere — sitting in
the file that describes the control, in the repository whose thesis is catching exactly
that.

**It was not an oversight, and that is the interesting part.** Self-approval is a
deliberate, correct policy for a repository that is still being built: intent is
established by whoever is building the thing, the gauntlet is the safety gate, and nothing
here reaches a real user. The defect was that the policy existed only in the sponsor's head
and this conversation. **A mode nobody can read is not a policy, and a policy nothing
checks is a wish.**

**Fixed** by making the mode a declared, checkable parameter —
[`.github/governance-mode.json`](../../.github/governance-mode.json) — with
**V1.5** comparing the declaration to the live ruleset, an offline sweep in
`failure-classes.Tests.ps1` catching prose that drifts from it, and CODEOWNERS rewritten to
say what it actually does today: it *routes* review requests, it does not require them.

The principle the modes encode: **auto-merge where intent is pre-established and safety is
machine-checkable, and only where the change cannot modify the checker.** Self-healing is
deliberately unaffected by the mode — a patch GitHub generated for a named advisory that
cleared the full gauntlet auto-merges unattended in both, because heal PRs never touch the
paths that define what safe means.

---

### F195 — a skipped check was counted as a failed one *(fixed 2026-09-05)*

**What happened.** The scheduled run **33934487531** took the Dependabot lane and failed
V10.2 with:

> `gauntlet not green: deploy to Container Apps=skipped, deploy to Container
> Apps=skipped, …`

five times over, on a chain that had done its job.

**Why.** The gauntlet stage's predicate was `$_ -notlike '*=success'`, so anything that was
not literally `success` counted as a failure — including `skipped`. Those deploy jobs are
**correctly** skipped: they only run on `main`. Every heal pull request carries them.
Verified across three of them — **#174, #226 and #232 are each exactly 5 skipped / 24
success** — so both V10.1 and V10.2 failed their gauntlet stage on every correct run.

**The same shape as F191**, found the same way: a criterion asserting something that cannot
be true when the system behaves correctly, discovered only by reading a real run rather
than a green test suite.

**Fixed** with `Test-GauntletConclusion`, shared by both trails. Accepting `skipped`
outright would have been the opposite trap — a pull request where nothing ran would sail
through — so it asserts the capability: **no check failed, AND at least one check actually
concluded successfully.** `neutral` joins `skipped` as not-a-failure, because CodeQL
reports it on a pull request it has nothing to say about (observed on #225).

**And it exposed a latent bug beside it.** `$conclusion = Get-CheckConclusion …` was not
wrapped in `@()`. PowerShell unwraps a one-element result, so a heal PR with exactly one
check run made `$conclusion` a bare string and `"string".Count` threw under
`Set-StrictMode` — the criterion would have reported `check threw: The property 'Count'
cannot be found on this object` instead of a verdict. Never hit in production only because
every real heal PR has had 29 checks. Both call sites are now wrapped.

---

### F196 — V6.2 now says whether it could look, and F182's hypothesis was wrong *(fixed 2026-09-05)*

**F182** recorded that V6.2 fails on the rebuilt estate with one sentence offering two
readings and committing to neither:

> `the query returned no result (HTTP error, or the Reader identity cannot query this
> workspace)`

and named a **leading hypothesis, explicitly unproven**: that V6.2 retries past the
federated assertion's five-minute lifetime and reports the resulting auth failure as "no
result".

**That hypothesis is wrong, and the code says so.** `Invoke-MlsAz` matches
`AADSTS700024|assertion is not within its valid time range` and **throws** — deliberately,
even under `-AllowFailure`, with a comment explaining that swallowing it is how "an expired
credential becomes 'the lakehouse has no tables'". So an expired assertion reaches a
criterion as `check threw: … could not authenticate`, never as `no result`. Whatever V6.2
is hitting, it is not that.

This is recorded rather than quietly corrected because the register's value is that it
keeps its wrong diagnoses. F182's reasoning from job duration was sound and the conclusion
did not survive contact with the source.

**What was actually fixed** is the thing F182 asked for regardless of which hypothesis won:
*"establish whether the token can be obtained at the moment of the query, then report
UNOBSERVABLE rather than FAIL when it cannot."*

On the failure path only — an extra token call on every pass would spend the very assertion
lifetime this reasons about — V6.2 now asks whether this identity can mint a Log Analytics
token:

- **no token** → `SKIP`, stating that reachability is unobservable and that this is **not**
  evidence about the workspace or its role assignments;
- **token obtained** → `FAIL`, stating that authentication works and pointing at workspace
  RBAC, which is a different fix made by a different person.

The next real L6 run will say which of those two the estate is actually in. Until then V6.2
is **not** claimed as fixed — only as capable of telling the difference, which it was not
before.

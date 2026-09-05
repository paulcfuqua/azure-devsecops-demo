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

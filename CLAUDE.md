# Working Agreements — Meridian Launch Systems Demo

Rules for every agent (Orchestrator, Verifier, leads, ICs) working in this repo. The
authoritative brief is [docs/BRIEF.md](docs/BRIEF.md); the current plan is
[docs/superpowers/plans/2026-08-22-g1-master-plan.md](docs/superpowers/plans/2026-08-22-g1-master-plan.md).

> **Starting cold, or resuming after a compaction? Read
> [docs/DEMO-READINESS.md](docs/DEMO-READINESS.md) first — its SCORECARD and BLOCKER TREE
> are at the top.** The brief says what the demo is *for*; the scorecard says how much of
> it actually works today (1 showpiece of 4, 5 layers verified of 12) and the blocker tree
> says what stands in the way, ordered by how much each one unblocks. Nothing in this file
> tells you what to *do next*; that document does.
>
> Two habits it will save you: check a blocker's evidence yourself before acting on it -
> several entries record a confident diagnosis that a second sample disproved - and treat a
> finding with a test as closed and a finding with only prose as open.

## Hard rules

1. **Agents execute the estate. Two things still stop them: money and deletion.**
   *(Sponsor amendment 2026-08-29 — supersedes the original rule, which read "No
   Azure/Entra/Fabric/GitHub-org writes …  Authoring code is always allowed; executing
   deployments is not." G0 was human-run and every bootstrap script said "Agents author
   this file; they never execute it.")*

   **Agent-created and agent-managed infrastructure is now the demo**, not a thing the
   demo describes. Azure, Entra, Fabric and GitHub writes are allowed once (a) G1 is
   approved, (b) your layer is unblocked by the Orchestrator, and (c) the previous layer
   has Verifier sign-off — including the G0 bootstrap scripts under
   `scripts/bootstrap/`, which agents may now run.

   The two carve-outs are not caution, they are the point. An agent that can spend a
   sponsor's money without asking, or delete tenant objects it cannot recreate, is
   demonstrating something nobody wants to buy:
   - **G2 still binds.** Any spend-profile increase waits for a human, with the cost
     delta and duration stated first. Resuming a paid Fabric capacity is G2 *per resume*.
   - **G3 still binds.** The three tenant-level teardown scripts
     (`infra/{entra,policy,purview}/teardown.ps1`) keep refusing to run unattended in CI
     without `-AllowAutomation`, and no workflow passes it.

   The Verifier's independence is unchanged: it runs only code in `verification/`, as
   `mls-verifier`, never as the deployer.
2. **Gates:** G0 bootstrap (agent-run since 2026-08-29; previously human-only); G1
   one-time plan approval; G2 any spend-profile increase (state cost delta + duration,
   wait for human); G3 tenant-level deletions (Entra objects, labels, Fabric workspace,
   OIDC federation); G4 exception escalation (layer fails verification twice, cost
   anomaly, credential failure, lead deadlock). RG-scoped teardown of demo resources is
   gate-free by design.
3. **Escalation chain:** IC → workstream lead → Orchestrator → human. Only the
   Orchestrator messages the human; the Verifier may bypass it only when the Orchestrator
   itself is the problem.
4. **Synthetic data only.** Public facts (vehicle names, launch sites) are fine. Nothing
   proprietary from any employer. No real person's PII — demo users are fictional.
5. **No secrets in the repo. In CI, only the six that have no federated alternative.**
   Tenant/subscription IDs live in GitHub environment *variables*. Everything **Azure**
   authenticates via OIDC / workload identity federation, and since the 2026-08-24
   amendment there is **no LLM API key anywhere**. CI is not secret-free, and claiming it
   was is finding F28 — the complete list of long-lived credentials is:
   `PURVIEW_CERT_BASE64`/`_PASSWORD` and `MLS_VERIFIER_CERT_BASE64`/`_PASSWORD` (two Entra
   app X.509 certificates — Security & Compliance PowerShell has no federated path),
   `SELF_HEAL_TOKEN` (a PAT with `repo` write, because a `GITHUB_TOKEN` push does not
   trigger workflows) and `MLS_VERIFIER_GH_TOKEN`. Two more live in **Key Vault**: the
   **Direct Line secret** — held under the name `MLS_DIRECTLINE_SECRET_NAME` carries, which
   is `mls-directline-secret` and *not* the `directline-secret` the G0 runbook used to say
   (F147) — exchanged server-side for a short-lived token and never reaching a browser, and
   `mcp-auth-token`. Adding a seventh needs a written reason;
   `.github/workflows/gitleaks.yml`'s incident text is the rotation list and must stay
   in sync with this one.

   **A THIRD LIVES IN KEY VAULT, and the list said two until 2026-09-02.**
   `mls-data-api-github-token` is the read-only GitHub PAT behind the control tower's Dev and
   Sec tabs, created by G0 step 11b for finding F116. That is the written reason. It was
   legitimate all along and simply never reached this list, which called itself complete while
   the vault held four — the fourth being `mls-github-token`, its own pre-rename name, left
   behind because Key Vault has no rename and the delete half never happened. Deleted
   2026-09-02; soft-delete retains it until 2026-12-02.
   `verification/tests/failure-classes.Tests.ps1` now asserts that every secret a runbook
   creates is named both here and in gitleaks.yml, because a list that is only *believed* to be
   complete is the one that drifts.

## How we work

- Each teammate works in its own git worktree; merge to `main` via PR. ICs never push to
  `main` directly.
- Every layer ships a triplet: `deploy` path, `teardown` script, `verification/` audit
  script. A layer without all three is not done.
- Teardown scripts for tenant-level objects are idempotent create-if-absent on replay;
  the standard kill/rebuild path never touches tenant objects (see spec F6).
- The Verifier runs only code in `verification/`, authenticated as `mls-verifier`
  (Reader), never as the deployer SP. Audit output is written to
  `verification/reports/` and committed.
- CI targets `ubuntu-latest` (bash). Local orchestration targets PowerShell 7 (`pwsh`).
  Never assume Windows PowerShell 5.1.
- **A constant that names something in another system is verified against that system, not
  written from memory.** Policy and role GUIDs, Graph app-role ids, SKU strings, OIDC subject
  formats: resolve them, and put the resolution in the deploy path so it fails in seconds
  rather than inside a nested ARM error. Twenty-three such constants are pinned here and
  exactly one was ever wrong, which is precisely why it survived - see the register's
  "What this register has learned about verification".
- **Every value has one source.** Estate-wide settings live in the `demo` GitHub environment
  (`AZURE_LOCATION` and friends); a default elsewhere silently outranks them, because a
  workflow input beats an environment variable. When a value looks wrong, ask where it comes
  from before asking whether it is correct.
- **A check that gates a dangerous action asserts the capability, not the artefact that
  usually accompanies it.** Break-glass readiness meant "an account is in the group" and
  passed on one holding no role, so the enforced MFA policy would have deployed on a recovery
  path that could not recover anything. V3.3 meant "an enabled CA policy exists" and failed
  on a tenant whose MFA was enforced by Security Defaults. Ask what makes the action safe, or
  what the control actually requires, and assert that — the artefact is a proxy that is right
  until the day it matters.
- **A run is an expensive, rate-limited observation: it returns everything it saw.** A step
  iterating over independent items reports on all of them and fails at the end, rather than
  stopping at the first. Fail-fast is right for a deploy that must not proceed broken - and
  the layer still does not proceed - but applying it to DIAGNOSIS makes the discovery rate
  equal to the deploy rate, which is how three consecutive forty-minute runs each returned
  exactly one fact.
- **An audit that cannot see a thing says so; it never reports the thing as absent.** Three
  findings in one night, in three unrelated subsystems, were the same defect: a ZAP gate
  reported a security failure it had never assessed, because the step that owned the verdict
  had been skipped (F102); V9.1 announced that secret scanning, push protection and
  Dependabot alerts were OFF when all three were enabled, because their endpoints are
  admin-only and the check read the absent field as a disabled control (F103); and V5.2
  called a lakehouse empty while its SQL endpoint returned 1,200 rows, because Fabric
  answers `/tables` with `[]` rather than 403 to a caller without OneLake read (F105).
  Each produced a confident, specific, WRONG answer that a reader would have acted on, and
  none of them looked like anything other than an ordinary red criterion. Where an API
  returns emptiness on denial, absence is unprovable: establish that you could observe
  before reporting what you saw, and when you could not, fail as UNOBSERVABLE - never pass,
  and never claim the control is missing. The symmetric error is worse: an auditor that
  cannot see a control must not be able to report it as PRESENT either.
- **A class paid for once becomes a check, not just a finding.** When a defect is understood,
  ask where else its shape occurs and encode that as a test over the whole repository. The
  first sweep written this way found two more instances in a second, having cost a deploy to
  learn once. `verification/tests/failure-classes.Tests.ps1` is where they live.
- **A check declares how long it is willing to wait, and why.** Patience is opted into, never
  inherited: a criterion that says nothing gets a short window, and one that needs longer
  states the number and cites the propagation it is waiting on. Nineteen of forty-seven
  criteria once inherited a 30-minute window nobody chose for them, including a check whose
  answer was settled the moment the deploy step returned - it spent all thirty minutes
  reaching a wrong verdict. Match the window to the thing being waited for, and remember
  propagation is shared wall clock: the second criterion is not starting the clock again.
- **A step allowed to fail is a step nobody is watching. Assert its EFFECT, not its
  exit code.** Twice in one day a job reported success while the work it exists to do had
  silently stopped happening. Every zip publish to every Function App had failed 403
  against a storage firewall since the estate was built, and L6 signed off green each
  time, because both publish steps carry `continue-on-error` (F119) - so
  `mls-cost-ingest-demo-func` held no functions at all, and the FinOps leg everyone
  believed was blocked on a Cost Management export was *also* missing the Function meant
  to consume it. The nightly compliance artifact was pushed to a branch and opened as a
  pull request exactly as designed, and that pull request could never merge, because a
  `GITHUB_TOKEN` push triggers no workflow runs, so no required check ever reported
  (F120): nine days of state never reached `main` while the job stayed green.
  `continue-on-error` is often RIGHT - a non-critical step must not be able to starve the
  audit that would judge it, and removing it makes a silent failure loud by stopping the
  Verifier, which trades away the wrong thing. What it costs is visibility, and visibility
  is verification's job: for every step permitted to fail, something must assert the state
  it was supposed to produce. V6.7 asserts the Function Apps actually contain functions -
  the capability, not the artefact that usually accompanies it, which was "the publish
  step ran".
- **A value that exists, is spelled correctly, and cannot be seen by the thing that reads it
  is the most expensive defect this estate produces.** Four in one session, in four
  subsystems, all silent and all green. A Key Vault reference resolved to nothing because the
  site named no identity to resolve it with, and `az ... appsettings list` printed the
  reference back perfectly either way (F122). `SELF_HEAL_TOKEN` was an *environment* secret
  and every job that consumes it declares no environment, so the self-healing chain got HTTP
  403 for nine days and reported "nothing to heal" (F123). `MLS_DIRECTLINE_TOKEN_URL` reached
  the two jobs that did not need it and missed the one that builds the bundle, so an image
  built an hour *after* the variable was set still shipped without it (F124). And a job-level
  `if:` gated on `vars.AZURE_VERIFIER_CLIENT_ID != ''` — which is evaluated **before** the
  environment resolves, so a guard meaning "skip when unconfigured" meant "skip always", and
  two verify jobs had never once run (F125).
  Each looked correct from every angle a reviewer checks, because **an absent GitHub variable
  is the empty string, not an error**, and an unresolvable reference is still a well-formed
  string. Ask not "is this value right" but "can the thing that reads it see it at all", and
  prefer a value the template DERIVES over one a human stores: the control tower's own origin
  was a GitHub variable containing a Container Apps FQDN, which is a name that cannot survive
  the rebuild this demo exists to show (F129, F90's class in configuration).

- **A probe must be made with the client that will make it.** Status codes are
  content-negotiated. The DAST's auth-wall detector looked for a 302 to
  login.microsoftonline.com and was validated with PowerShell, which sends browser-like
  headers and gets exactly that. CI runs `curl`, which sends no `Accept` header and gets a
  **401 with no redirect** - so the detector never fired once, every Easy Auth app was
  classified as reachable content, and a scan of a login page passed as a security result
  (F158). The signal was in the response the whole time: Easy Auth's challenge carries
  `authorization_uri=` and names the audience in `resource_id=`, while a genuine
  application 401 carries neither. Validate a check against a friendlier client than
  production uses and you have tested a different system.

- **A change is finished when a rebuild reproduces it, not when the thing works.** An Easy
  Auth audience was hand-patched onto three running apps and the scan started working;
  `validation` appeared zero times in the template, so the next teardown would have erased
  it silently (F159). The same session hand-added an `identifierUris` to one app while
  testing, and that single manual value then masked a bug in the other two for three runs
  (F163). Configuration that exists only in the estate is a demo that works once.

- **Evidence that cannot distinguish two states is not evidence.** An authenticated scan and
  a blocked one produced identical reports - 17 alerts over 3 URLs - and nothing recorded
  which had happened, so "is this working" could not be answered from the artifact at all
  (F162). The fix was not more capability but one recorded line per target: `authenticated
  GET / -> HTTP 200, 638 bytes`. It found the real bug on its first run. When a check cannot
  tell success from silence, add the observation, not another feature.

- **A list that feeds two checks answers two questions.** V8.1's expected component set was
  built from one of the three files that declare components, so it could never match what
  Dataverse reports and spent days naming sixteen legitimate topics as drift (F145). Fixing it
  meant widening that list - and V8.3 filtered the SAME list for
  `connector|connection|tool|agent`, so a topic whose display name is "Meridian Ops Tools" would
  have started counting as a tool and V8.3 would have failed on a correct solution. One broken
  criterion traded for another. Before widening an input, find every reader of it: a check whose
  meaning changed because a different check needed more data is the hardest kind to spot,
  because nothing about it was edited.

- **Verify that the input can be obtained before verifying that it is valid.** The
  directline-token Function got a careful user-token verifier: signature, issuer, audience and
  expiry, twelve negative cases, real RSA key pairs, mutation-tested. It shipped and the Ask
  tab broke, because Container Apps' Easy Auth token store was disabled and `/.auth/me`
  returns claims with **no raw token** — there was nothing to verify and no test had asked
  whether there could be (F135). The checking was rigorous about the half that was already in
  hand and silent about the half it depended on. A guard has a precondition; test the
  precondition, or the guard is a well-tested branch that never executes.

- **File CONTENT is written with a file tool, never through a shell heredoc.** Content sent
  through a heredoc crosses two escaping layers - the shell, then the Python or PowerShell
  string literal inside it - and backslash sequences are silently transformed on the way. In
  one session this produced a regex of `/<0x08>429<0x08>/` where `\b` was meant (a literal
  BACKSPACE character, matching nothing, in a security-relevant throttle check), a `printf
  '%s
'` split across two lines, a swallowed shell line-continuation, and a commit message
  with two command names missing because backticks were executed. The damage is invisible in
  review: the file looks right in a diff, the code compiles, and a comment carrying it passes
  every test.
  Use Write or Edit for content. Keep the shell for commands. When a programmatic edit is
  genuinely the right tool - a repeated substitution across many files - write the script to
  a file first and run the file, so the content is escaped once rather than twice. Then
  **verify the bytes, not the rendering**: `python -c "print(repr(open(p).read()[i:j]))"` or a
  grep for the literal you expected. A backslash you cannot see is the whole failure mode.
  `verification/tests/failure-classes.Tests.ps1` sweeps the repository for the control
  characters this produces, because the class is cheap to check and expensive to find.

- **A test harness runs in the language mode of the script it tests.** No
  `Set-StrictMode -Off` in `*.Tests.ps1`, and no test that supplies the answer it is
  checking - a wrapper, a helper default, or a fixture that re-wraps a return value is not a
  test, it is a mirror.

## Direction

*Sponsor direction, 2026-09-01. This is the ORDER the work is heading in, not the next
ticket. Nothing here overrides an unblocked layer, a gate, or whatever the Orchestrator has
in flight — if a phase-3 item is the thing in front of you and phase 1 is not blocked on it,
do the work. What this section settles is **sequence when the sequence is in question**, and
why each phase gates the next.*

**1. The IaC runs smoothly, up and down.** A clean deploy of every layer, and a teardown and
rebuild that completes. This is first because everything else is measured against a
rebuilt estate: if the environment cannot be recreated, nothing built on it can be trusted
or shown twice.

**RUN, AND LARGELY ACHIEVED, 2026-09-03.** The estate was torn down (14 minutes, clean) and
rebuilt (87 minutes), and came back with the same 30 resources. L2, L3, L5, L6 and L7 all
signed off on the rebuilt estate — L7 at 7 of 7, including V7.6, the criterion that asserts
the data API returns rows rather than a status code.

**All four of the never-rebuilt fixes survived**: the derived DAST targets (six enumerated
from Azure, zero High-risk alerts), the Entra probe roles (all three Easy Auth apps
authenticated), F107's Log Analytics purge (a genuinely new workspace, proven by
`customerId`), and the Easy Auth audience — which was correctly *erased*, because the
template no longer produces it. That last one settled F159 against F161 empirically: the
hand-applied audience was never load-bearing.

**What the rebuild actually bought was not those four.** It failed twice before it passed
and produced eleven findings (F167–F177), and the three most valuable were not broken
infrastructure but **green checks verifying nothing**: L4's audit had never once executed on
any run in the repository's history, V11.2 had never had evidence on any teardown ever run,
and a step whose only job is to announce a failed grant was reporting success. Nothing but a
real teardown finds those.

**Still open from phase 1:** L4 cannot be independently audited until a human performs
g0-bootstrap step 11d (`mls-verifier` holds no Security & Compliance grant — a tenant change,
so G3); and V11.2's fix is itself untested, because no teardown has happened since it landed.

**2. The apps tell the truth about what is there.** The dashboards render real rows from the
lakehouse, and what they display matches what the estate actually contains. *F101 was the
whole of this phase and is closed — V7.6 now independently confirms the data API answers with
rows, not merely a status code.* The historical statement follows: F101 was that
`data-api` could not authenticate to Fabric's SQL endpoint, so every
dashboard renders empty while every criterion passes. This phase is also where the gap named
in `docs/DEMO-READINESS.md` § D closes — **no criterion currently asserts that the API
returns a row**, and a layer that verifies plumbing without verifying water is why an empty
estate signed off 5/5 for two days.

**3. The advanced capabilities land.** Purview labels applied and visible; the Copilot agent
published, authenticated and answering from the lakehouse; Defender scans producing real
posture; the self-healing chain run at least once end to end. Each of these is a distinct
showpiece and each is independently blocked today (P-12's certificates, F106's undeclared
registrations, L10 never executed). They come third because a capability demonstrated over
empty data demonstrates nothing.

**4. The outbrief.** A document — target ~20 pages, PDF — that showcases the estate through
**verifiable screenshots of real data in the running apps**, plus the narrative: the IaC,
the apps as proof, the data segregation, the copilot on top, the self-healing pipeline, and
disposable environments for sandboxes, upgrades and proofs of concept. The argument is
business value and innovation — how this landscape shores up the automation floor so an
enterprise can spend its attention on needle-moving work instead of undifferentiated
plumbing.

It is last for a reason that is not scheduling: **a screenshot is a claim, and three quarters
of the intended screenshots would today photograph an empty page.** The document cannot be
honest before phases 1–3 are real, and a polished outbrief over unverified capability is the
exact failure this repository spends its verification budget preventing.

One thing worth carrying into that document when it is written: the sharpest material is not
the feature list. It is that this estate **catches its own false claims** — ten findings in a
single session where a green check was confidently wrong, each now a test. For an audience
answering to their own auditors, evidence that is structurally incapable of overstating
itself is a stronger argument than any board or dashboard.

## Naming and tagging

- Resource names: `mls-<app|role>-<env>-<type>` (e.g. `mls-mcp-demo-ca`,
  `mls-ops-demo-sql`). `infra/bicep/naming.bicep` holds the **defaults**; a deployment
  overrides them with `MLS_COMPANY_PREFIX` / `MLS_ENV_SEGMENT` (from `estate.env`
  locally, the `demo` GitHub environment in CI). Do not hardcode `mls` anywhere else —
  and that now includes identity: `infra/entra/manifest.json` is tokenised `${prefix}` /
  `${env}`, resolved by every reader of it. Rebranding used to reach Azure and leave 22
  Entra names and the Fabric workspace behind, which is half a rebrand and the half
  nobody sees (F90).
- Required tags on every RG (policy-enforced): `env`, `app`, `costCenter`, `owner`,
  `dataClassification`, `managedBy=iac`. Resources inherit via modify policy.
- Demo RGs: `mls-rg-platform`, `mls-rg-apps`, `mls-rg-data`, `mls-rg-ops`. Teardown =
  delete these four.

## Commit conventions

- Conventional commits (`feat:`, `fix:`, `infra:`, `docs:`, `verify:`).
- Layer work references its layer, e.g. `infra(L6): container apps environment`.
- Never commit generated data (`data/generated/`), local settings, or `.env`.

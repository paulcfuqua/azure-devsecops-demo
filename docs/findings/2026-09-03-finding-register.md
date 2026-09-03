# The finding register — 2026-08-22 to 2026-09-03

> **This is an archive. It is history, not current state.**
>
> Every entry below was true when it was written and is dated accordingly. Nothing in it
> has been rewritten, softened, or removed as findings closed — including the diagnoses
> that later turned out to be **wrong**, which are the entries worth reading twice.
>
> **For what is true today, read [../DEMO-READINESS.md](../DEMO-READINESS.md).** It is the
> live scorecard and blocker tree, and it is short on purpose. This file is what you open
> when you want to know *how* something came to be true, or what a green check once hid.

## Why nothing was deleted

A register that quietly edits itself is not a register. The argument this repository makes
to an auditor is not that it has few defects — it is that **it catches its own false
claims**, and that argument is only checkable if the false claims are still here.

Read [F160/F161](#f160f161--two-bugs-in-the-authenticated-scan-and-f159s-diagnosis-was-wrong-fixed-2026-09-02)
against [F159](#f159--the-audience-the-scanner-needs-existed-only-on-the-running-apps-fixed-2026-09-02)
for the clearest example: F159 diagnosed a refused security probe as a missing Easy Auth
audience and hand-patched three live applications. F161, two hours later, established that
the diagnosis was wrong — the real fix was to request a differently-scoped token — and
reverted it. **The 2026-09-03 teardown settled it empirically**: the rebuild erased the
hand-applied audience and the authenticated scan kept working, which is what a wrong
diagnosis looks like when the estate is finally asked instead of the author.

The same shape appears in [F151](#f151--the-closed-credential-list-was-not-closed-closed-2026-09-02)
(two mysterious credentials that resolved as one legitimate and one rename leftover) and in
[F167](#f167--the-check-worked-and-the-scorecard-had-been-wrong-for-two-days-fixed-2026-09-03)
(a check that was working correctly while the scorecard describing it had been wrong for
two days).

## Where the rest of the register lives

**This file is not the whole register**, and a reader told otherwise would never find F19,
which is cited from `CLAUDE.md` and from `infra-up.yml`. Measured 2026-09-03:

| Findings | Where | Covering |
|---:|---|---|
| 86 | [`../../compliance/findings/2026-08-26-prepublication-review.md`](../../compliance/findings/2026-08-26-prepublication-review.md) | the pre-publication security review |
| 43 | **this file** | roughly F121–F177, plus the historical A–E assessment |
| 11 | [`../superpowers/specs/2026-08-22-azure-devsecops-demo-design.md`](../superpowers/specs/2026-08-22-azure-devsecops-demo-design.md) | design pressure-test findings |
| 3 | [`../runbooks/layers/L07.md`](../runbooks/layers/L07.md) | layer-local |
| 1 | [`../runbooks/layers/L11.md`](../runbooks/layers/L11.md) | layer-local |

Finding **ids** run to F177; the count of written entries is smaller, because some findings
are recorded only where they were fixed. **The id is the trail** — `F1`–`F177` are greppable
across `docs/`, `CLAUDE.md`, the layer runbooks and `verification/tests/`.

**A finding with a test is closed. A finding with only prose is open.**

---

### F182 — V6.2 reports "no result" where its sibling reports an expired credential *(open, 2026-09-03)*

L6's verify has failed on the rebuilt estate twice, ~3 hours apart, on the same criterion:

    [PASS   ] V6.1  ARM GET on each resource: SKU/serverless/auto-pause/minReplicas match
    [FAIL   ] V6.2  KQL query against LAW succeeds as verifier
               observed: the query returned no result (HTTP error, or the Reader identity
                         cannot query this workspace)
    [PENDING] V6.3  First cost export file lands within 24 h
               observed: check threw: ... could not authenticate: the federated client
                         assertion has EXPIRED (AADSTS700024), and re-authenticating did not
                         recover it. This is NOT a permissions problem and not a missing
                         resource, and it will look like both. The CI login's assertion lives
                         about five minutes; this call asked for a token az had not already
                         cached, later than that.
    [PASS   ] V6.5  V6.7  V6.8

**Not a fresh-workspace timing artifact.** The workspace was created 12:34:31Z; the second
failure ran 15:58 -> 16:14Z, ninety minutes later, and failed identically. It also PASSED once
on a workspace fourteen minutes old (the 2026-09-03 03:33Z L6 probe), so "new workspace" does
not separate the passing case from the failing ones.

**What does separate them is job duration.** The probe run's verify took **0.9 minutes**. Both
failing runs took **14-16 minutes**. V6.3, in the same job and the same file, names the
mechanism exactly: the CI federated assertion lives about five minutes, and a call needing a
token `az` has not already cached, made later than that, cannot authenticate — while anything
already cached keeps working, "which is why the run got this far".

**LEADING HYPOTHESIS, EXPLICITLY UNPROVEN: V6.2 retries past the assertion's lifetime and its
later attempts fail to authenticate, which it reports as "the query returned no result".** The
alternative — that `mls-verifier` genuinely cannot query the rebuilt workspace — is not ruled
out, and the criterion as written cannot tell me which, because its own message offers both
readings in one breath and commits to neither.

That is the point worth recording regardless of which hypothesis wins. **V6.3 diagnoses this
condition precisely and V6.2 cannot**, and they sit in the same file. One criterion was taught
to distinguish "I could not authenticate" from "the thing is absent"; its neighbour reports the
union of "HTTP error" and "cannot query" and calls it a result. It is F102/F103/F105's class in
the component that exists to catch F102/F103/F105 — an audit that cannot see, reporting absence.

**Not chased in this session**, and deliberately not diagnosed further from two samples: the
last confident single-sample diagnosis in this register was mine, about my own fix, and it was
wrong twice (F180). What the next session needs is not a guess but the observation V6.2 refuses
to make — establish whether the token can be obtained at the moment of the query, then report
UNOBSERVABLE rather than FAIL when it cannot. F105's rule already says exactly that.

### F181 — a transient in L4's supplementary step skipped four layers *(noted 2026-09-03, not chased)*

Rebuild 3, first attempt. L4's apply failed and took the rest of the estate with it:

    success  Install ExchangeOnlineManagement (pinned)
    failure  Connect S&C PowerShell and apply the label taxonomy

    Label 'mls-public' already correct - skipping.
    Label 'mls-internal' already correct - skipping.
    Label 'mls-confidential' already correct - skipping.
    Label 'mls-export-controlled' already correct - skipping.
    WARNING: Force Validate not set
    Set-LabelPolicy: One or more errors occurred.

**All four labels applied cleanly.** Only `Set-LabelPolicy` failed, with Security & Compliance
PowerShell's generic aggregate error — and the label policy is what V4.3 itself calls
*supplementary*, beside V4.1's labels, which are the layer's actual deliverable and had
already succeeded in that same run.

**It did not reproduce.** An immediate standalone re-run of `layer-04-purview.yml` passed both
apply and verify, as did the next full rebuild. One failure, two immediate passes.

**Deliberately recorded rather than diagnosed, and deliberately not fixed.** One sample is not
a cause, and a confident first explanation from a single observation is the error this register
keeps cataloguing — F107 asserted a permanent state from a forty-minute sample and was wrong.
Calling this "S&C flakiness" would be a guess wearing a diagnosis's clothes.

What is *not* a guess is the blast radius: **L5, L6, L7 and L8 all skipped, and the L11 rebuild
proof failed**, because a supplementary step in a tenant-object layer hiccuped. L5 and L6 have
no real dependency on L4 — the labels are tenant-scoped and nothing in the data or platform
layers consumes them; `infra-up.yml` chains them for ordering alone.

So there is a design question here — should the layer graph gate on this at all, and should a
supplementary step be able to fail a layer — and it is the same *kind* of question as
BLOCKER-E: a decision about what the gate-free cycle is allowed to stop for, not a bug with an
obvious fix. **Sponsor's call, 2026-09-03: note it, do not chase it.** Recorded here so the
next person who hits it knows it has been seen once, recovered on retry, and is not new.

### F180 — the empty string cannot win a `&&`, so V11.2 skipped even after F170 was fixed *(fixed 2026-09-03)*

F170 established that V11.2 had never had evidence, and moved the guard into the job that
can actually see the certificate. The fix was merged, and the **second teardown of the day
proved it did not work**:

    [PASS] V11.1  All RGs absent post-down
    [SKIP] V11.2  Tenant objects intact (L3/L4 audits still pass)
           observed: child audits skipped by -SkipChildAudit

The guard itself was now correct — measurable from the job's own steps:

    success  Run ./.github/actions/demo-env-guard
    success  Install ExchangeOnlineManagement (pinned)
    success  Stage the mls-verifier certificate for the child L4 audit
    skipped  Tenant-object audits unavailable      <- correctly skipped: guard said CONFIGURED

The certificate staged. The "unavailable" notice did not fire. And `-SkipChildAudit` was
passed anyway.

**The cause is that GitHub Actions has no ternary operator.** `A && B || C` is
short-circuit evaluation over *truthiness*, and **the empty string is falsy**. The
condition read:

    ${{ steps.tenant.outputs.configured == 'true' && '' || '-SkipChildAudit' }}

When the guard said `true`, `true && ''` evaluated to `''`; `''` is falsy, so `|| C` won and
the flag was passed. When the guard said `false`, the flag was passed. **The expression
could not express "pass nothing" for any input** — the one thing it existed to do.

The fix is positional rather than clever: put the **non-empty** value in the `&&` branch.

    ${{ steps.tenant.outputs.configured != 'true' && '-SkipChildAudit' || '' }}

Every other call site in the repository already used that shape
(`inputs.only_criterion && '-OnlyCriterion' || ''`, seven of them). This was the only one
that did not, and it was the one guarding the kill/rebuild cycle's honesty checkpoint.

**Two independent causes stacked behind one symptom.** F170 was real and its fix was
necessary; it was simply not sufficient, and nothing short of another teardown could show
that — the guard and the flag are only observable together on a run that performs a
teardown. Fixing F170 and declaring V11.2 repaired would have been exactly the error the
register keeps recording: a change that makes the code look right, asserted without the
observation that would test it.

**It is also the same family as F26 and F125.** All three are the empty string behaving as
a value in one place and as a falsehood in another: an absent GitHub variable is `''` rather
than an error (F26); a job-level `if:` evaluates before the environment resolves so it reads
`''` and fires always (F125); and here `''` in a `&&` branch is unreachable as a result. The
platform is consistent about this and it is consistently surprising.

`verification/tests/failure-classes.Tests.ps1` now sweeps every `${{ ... && ... || ... }}`
expression in `.github/workflows` and `.github/actions` and fails any whose `&&` value is an
empty literal. Mutation-tested: restoring the old expression fails with the file, line and
the expression itself.

### F179 — L4 has a verdict, and it took three stacked defects to get one *(2026-09-03)*

`verify L4 (mls-verifier)` reported real criteria for the first time in the project's
history:

    [PASS] V4.1  Get-Label returns the 4 labels with expected GUIDs recorded to verification/reports/
    [SKIP] V4.2  Labels survive a kill/rebuild cycle (checked again at L11)
    [PASS] V4.3  Label policy exists, publishing the taxonomy to the demo groups

**2 PASS + 1 by-design SKIP.** The labels were real the whole time — `apply` had been
creating them correctly since 2026-09-01. What did not exist was any way to prove it.

Three defects sat between the green job and this one, each hiding the next:

| | |
|---|---|
| **F175** | the guard read a `verify` secret from a job declaring `environment: demo`, so it reported "not configured" and the audit was skipped — green in six seconds |
| **F176** | with the guard fixed, `Connect-IPPSSession` died at parameter binding: `-CertificateThumbprint` is Windows-only and CI is ubuntu |
| **F177** | with binding fixed, the service returned `UnAuthorized` — `mls-verifier` held neither `Exchange.ManageAsApp` nor any directory role |

Only the first two were fixable in the repository. F177 needed a human to perform a tenant
grant (g0-bootstrap step 11d), which the sponsor authorised and which was then performed
and read back.

**What this cost is the point.** A layer sat at "verified" for two days on the strength of a
job that ran nothing, and the only reason anyone looked was a teardown-and-rebuild. Each
fix revealed the next, and none of the three was visible from the outside — the job was
green at every stage.

**V4.2 remains unproven by machine.** It is deferred to L11, and L11's V11.2 is the
criterion that had never had evidence (F170). The labels were confirmed to survive the
2026-09-03 teardown by hand; *confirmed by hand* is not what the criterion is for.

### F178 — the documented consent command silently revoked three grants *(fixed 2026-09-03)*

Performing g0-bootstrap step 11d exactly as written destroyed part of the estate's identity
configuration:

    BEFORE (5):  Graph Directory.Read.All · Graph Policy.Read.All
                 Telemetry.Probe × 3  (launch-ops, control-tower, compliance)
    AFTER  (2):  Graph Directory.Read.All · Graph Policy.Read.All

`az ad app permission admin-consent` **removed three grants and created nothing** — not even
the `Exchange.ManageAsApp` role it exists to add. Both commands exited 0.

**Why.** `admin-consent` does not add; it **reconciles** the principal's app-role assignments
against the app registration's declared `requiredResourceAccess`. The three `Telemetry.Probe`
roles are assigned directly by `Initialize-VerifierProbeRole` in `infra/entra/apply-entra.ps1`
and appear in no manifest, so consent classified them as drift and deleted them.

**What it would have broken.** Those three roles are how the authenticated DAST mints a token
that gets past Easy Auth (F161). Without them every Easy Auth app reclassifies as `auth-wall`
and L9's scan silently reverts to scanning a login page — the exact regression that F152
through F163 were spent eliminating, re-introduced by a *documentation step*.

**How it was repaired, and this matters more than the fix.** Not by hand: re-running
`layer-03-entra.yml` restored all three, because `apply-entra.ps1` creates those assignments
and calls no consent of its own. The deploy path repaired damage done from a terminal — which
is the estate's central claim working in the direction nobody designs for.

**The runbook was the defect.** Step 11d told the operator to run this. It now carries a
warning block, uses a direct additive POST to `appRoleAssignments` instead, and records that
the POST was confirmed working with the probe roles intact afterwards. The old text is kept
above the correction rather than deleted.

**The class, and it is not "read the docs more carefully":** a command whose name is
*consent* — which reads as additive, granting, permissive — performs a **reconcile**, and a
reconcile is a delete for anything not declared. The register already holds a family of
findings about checks that could not see what they claimed to (F102, F103, F105); this is the
inverse: an action that did more than its name admits. Both are cured by the same habit —
read back the state afterwards and compare it to what you had, rather than trusting an exit
code. The step already said *"VERIFY THE CONSENT, DO NOT TRUST ITS EXIT CODE"*. It was right,
and it was still not paranoid enough: it told the reader to check whether the grant had been
*added*, and nobody thought to check whether something had been *taken away*.

### F177 — L4's audit could never have authenticated, and nothing in the repo can fix it *(open, needs a human — 2026-09-03)*

With F170 and F176 fixed, `verification/layer-04-audit.ps1` was reached for the first time
in the project's history. It failed immediately:

    layer-04-audit could not start: UnAuthorized
    exit code 2

Read back as Global Admin — a read, nothing granted:

| | `appRoleAssignments` | `memberOf` |
|---|---|---|
| **`mls-verifier`** | Graph `Directory.Read.All`, `Policy.Read.All`, 3× `Telemetry.Probe` — **no Office 365 Exchange Online entry at all** | **`[]`** |
| **`mls-purview`** (control) | **`Exchange.ManageAsApp`** on Office 365 Exchange Online | **Compliance Administrator** |

`mls-purview` is the control that makes this a diagnosis rather than an assertion: identical
mechanism, same runner, and its Security & Compliance session connects. App-only S&C needs
**both** halves and `mls-verifier` has **neither**.

**This is not fixable in this repository.** Granting an app role or a directory role is a
tenant change and G3. It is written up as `docs/runbooks/g0-bootstrap.md` **step 11d**, and
two judgements in that step are worth reading:

- **It does not copy 11c.** `mls-purview` holds Compliance Administrator, which can *write*
  labels. `layer-04-audit.ps1`'s own header says a writable Verifier credential would itself
  be a finding, so 11d proposes **Global Reader** — read-only and Graph-assignable, therefore
  reproducible — with the View-Only Configuration role group as fallback.
- **It says what is not verified.** The object ids and the diagnosis are verified; nobody has
  run the grant sequence end to end, because that is G3. The step says so in a callout rather
  than reading like a tested recipe.

**A repo defect came out of the same thread.** `scripts/bootstrap/01-root-oidc.ps1` never
granted this and never claimed to — it grants two Graph roles and *prints* the S&C grant as a
manual step. But `docs/runbooks/layers/L04.md` said **the script granted it**, and three other
places stated the same intent as accomplished fact. That sentence was wrong for the life of
the project. All four now describe what the tenant actually holds. It is F167's class exactly:
a claim recorded once and carried forward as current.

**Until a human performs 11d, L4 has no verdict** — and GAPs afterwards would be the correct
outcome, not a green.

### F176 — the S&C session used a Windows-only parameter, and the module was unpinned *(fixed 2026-09-03)*

`-CertificateThumbprint` is a **Windows-only dynamic parameter** of `Connect-IPPSSession`.
ExchangeOnlineManagement builds its certificate parameters in a `DynamicParam` block and adds
that one only inside `if($IsWindows)`; the module's own comment reads *"We do not want to
expose certificate thumprint in Linux as it is not feasible there."* CI is `ubuntu-latest`, so
the call died at parameter binding before opening a socket. Verified against the installed
module, not reasoned about.

**It never worked.** This is not a version regression — the path had simply never executed,
per F170 and F175, so a broken call sat undetected behind a broken guard.

**The working implementation was sixty lines above it in the same file.** L4's `apply` job
connects to the same service on the same runner using `-Certificate`/`-CertificateFilePath`,
which the module adds unconditionally, and has always worked. Two jobs, one file, one service;
the one that never ran diverged and nothing could tell. `Connect-MlsCompliance` now mirrors
the proven path and probes the **installed cmdlet** rather than `$IsWindows`, so it follows
the module if the gate moves.

**And the module was unpinned** — three jobs ran `Install-Module ExchangeOnlineManagement`
with no version, so the Verifier's behaviour could change with no commit to this repository.
There is no lockfile for PowerShell modules, so `-RequiredVersion` is the lockfile; it now
lives in one place, `.github/actions/install-exo`, which asserts the version it **loaded**
rather than trusting `Install-Module`'s exit code.

`Connect-MlsCompliance` previously had **no test of any kind, anywhere** — every suite that
reaches L4 mocks it away, which is exactly why this survived.

### F175 — L4 was marked verified, and its audit had never once run *(fixed 2026-09-03)*

`docs/DEMO-READINESS.md` recorded:

> **L4 Purview labels | verified | DONE 2026-09-01, the first time ever.
> `verify L4 (mls-verifier)` PASSED.**

That job passed. It also audited nothing. Steps from the cited run 33548766843, and
identically from the 2026-09-03 rebuild:

    success  Verifier Security & Compliance credentials not configured
    skipped  Azure login (OIDC, mls-verifier)
    skipped  Install the mls-verifier certificate and install ExchangeOnlineManagement
    skipped  Run verification/layer-04-audit.ps1
    skipped  Upload audit report

Green in six seconds, because the *"not configured"* NOTICE step succeeded. The guard it
depends on is F170's.

**What was actually true:** the labels ARE applied — the `apply` job runs
`Connect S&C PowerShell and apply the label taxonomy` and succeeds, using
`PURVIEW_CERT_BASE64`, which IS on the `demo` environment that job declares. That half was
always real. Only the independent verification never happened.

This is the repository's own rule failing in the component built to enforce it: *"a step
allowed to fail is a step nobody is watching — assert its EFFECT, not its exit code."* A
layer's third leg reported success while never executing.

### F174 — the purge check cried wolf on every teardown, and could not do otherwise *(fixed 2026-09-03)*

The teardown step that purges the Log Analytics workspace emitted, two seconds apart:

    02:00:15  Purged.
    02:00:17  ##[warning] A soft-deleted mls-obs-demo-law is still registered, so a
              same-name rebuild will RECOVER it and L6's alert rules will fail (F107).

The warning is **false, and false on every run**. `az monitor log-analytics workspace delete
--force` purges the workspace but leaves a tombstone in `list-deleted-workspaces`. Proven
conclusively on 2026-09-03: the tombstone for `customerId 5c967cf4` was **still listed while a
new same-name workspace (`87f95e84`) ran live in the same resource group**, and both
scheduled-query alert rules — the exact things F107 broke — deployed clean.

So the check could only ever report the hazard as PRESENT. That is the worse half of the rule
three earlier findings taught: *"an auditor that cannot see a control must not be able to
report it as PRESENT either."*

**It cost real time on the run that found it.** It read as an F107 regression, nearly earned a
hand-purge — which would have made the run green and taught nothing — and a whole probe
dispatch was structured around resolving the ambiguity.

The signal that DOES distinguish the two states is the **live** workspace's `customerId`,
which is what F107's own entry recorded (*"its original customerId intact"*) and never encoded
as a check. The teardown now captures it before the delete and publishes it in the step
summary; the test that used to pin the old warning now asserts its **absence**.

### F170 — V11.2 has never had evidence, on any teardown ever run *(fixed 2026-09-03)*

`infra-down.yml`'s `preflight` job declares `environment: demo` and read
`secrets.MLS_VERIFIER_CERT_BASE64` — a secret that lives on the **`verify`** environment. An
absent GitHub secret is the **empty string, not an error**, so the guard reported "not
configured" on every run since it was written, the down-state audit was always invoked with
`-SkipChildAudit`, and:

    [PASS] V11.1  All RGs absent post-down
    [SKIP] V11.2  Tenant objects intact (L3/L4 audits still pass)
           observed: child audits skipped by -SkipChildAudit

**V11.2 is the criterion that proves a teardown did not cross the G3 tenant-object line.** It
is the kill/rebuild cycle's honesty checkpoint, and it has been reporting nothing while the
workflow went green and L11's scorecard row read "verified".

This is F123's shape (a secret invisible to the job that reads it) and F125's (a guard whose
"skip when unconfigured" meant "skip always"), **one level up: the job DID declare an
environment, just not the one holding the secret.** A reviewer checking "does this job declare
an environment" would have seen yes — which is why the F124 sweep did not catch it.

The tenant objects were confirmed intact by hand on the day — seven app registrations, seven
groups, the break-glass account holding an active Global Administrator role — but *confirmed
by hand* is not what the criterion is for.

**Writing the class as a sweep immediately found two more**, which is the argument for writing
sweeps rather than filing findings:

    layer-04-purview.yml   `preflight` read the verifier cert under environment: demo, so L4's
                           independent audit took its degrade path unconditionally (F175)
    layer-09-devsecops.yml `ghas` read MLS_VERIFIER_GH_TOKEN with no environment at all, so
                           the first element of its token fallback chain was dead code and the
                           job has only ever run on SELF_HEAL_TOKEN

`verification/tests/failure-classes.Tests.ps1` now asserts every job reading an
environment-scoped secret declares the environment that **holds** it, not merely some
environment. **Fixed and still untested against a real teardown**, because none has happened
since.

### F171 — V5.2 read a table list over a route it had been refused, and spent 30 minutes doing it *(fixed 2026-09-03)*

The 2026-09-03 re-baseline:

    [PASS] V5.1  Fabric REST: workspace + lakehouse exist
    [FAIL] V5.2  Table list matches manifest
    [PASS] V5.3  SQL analytics endpoint returns expected row counts (launches = 1,200 +/- 0)

V5.2 said the table list did not match while V5.3, reading **the same lakehouse**, returned
1,200 rows. This is **F105 recurring**, and F105's own stated rule is that the criterion must
report UNOBSERVABLE — *"establish that you could observe before reporting what you saw, and
when you could not, fail as UNOBSERVABLE - never pass, and never claim the control is
missing."*

**F105's fix was applied to the message and not to the verdict.** The code did recognise the
shape and printed an honest sentence —

    observed: the tables endpoint returned an EMPTY LIST - this is what it returns without
              OneLake read, not necessarily an empty lakehouse

— and then returned a plain `FAIL` with no `-Final`. So the most-likely-correct state of the
estate produced a red criterion that re-asked a permission question for the full window:
**03:59:25 → 04:29:33, thirty minutes, 91 attempts** at an answer settled on the first poll.
That is F169's shape in a second layer, and the mutation test now measures it — removing the
`-Final` takes the attempt count from 1 back to 91.

**Why the Verifier cannot see the tables, established rather than assumed.** Fabric has four
workspace roles — Admin, Member, Contributor, Viewer — and `mls-verifier` holds **Viewer**,
because the Verifier is read-only by contract. Viewer can read the SQL analytics endpoint
(V5.3 proves it every run) and **cannot read OneLake**, which is what
`GET /lakehouses/<id>/tables` requires. Same lakehouse, minutes apart, on this very run:

    03:58:35Z  deploy identity (Contributor):  Lakehouse seeded: 10 Delta table(s) loaded, 10 reported by Fabric
    03:59:25Z  mls-verifier   (Viewer):        []

Probed directly against the live estate as a principal holding no workspace role at all, the
two endpoints disagree about how to say no — and that disagreement is the whole fix:

    GET .../v1/workspaces/<ws>/lakehouses/<lh>/tables              -> HTTP 200  {"data":[]}
    GET https://onelake.dfs.fabric.microsoft.com/<ws>/<lh>/Tables  -> HTTP 403  Forbidden

**So the criterion probes OneLake first, and only then decides what it is looking at.** Three
outcomes where there were two: OneLake readable, so the Fabric list means what it says and an
empty one is a real empty lakehouse; OneLake denied, so that list is UNOBSERVABLE and the
table list is read from the SQL analytics endpoint's own catalog instead, which a Viewer
demonstrably can read; neither, and the criterion reports `UNOBSERVABLE:` and is `-Final`,
because a denial is not a propagation artifact. Every run now records one line of positive
evidence naming which route answered (F162's shape):

    OneLake read: https://onelake.dfs.fabric.microsoft.com/... -> HTTP 403 (denied - so the
    Fabric /tables list this identity receives is UNOBSERVABLE, not empty) | table list read
    from the SQL analytics endpoint instead: INFORMATION_SCHEMA.TABLES on ... returned 10 dbo
    BASE TABLEs: cost_daily, findings_history, launches, ...

**The fix is deliberately NOT to give the auditor OneLake read.** Contributor is the lowest
Fabric role that carries it, and Contributor can write. Escalating the Verifier to make a
criterion convenient trades a stated architectural boundary for a table list; a test asserts
the audit never calls `Add-FabricWorkspaceRoleAssignment`.

**One honest cost, recorded in the criterion rather than left to be discovered:** the SQL
route cannot see an *extra* Delta table until the endpoint has synced it, so drift detection
over the fallback lags OneLake's. `TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo'` was
read off the live endpoint, not written from memory — it returns the ten seeded tables plus
exactly one `sys` VIEW, so an unfiltered catalog read would report permanent drift against a
correct lakehouse.

Mutation-tested: pretending observability is always established fails six tests; dropping the
`-Final` fails the window test on its own.

### F172 — a G0 step documented as "once per tenant" was bound to an identity every rebuild replaces *(fixed 2026-09-03)*

The same re-baseline, four layers later:

    [FAIL] V7.6  The data API answers with rows, not merely with a status code
                 observed: launch-ops http=502 rows=n/a; control-tower http=502 rows=n/a

    upstream_unavailable (502) detail=ConnectionError: Login failed for user '<token-identified principal>'.

`launches` is a **`sql`**-store table (`apps/data-api/src/contract/allowlist.ts`), so the 502
is Azure SQL, not the lakehouse — and it is the same root cause as the silently-failing grant
in the same job. **One defect, two symptoms.**

`CREATE USER ... FROM EXTERNAL PROVIDER` makes the SQL engine resolve the principal in
Microsoft Graph. An application cannot impersonate another application, so under CI the engine
falls back to **the SQL server's own managed identity**, which must hold the Entra "Directory
Readers" role. `docs/runbooks/g0-bootstrap.md` step 6 called that *"One assignment, once per
tenant"*.

**It was never once per tenant.** L6 creates the server in `mls-rg-data`; teardown deletes
that resource group; the server's **system-assigned** identity dies with it and returns under
the same NAME with a **new principal id**, and Entra removes the dangling role assignment
along with the deleted service principal. The grant stops existing the first time the estate
is rebuilt — the one thing this demo exists to do.

Read after the rebuild, not inferred:

    directory audit log   2026-09-01T12:23:23Z  success  mls-ops-demo-sql -> Directory Readers
                                                         (appId 4d541df8-e920-4603-8aa9-2e1ac6da0ead)
    current server identity principalId          031dbb19-9d2c-4832-bf78-be5480aa3a59
    its directory role assignments               0
    members of Directory Readers                 0

**The class: a NAME survives a rebuild and a PRINCIPAL ID does not**, so every check keyed on
the name still passes. The old F20 verification is exactly that check — it asked whether a
principal of this name existed, which a user left behind by a *previous* identity of the same
name satisfies while being unable to log in.

**Fixed by removing the dependency, not by automating the privilege.** The contained user is
now created with its SID supplied explicitly — for an application that SID is its
**application (client) id**, resolved from Azure at deploy time with `az identity show` — so
nothing asks Graph, no server identity is involved, and **no tenant-level privilege is needed
anywhere**. `Set-SeedWorkloadUser` (`data/seed/sql/sql-seed.psm1`) creates it, drops and
recreates a user whose SID belongs to a dead identity, adds `db_datareader`, then reads the
user, its SID and its role membership back out of `sys.database_principals` and throws on any
mismatch. `data/seed/sql/900-contained-users.sql` keeps only its `schema_version` row and the
explanation: two mechanisms creating one user, one of which must be allowed to fail, is the
two-copies-of-one-fact shape this repository keeps paying for.

**The one constant here that names something in another system is client-id-versus-object-id,
and this fix cannot verify it itself.** Comparing the SID we wrote against the value we wrote
it from is a mirror, not a test. What settles it is **V7.6**, which asks the running data-api
for a row over a real login — so a wrong SID leaves the criterion red rather than green. The
deploy step prints both GUIDs beside the grant for whoever reads the log next.

Automating the Directory Readers grant was considered and rejected: it needs Privileged Role
Administrator, `mls-github-deployer` holds no `AppRoleAssignment.ReadWrite.All` either, and
the runbook's own reasoning stands — *"an agent that can grant itself directory roles is
demonstrating something nobody wants to buy."* The right answer was to stop needing it.

### F173 — a step whose whole job is to announce a failure reported success *(fixed 2026-09-03)*

The L7 deploy job of the same run, verbatim:

    success  Apply the SQL contained-database user now that the identity exists (F20)
    success  Report a failed F20 grant pass          <-- this step RAN
    skipped  Report a failed F24 grant pass

The second line's **presence** means the first one failed. Its `success` means it succeeded at
saying so. The deploy job was green, and stayed green for the fifty minutes until V7.6 read a
row and could not.

`continue-on-error` on the grant step is **right** and stays: the `verify` job needs `deploy`
to succeed, so a transient PSGallery hiccup in an idempotent remediation would otherwise
starve the audit that would judge it — CLAUDE.md's own ruling on F119/F120. What it costs is
visibility, and the run's **step list is the surface people actually read**. So the reporting
steps now say what their presence means:

    FAILURE: the F20/F172 SQL contained-user grant did not complete
    FAILURE: the F24 Fabric workspace grant for data-api did not complete
    FAILURE: the F19 Fabric workspace grant for cost-ingest did not complete
    FAILURE: the Easy Auth redirect-URI registration did not complete

That fourth one was found by the check, not by the eye. This is F162's rule — *evidence that
cannot distinguish two states is not evidence* — applied to a run summary rather than a scan
report.

**Two things the fix turned up on the way, both worth more than the rename.**

**A green check over prose describing its own removal.**
`verification/tests/workload-rbac.Tests.ps1` asserted `900-contained-users.sql` matches `FROM
EXTERNAL PROVIDER`. After the statement was deleted the test **still passed**, because the
deleted statement is quoted verbatim in the comment explaining why it went. A capability moved
out of a file and its check stayed green on the paragraph describing the move. That is F27's
class — matching a string that lives only in a comment — and every assertion in the new sweep
strips comments before reading, in both PowerShell (`<# … #>` and `#`) and SQL (`/* … */`).

**Two copies of one fact, already diverged.** `workload-rbac.Tests.ps1` carried two private
copies of `Get-JobBody`/`Get-StepBody`. One had lost the `\r?\n` in its regex to a pair of
literal newline characters somewhere in an edit that went through a shell — CLAUDE.md's
control-character class, still matching by accident on an LF file — and only one learned to
accept a **quoted** step name, which YAML requires as soon as a name contains a colon. So the
rename above was found by one copy and thrown by the other. Deduplicated to one.

### F169 — 45.9 minutes spent on a verdict that was settled at minute zero *(fixed 2026-09-03)*

V3.1 fuses two questions under one criterion id and one retry window:

1. *Do the manifest's declared objects exist yet?* — legitimately propagation-sensitive.
   Entra object writes can lag 15-45 min (spec F6), so the criterion declares
   `-RetryWindowMinutes 45` and cites that.
2. *Is there a prefixed directory object the manifest does not declare?* — settled at the
   first poll.

**Propagation makes a declared object appear LATE. It cannot make an EXTRA object
disappear.** The second question's answer cannot change by waiting. It inherited the
window anyway, because it lives in the same function.

The 2026-09-03 rebuild paid that bill in full. `verify L3 (mls-verifier)` ran
**02:25:23Z -> 03:11:16Z, 45m53s**, re-asking a question answered at minute zero — while
the very same output line had already reported `users 5/5; groups 7/7; appRegistrations
4/4`, so the half the window exists for was complete before the first poll finished. That
is 45.9 minutes off the critical path of a kill/rebuild cycle whose headline claim is
under an hour.

CLAUDE.md: *a check declares how long it is willing to wait, and why.* The counts half
declares 45 minutes and names spec F6. The drift half now declares nothing: it returns
`New-MlsCheckResult -Final`, which `MlsAudit.psm1` already honours by breaking the retry
loop, and which `Test-ConditionalAccessState` has used since it was written for exactly
this reason ("wrong state or scope is not a propagation artifact"). A short count with no
drift still retries the full window, unchanged.

**This is the second time this window was paid for without being chosen.** Nineteen of
forty-seven criteria once inherited a 30-minute window nobody selected for them, including
one whose answer was settled the moment the deploy step returned. Inheriting patience is
the failure mode. The tell is a criterion that cannot say what it is waiting for.

### F168 — the drift exemption hardcoded the company prefix *(fixed 2026-09-03)*

`verification/layer-03-audit.ps1` resolved the prefix correctly on every line but one:

    $_ -notin @('mls-github-deployer', 'mls-verifier')

Two literals in the file whose whole job is to hold no independent knowledge of the
estate — and whose drift *messages*, two lines below, interpolate `$NamingPrefix`
properly. This is **F90's class in verification rather than configuration**: a rebrand
reaches Azure and leaves identity behind. After `MLS_COMPANY_PREFIX=acme` the sweep would
query for `acme`-prefixed applications, find `acme-github-deployer` and `acme-verifier`,
match neither literal, and **V3.1 would fail permanently on a correct estate**.

It never fired, because nothing has ever been rebranded — which is the same reason the one
wrong constant in the register's verification note survived as long as it did. A value
that is right until the day it is exercised is not observably wrong before then.

The list was also a **second source of truth for "which identities this estate has"**,
which is why it could not be extended without editing the Verifier. F167 is what that
cost. The exemption is now derived from `infra/entra/manifest.json`'s
`bootstrapAppRegistrations`, tokenised `${prefix}` like every other name in that file,
with no literal left in the audit. `verification/tests/failure-classes.Tests.ps1` gained a
repository-wide sweep for the shape — a file that resolves the prefix and then writes a
prefixed name by hand — because a class paid for once becomes a check.

**Not changed, and named so nobody thinks it was missed.**
`scripts/bootstrap/01-root-oidc.ps1` still *defaults* `-DeployerAppName` to
`'mls-github-deployer'` and `-VerifierAppName` to `'mls-verifier'`. Those are overridable
inputs to a human-run G0 script, not a check's private knowledge, and editing G0 on the
critical path of a running rebuild trades a real risk for a hypothetical one. A rebrand
must pass the new names there; nothing derives them.

### F167 — the check worked, and the scorecard had been wrong for two days *(fixed 2026-09-03)*

The 2026-09-03 rebuild stopped at `verify L3 (mls-verifier)`:

    [FAIL   ] V3.1  observed: users 5/5; groups 7/7; appRegistrations 4/4
                    | drift - mls-prefixed app registrations absent from the manifest: mls-purview

Every declared object resolved. The extra one is `mls-purview`, the certificate-bearing
Security & Compliance identity `docs/runbooks/g0-bootstrap.md` step 11c creates by hand.
It is entirely legitimate — Security & Compliance PowerShell has no federated path, which
is why hard rule 5 permits the certificate at all, and L4 cannot apply the label taxonomy
without it — and it was **declared nowhere a check could read**.

**V3.1 did not silently pass on this. It never ran.** The registration's
`createdDateTime` is **2026-09-01T18:23:48Z**. The last `infra-up` before the rebuild
started **2026-09-01T03:39Z** and had finished by 05:23Z; the last standalone
`layer-03-entra` run was **2026-08-31T19:13Z**. Both predate the object. The rebuild was
the sweep's first opportunity and it caught the drift at it — correctly, and on the first
poll. What it cost was 45.9 minutes to say so (**F169**), against an exemption list that
could not be extended without editing the Verifier (**F168**).

**What was wrong is this document.** The scorecard carried `L3 Entra | ✅ verified |
V3.1–V3.4 PASS` as a present-tense fact for two days after the tenant changed underneath
it. The row was true when written. Nothing in the file made it false, because nothing in
the file records what a verdict was observed against, or when it stops being an
observation and becomes a memory.

**The class is a verdict recorded at time T carried forward as current after the system it
describes changed**, and it is worth naming plainly because this scorecard is *made of*
such verdicts. Every ✅ row is a past observation written in the present tense against an
estate that is mutable by design and gets torn down on purpose. The sharp edge is that a
**rebuild is precisely the event that re-tests them all**, so the scorecard is least
reliable in the hours before one — which is exactly when a planner reads it to decide what
to run. The row now says blocked, pending re-run.

The repository fix is that `mls-purview` is declared in `infra/entra/manifest.json` under
**`bootstrapAppRegistrations`**, beside `mls-github-deployer` and `mls-verifier`: a key
`apply-entra.ps1` never iterates, with `Assert-ManifestSchema` refusing a name that
appears in both arrays. Declaring it in `appRegistrations` instead would have been worse
than the drift — on a tenant lacking it, L3 would create a **credential-less impostor**
with no certificate, no `Exchange.ManageAsApp` and no Compliance Administrator role, while
`PURVIEW_APP_ID` still named the old GUID, **and V3.1 would go green on it**, because a
registration resolving to exactly one object is all the count asserts. That is this
repository's most expensive shape: asserting the artefact where the control is the
capability. The sweep keeps its teeth either way, because the exemption is a per-name
entry in a reviewed, committed file rather than a pattern: `mls-purview-2` still fails.

**Same shape as F92.** `mls-copilot-authors` and `mls-sql-admins` existed in the tenant
and in no manifest, V3.1 correctly reported both as drift, and both times the manifest was
wrong rather than the tenant. Resolved the same way, by declaring. The audit now also
*reports* what it exempted — `bootstrap (not applied by L3) 3/3 present` — because before
that line a deleted `mls-verifier` and a present one produced the same green V3.1: a
bootstrap identity is in nobody's expected set.

**Still open, deliberately named:** `scripts/bootstrap/verify-g0.ps1` runs eleven checks
and none of them is `mls-purview`. G0's own verifier does not assert that step 11c
happened. L4 finds out — or does not, since all three Purview values missing makes the
apply job skip green with a notice (F43).

### F166 — the board reported a backlog and called it posture *(fixed 2026-09-02)*

The Sec tab said **88 open** and stopped there. The repository had also **closed 323 findings**,
and nothing surfaced it — the least flattering true sentence available was the only one on the
page. A backlog count answers *"what is wrong"*; the reader's actual question is *"are we
winning"*.

Two changes, both prompted by the sponsor:

**1. Posture over time.** The feeds now fetch every alert state, carry `fixed_at` / `dismissed_at`,
and the board charts opened against closed by date, with the totals in a **Findings closed** KPI.
The shape is lumpy — most findings arrived and were closed the day CodeQL first swept every image
— and that is the truth about a twelve-day-old repository rather than a reason to draw something
smoother.

**2. The seeded CVEs are a test feature, and now say so.** They live in `apps/vuln-lab` because
**V9.2 asserts CI FAILS on them** and passes once pinned. They are the evidence the pipeline
blocks vulnerable builds, so a board listing them beside real exposure reports the proof as though
it were the problem. The KPI is now **"Seeded CVEs (pipeline test)"**, and the sponsor's framing is
the right one: *"show that the CVE is purposeful as a test feature and not a break in our
security."* **Not closed, deliberately** — closing them would break V9.2 to improve a number.

**And the discrepancy a reader spotted is fixed.** The chart said 1 critical and the table said 2.
Both were right — the chart excludes seeded fixtures, the table listed everything — and nothing on
screen explained the gap, which is the F156 defect in a different panel. Seeded rows are now
marked `Dependabot (seeded)`. Mutation-tested, because the first version of this fix passed all
132 tests with the marking removed.

**The Dependabot trap, encoded.** `state=all` is valid for code scanning and **not** for
Dependabot, and GitHub answers the invalid case with an **empty list rather than an error**:

    dependabot/alerts             -> 10
    dependabot/alerts?state=open  ->  8
    dependabot/alerts?state=all   ->  0

The obvious symmetry with the code-scanning call would have silently reported zero dependency
findings. Checked against the live API before the code was written, and a test now asserts the
Dependabot URL never carries `state=all`.

**Future opportunity, noted not planned:** self-heal has two lanes, `dependabot` and
`code-scanning`, both application-facing. Infrastructure findings — the Defender assessments and
Azure Policy non-compliance lit up today — have no lane at all. An infra lane would need a
**what-if gate rather than a lint gate**, since F141 showed a Bicep change can pass every lint and
still fail at deploy.

### F165 — V9.5 asserted the security control should be OFF *(fixed 2026-09-02)*

Enabling Defender for Containers so the estate would produce posture (F153) made V9.5 fail, and
the sponsor put their finger on why: *"I think it was built on a false premise."*

They were right. The criterion required

    pricingTier == 'Free'                                  <- the END state
    AND paired Standard-then-Free writes in the window      <- proof it toggled

which encodes an assumption nobody ever stated: that this estate's normal condition is Defender
**switched off**, and the plan is turned on only briefly to demonstrate that turning it on works.
For a security demo that is backwards. The old failure text even called an enabled security
control *"a cost leak: disable immediately"*.

**Decision: the plan stays on.** ~USD 0.29/day, on a free trial until 2026-10-01 that outlasts
the demo window, and it is one of the five plans whose enablement took Defender's assessment
surface from 0 to 6 findings in seconds.

**This needed code, not just documentation**, and that was worth saying out loud. Leaving a
criterion permanently red while a document explains that the red is fine produces exactly the
thing this repository spends its budget avoiding: a failing check people learn to scroll past.
CLAUDE.md's own rule is that a finding with a test is closed and a finding with only prose is
open.

So V9.5 now asserts what the estate intends - **the plan is Standard** - and a DISABLED plan is
the failure, with a message that sends the reader to the G2 gate (and to
`freeTrialRemainingTime` first, since the delta is zero while the trial runs) rather than telling
them to switch protection off. The Activity Log write count is **reported beside the tier, not
required**: a quiet day with nobody touching the plan is the normal case, and failing on it would
make the criterion red most days.

Mutation-tested: restoring the old premise fails four tests. 21 L9 audit tests pass.

### F164 — sweeping today's classes across the repo, and what it found *(2026-09-02)*

The sponsor asked the right question: *"we have patterns we may need to scan on other layers like
this"*. CLAUDE.md's own rule says a class paid for once becomes a check, so the classes from the
DAST work were swept across the whole repository rather than left in L9.

**The sweep resolved F151 outright.** The two Key Vault secrets recorded as unaccounted-for are
not mysterious at all:

- **`mls-data-api-github-token`** is created by **G0 step 11b**, added 2026-09-01 for finding
  F116 - the read-only GitHub token behind Control Tower's Dev and Sec tabs. Entirely
  legitimate, fully documented in a runbook, and simply never added to rule 5's list.
- **`mls-github-token`** is its **pre-rename name**, left behind when 11b renamed it. A genuine
  orphan; rotate and delete it, which is a deletion and so the sponsor's call rather than mine.

Neither was dangerous. The finding is that a list which calls itself *"the complete list of
long-lived credentials"* - and which `gitleaks.yml` mirrors as the rotation runbook someone
follows after a leak - drifted from the estate silently, and the two documents agreed with each
other while both disagreed with the vault.

**Encoded:** every `az keyvault secret set --name X` in the runbooks must name X in CLAUDE.md
rule 5 **and** in gitleaks.yml's rotation table. Mutation-tested: removing one mention from
CLAUDE.md fails it. CLAUDE.md has always said those two must stay in sync; nothing enforced it
until now.

**Three working agreements added**, because these generalise past the layer that paid for them:

- *A probe must be made with the client that will make it* (F158)
- *A change is finished when a rebuild reproduces it, not when the thing works* (F159, F163)
- *Evidence that cannot distinguish two states is not evidence* (F162)

**Still open from the sweep, and worth someone's hour:** the feed contract is declared twice -
`apps/data-api/src/contract/feeds.ts` and `apps/control-tower/src/providers/types.ts` - with
nothing keeping them equal. F154 hit it (a field added to one arrived `undefined` from the other)
and the fixtures are parity-checked, but the *types* are not. Same shape as the credential list
and the two token mints: two copies of one fact.

### F163 — the token was minted in two places and only one was fixed *(fixed 2026-09-02)*

F162's proof step worked immediately, by producing **one line where there should have been
three**:

    mls-launch-ops-demo-ca: authenticated GET / -> HTTP 200, 638 bytes

launch-ops genuinely gets in - 200, real content. The other two never reached the proof at all,
because their token was empty.

**The cause: `zap.yml` mints a probe token in TWO places.** The classifier needs one to decide
whether an endpoint is an auth wall; the scanner needs one to scan through it. F161 corrected the
audience in the first and never looked for a second:

    line 202  --resource "$1"            <- fixed by F161
    line 389  --resource "api://${cid}"   <- missed

**And one app hid it.** launch-ops had an `identifierUris` I added by hand while testing the
approach, so `api://<clientId>` resolved *there and nowhere else*. A single app carrying a
manual fix made a broken code path look partly working - the same shape as F151 (the vault
holding two credentials the documented list did not) and F155 (a hand-written surface list
missing two apps). **Two copies of one fact, with nothing keeping them equal.**

**Encoded as a check**, because the next divergence will be just as quiet:
`failure-classes.Tests.ps1` now asserts every `get-access-token` in `zap.yml` requests the same
audience shape, and that there is more than one of them - so the check fails rather than passes
if the sites are ever consolidated and it starts reading the wrong thing. Mutation-tested;
reintroducing `api://` at either site fails it.

**The drift is cleared too.** The hand-added `identifierUris` is removed from
`mls-launch-ops-demo-app`, so the next run exercises the real path on all three apps with no
accidental help from a value I typed in a terminal.

### F162 — the scan could not tell a thin result from a blocked one *(fixed 2026-09-02)*

The run after F161 authenticated all three Easy Auth apps and produced this:

    mls-launch-ops-demo-ca      18 alerts   4 URLs    <- more than the anonymous scan saw
    mls-control-tower-demo-ca   17 alerts   3 URLs    <- identical to the anonymous scan
    mls-compliance-demo-ca      17 alerts   3 URLs    <- identical to the anonymous scan

launch-ops demonstrably got further with a token than without one. The other two returned exactly
what they had returned unauthenticated, down to the alert list - including
`Session Management Response Identified` and Easy Auth's own `SameSite` cookie.

**Two explanations fit that equally well, and the report cannot separate them:** an SPA with no
further crawlable URLs, because ZAP's passive baseline does not execute JavaScript and
client-side routes are invisible to it; or a scan still looking at the wall despite a token the
classifier accepted. One is fine. The other is F152 all over again.

**So stop inferring it from the report and record it at the source.** One authenticated request
per target, before the scan, with its status and body size written into the log:

    mls-control-tower-demo-ca: authenticated GET / -> HTTP 200, 1483 bytes

A 200 with real bytes means the token opens the door, and a thin scan afterwards is the
crawler's limit rather than the credential's. A 401 or a 302 means the classifier accepted a
token the application refuses - which **fails the job** instead of being read as "zero High-risk
alerts". A 200 under 200 bytes fails too: an empty page is not an application.

**Why this is the right shape.** Every previous fix in this chain made the scan *do* more; this
one makes the run *say* what it did. The distinction matters because three of the last four
findings here were not wrong behaviour but unreadable evidence - F152 (a verdict about a login
page), F158 (a classifier that never fired), F161 (a diagnosis built on the wrong cause). The
scan was never going to become trustworthy by adding capability. It becomes trustworthy by
recording what it actually reached.

### F160/F161 — two bugs in the authenticated scan, and F159's diagnosis was wrong *(fixed 2026-09-02)*

With the audience applied, launch-ops finally classified `content` and entered the scan matrix -
authentication worked. Then its scan **failed with no report at all**:

    FileNotFoundError: [Errno 2] No such file or directory: '/zap/wrk/onfig'

**F160.** `zap-baseline.py` owns `-c` for its own config file, so the `-config ...` options I
passed through `cmd_options` were parsed as `-c onfig` and the scan died before starting. The
empty-report gate caught it and failed the job - F102's fix earning its keep again - but a whole
run bought one fact. The action already forwards `ZAP_AUTH_HEADER`, `ZAP_AUTH_HEADER_VALUE` and
`ZAP_AUTH_HEADER_SITE` into the container, visible in its own `docker run -e ...` line. The
bearer now travels that way: no quoting to lose, and the token never reaches an argv that gets
echoed into the log at all.

**F161, and this is the one worth reading. F159's diagnosis was wrong.** I concluded Easy Auth
refused the token because its audience was not on the allowed list, and put
`allowedAudiences: ['api://${clientId}']` into the Bicep. The real cause was that I asked for the
wrong audience. `Initialize-VerifierProbeRole`'s own docstring says it plainly -

> Easy Auth validates only that a bearer token's audience matches the app's **client id**

- and V7.3 has been minting exactly that token for months:

    az account get-access-token --resource $clientId      # bare id, not api://

`--resource api://<id>` produces a different audience, which then needs an Application ID URI on
the registration to be requestable at all, which then needs that audience adding to
`allowedAudiences`. **Three moving parts to reach somewhere the repository already had a one-line
route to** - and launch-ops only appeared to work because I had hand-added an `identifierUris` to
it while testing, which the other two never got.

The Bicep change is reverted. It was unnecessary, and it carried a risk I had not established:
whether `allowedAudiences` REPLACES the default client-id audience rather than adding to it. If
it replaces, every interactive sign-in breaks. L7's V7.3 probes with precisely that audience, so
its verdict settles the question - which is the right way round: the estate's own criterion
answers it, not my recollection of the documentation.

**Settled by the estate's own criteria, not by recollection.** The L7 run after the change
reported **7 of 7 PASS**, including the two that answer this directly:

    [PASS] V7.3  OTel spans from a synthetic request visible in App Insights via KQL
    [PASS] V7.7  A human can complete an interactive sign-in

V7.3 probes with a token minted for the **client id** and passed with `allowedAudiences` set, so
the list is **additive** rather than restrictive - the default audience still works, and V7.7
confirms interactive sign-in is untouched. That also proves F161's route: a bare-client-id token
does get past Easy Auth on these apps.

**Residual drift, recorded rather than hidden:** the three live apps still carry the hand-applied
`allowedAudiences`. ARM's PATCH will not remove an array with either `[]` or `null`, so clearing
them needs a full authConfig PUT or the next L7 deploy from the reverted template. Demonstrably
harmless, per V7.3 and V7.7 above - but still drift, and the template no longer produces it.

**The lesson, which is the same one three times today:** the answer was already in the
repository, written down in the docstring of the function that creates the role. I read the code
that assigns the role and not the paragraph explaining why it exists.

### F159 — the audience the scanner needs existed only on the running apps *(fixed 2026-09-02)*

F158 fixed the classifier, and the next run told the truth: the three Easy Auth apps reported
`auth-wall`, and launch-ops logged

    mls-launch-ops-demo-ca: authenticated as the deployer via Telemetry.Probe -> auth-wall

A token was minted, injected, and **refused**. Easy Auth accepts an audience of the bare client
id by default — what a browser sign-in produces — while a client-credentials token requested by
resource URI carries `aud: api://<clientId>`, which the default does not accept. Coverage was
therefore an honest 3 of 6 rather than a fictional 6.

**The fix was one line of configuration, and I applied it in the worst possible place first.** I
patched `allowedAudiences` onto the three live apps from a hardcoded list in a terminal. Two
defects in one action:

1. **`validation` appeared ZERO times in `infra/bicep/apps/main.bicep`.** The setting existed only
   in the estate, so the next teardown-and-rebuild would have erased it and the authenticated scan
   would have silently stopped working. That is F129's class, F144's class and F155's class — and
   I was committing it *while* fixing that same class elsewhere.
2. **`az containerapp auth update --set` stored the quotes literally** — `'api://7820c65c…'`, 44
   characters including them. It rendered correctly in the formatted output and would never have
   matched a token. Caught only by printing the raw value and its length.

The sponsor's question — *"Are you hardcoding the values to scan?"* — is what surfaced it. The
scan targets were not hardcoded; the fix I was hand-applying to enable them was.

**Now derived, in the template:** `allowedAudiences: [ 'api://${clientId}' ]` on the shared
`authConfig`, interpolated from the same `clientId` the config already binds, so it cannot drift
from it and a rebrand or rebuild carries it automatically. Additive rather than restrictive —
naming an audience does not stop the default being accepted, and interactive sign-in was verified
unchanged (302 to Entra on all three apps, with the same client used before and after).

**The rule this keeps re-teaching:** a change that makes something work is not finished when the
thing works. It is finished when a rebuild reproduces it.

### F158 — the auth-wall detector never fired, because I tested it with the wrong client *(fixed 2026-09-02)*

The first authenticated multi-target ZAP run went green: six targets, six scans, zero High. The
merged report said otherwise.

    mls-launch-ops-demo-ca      alerts=17  distinct URLs=3   <- the login-wall signature
    mls-control-tower-demo-ca   alerts=17  distinct URLs=3
    mls-compliance-demo-ca      alerts=17  distinct URLs=3
    mls-mcp-demo-ca             alerts=9   distinct URLs=3

Three URLs and seventeen alerts is exactly the F152 fingerprint - `/`, `/robots.txt`,
`/sitemap.xml` and a report about Easy Auth's own cookies. And the run log contained **no
"authenticated as the deployer" line at all**: the auth branch never ran, because every Easy Auth
app had already been classified `content`.

**Why: I validated the classifier with a different HTTP client than the one that runs it.** My
probes used PowerShell's `Invoke-WebRequest`, which sends browser-like headers and gets a **302 to
login.microsoftonline.com**. The workflow uses `curl`, which sends no `Accept` header — and Easy
Auth answers a non-browser caller with **401 and no redirect at all**:

    $ curl -s -o /dev/null -w '%{http_code}'   ...  ->  401
    $ curl -s -o /dev/null -w '%{redirect_url}' ...  ->  (empty)

So `redirect_url` never matched, 401 is not `000`, and every Easy Auth app fell through to
`content`. **The protection F152 added has never once fired in CI**, and F157 built authentication
on top of a gate that was already open.

**The signal was in the response the whole time.** Easy Auth identifies itself, and names the
audience to ask for:

    www-authenticate: Bearer realm="..."
      authorization_uri="https://login.microsoftonline.com/<tid>/oauth2/v2.0/authorize"
      resource_id="7820c65c-2ac3-4242-a283-aedbc705e03f"

A genuine application 401 carries no `authorization_uri` — the MCP server answers
`Bearer realm="mcp-tools"` and is real content that *should* be scanned. So presence of
`authorization_uri` is the classifier, and `resource_id` removes the `az containerapp auth show`
lookup entirely: the challenge tells you which token to fetch.

**Tested against every real case before shipping this time**, which is the whole lesson:

    launch-ops    auth-wall  resource_id=7820c65c...   control-tower auth-wall  resource_id=88106f53...
    compliance    auth-wall  resource_id=302b0835...   mcp           content    (genuine app 401)
    directline-func  content                           cost-ingest-func content

**The class, stated plainly:** *a probe must be made with the client that will make it.* Status
codes are content-negotiated, and validating a check against a friendlier client than production
uses is the same defect as F135 and F142 — verifying the half in hand and assuming the half that
matters.

### F157 — the DAST now gets past the login page *(2026-09-02)*

F155 made ZAP scan every *reachable* endpoint. Three remained unreachable by construction: the
Easy Auth apps, correctly reported `auth-wall` rather than passed. This closes that.

**The mechanism already existed and nobody had connected it.** `infra/entra/manifest.json`
declares `verifierProbeRole: Telemetry.Probe` on all three apps — launch-ops, control-tower and
compliance — and `mls-verifier` already held it. The estate had a designed way for a trusted
identity to probe past Easy Auth, and the scanner simply was not using it.

**As the deployer, NOT the Verifier.** `mls-verifier` holds the same role and CI has its
credentials, which makes it the tempting choice. CLAUDE.md says the Verifier runs only code in
`verification/`, and `zap.yml` is not that; blurring it to save one role assignment would trade a
stated architectural boundary for convenience. Granting `mls-github-deployer` a read-only probe
role on apps it created itself is no escalation.

**Degrades safely, which is the property that matters.** A target is classified anonymously
first — that is what an internet attacker sees, and for the Functions and the MCP server it is
the whole story. Only an `auth-wall` is retried with a token. If no token can be minted the
endpoint stays `auth-wall` and is reported, never scanned-and-passed on a redirect.
**Authentication failing costs coverage, never honesty.**

**A secret nearly went into the logs.** The first version carried the bearer token in the matrix
entry. Matrix values appear in the job name, the run summary and the logs, so that would have
published a token for every scanned app. Only the boolean `auth` travels now; the scanning job
mints its own token and `::add-mask::`s it before use. Worth recording because it was caught by
re-reading rather than by any check — nothing in this repository would have failed.

**Verified before wiring:** the role assignments landed on all three apps. **Not verified
locally:** the client-credentials token exchange, which needs a federated credential only CI
holds. CI is the test, and the safe-degradation design is what makes that acceptable — a failure
reports `auth-wall`, which is exactly what the register already says today.

### F156 — the cost donut dropped services silently, so new spend could vanish *(fixed 2026-09-02)*

Asked to make sure newly enabled Defender spend reaches the Ops tab, the plumbing checked out:
the Cost Management query groups by `ServiceName` with **no filter**, and the "Run cost by
service" table lists every row. Defender appears there by construction.

**The chart above it did not.** `Cost by Azure service` charted `byService.slice(0, 8)` and
discarded the tail, so:

- the ring totalled **less** than the "Total run cost" KPI printed directly above it, and
- a small line simply vanished — which is precisely what a Defender plan billing cents beside a
  database billing dollars would do.

Five Defender plans were enabled today. Each is individually tiny next to Azure SQL, so all five
would have fallen off the ring while the total silently disagreed with itself.

**Fixed:** the tail is grouped as `Other (N services)` rather than dropped, so the ring
reconciles with the total and the chart says how many it summarised. Mutation-tested — restoring
the plain `slice` fails three tests, including one that plants a cent-sized
`Microsoft Defender for Cloud` line and asserts it survives into the total.

**A cost chart that does not add up is worse than no cost chart**, because it invites arithmetic
a reader will trust.

**Not fixed, and worth stating:** the Ops tab shows what is billing, not what is *about to*.
All five Defender plans are on free trials that expire **2026-10-01/02** — about ten days after
the 30-day demo window closes. Nothing on the tab would warn anyone that a $0 line becomes a real
one on that date. Surfacing trial expiry needs a feed that carries it; `az security pricing list`
returns `freeTrialRemainingTime`, so the data exists.

### F155 — the attack surface was written by hand, so two internet-facing apps were never scanned *(fixed 2026-09-02)*

F152, earlier the same day, enumerated the estate's external surface and listed **four** entries.
The sponsor's reaction — *"I think we have more than 3 container apps, our documentation is
probably out of date"* — was right, and understated it. Read live:

    mls-control-tower-demo-ca   external   Easy Auth
    mls-launch-ops-demo-ca      external   Easy Auth
    mls-compliance-demo-ca      external   Easy Auth
    mls-mcp-demo-ca             external   app-level bearer only
    mls-data-api-demo-ca        INTERNAL   -
    mls-vuln-lab-demo-ca        no ingress -
    mls-cost-ingest-demo-func   external   NONE  -> HTTP 200 anonymous
    mls-directline-demo-func    external   NONE  -> HTTP 200 anonymous

**Two Function Apps, internet-facing, answering 200 to an anonymous caller with no platform
auth, that no scan had ever touched** — and that F152's own list omitted, because that list was
written by hand and stopped at container apps. They are not even in the same resource group
(`mls-rg-ops`, not `mls-rg-apps`), which is exactly the sort of detail a hand-written inventory
loses.

**The class:** a surface written down is a surface that goes stale the next time someone
deploys. F144 taught the same lesson about one hostname; this is the same defect applied to the
*set* rather than to a member of it. An inventory that is not derived is a guess with a
timestamp.

**Fixed by enumerating instead of listing.** `zap.yml` now asks Azure every run which Container
Apps have `ingress.external` and which Function Apps are running, classifies each anonymously
(`content` / `auth-wall` / `unreachable`), and scans every one that answers with content. The
scan is a **matrix**, `fail-fast: false` — a run is an expensive observation and returns
everything it saw, so one endpoint's High-risk alert must not cancel five other scans.

**The audit contract is untouched.** A merge job combines the per-target reports into the single
`zap-baseline-report` artifact V9.4 already downloads by name, so the criterion now asserts zero
High across **every reachable endpoint** rather than across one, with no change to
`layer-09-audit.ps1`. The merge runs on `always()`, because a target that failed its own gate
still produced a report and hiding it would hide the findings worth having.

**Still open:** the three Easy Auth apps remain unscannable by an unauthenticated baseline, and
are correctly reported as `auth-wall` rather than passed. An Application ID URI was added to
`mls-launch-ops-demo-app` to make an authenticated scan possible; minting a token then failed
`AADSTS65001 consent_required`, so it needs an app-role assignment for the CI service principal.
That work is not done, and the criterion says so rather than implying coverage it does not have.

### F154 — the security board understated severity, trebled the work, and counted a fixture as exposure *(fixed 2026-09-02)*

Three defects on one panel, found by looking at it rather than by a check.

**1. High rendered GREEN.** The bar chart set no colour, so the chart library assigned from a
*categorical* palette by index: Critical blue, **High green**, Medium and Low pink. Green is the
one colour that reads as "fine", sitting on the second-most serious bar on a security board.
Colour was working against the reader. Severity colour is now explicit, ranked and semantic, and
a test asserts every bar carries one.

**2. "88 open alerts" is 30 distinct findings.** The container scan raises the same base-image
CVE once per image, so three images treble every finding. The count was true and overstated the
real work roughly threefold — in a repository whose entire argument is that it does not overstate
itself. The board now leads with **distinct findings** and reports **alert instances** beside it,
and the chart's own subtitle says how many collapsed into how few.

*(An earlier note in this session put the distinct count at "about 6", reasoning from the top-6
rule IDs. It is 30. Counting beats inferring.)*

**3. One of the two open criticals is a deliberate fixture.** `CVE-2021-44906` is seeded in
`apps/vuln-lab` for L9's negative test — V9.2 exists to prove CI fails on it. The board could not
tell it from real exposure, because **`manifest_path` was dropped by the data-api's projection**,
so the only field that distinguishes them never reached the browser. It is now carried, seeded
alerts are counted separately as **"Seeded for the demo"**, and they are **labelled, never
hidden** — removing them would be the mirror-image lie.

The sharpest evidence is in the test fixture: **High falls from 2 to 1**, because its only
high-severity dependency alert is a seed. Mutation-tested both ways — counting seeds as real
fails three tests, dropping the colours fails a fourth.

**Two things this turned up on the way:**

- **The feed contract is declared twice** — `apps/data-api/src/contract/feeds.ts` and
  `apps/control-tower/src/providers/types.ts` — with nothing keeping them in step. A field added
  to one and not the other arrives `undefined` at runtime, with no error and no test. Both now
  carry a note; the drift risk deserves its own check.
- **`dependabot/alerts?state=all` returns an empty list.** No state parameter returns 10, and
  `state=open` returns 8 — but `state=all`, which is valid for *code scanning*, is not valid here
  and GitHub answers it with `[]` rather than an error. Anyone writing the obvious query gets
  zero Dependabot alerts and no indication anything is wrong. It was checked before the trend
  chart was built on it.

**Deferred deliberately:** the opened/closed-over-time chart the sponsor asked about. The data
supports it — 411 code-scanning alerts, every closure dated — but 390 of the opens and all 323
closures fall on **2026-08-29**, the day CodeQL first swept every image. The chart would be one
column and two slivers: true, and a picture of a single scan rather than a working find-and-fix
cycle. It gets built when the rebuild gives it a second data point.

### F153 — Defender has never assessed this subscription, and nothing noticed *(criterion added 2026-09-02)*

The sponsor direction's phase 3 promises **"Defender scans producing real posture"**. There is
none, and there never has been:

    GET .../Microsoft.Security/secureScores?api-version=2020-01-01   -> empty
    GET .../Microsoft.Security/secureScores/ascScore                 -> ResourceNotFound
    GET .../Microsoft.Security/assessments?api-version=2021-06-01    -> empty

Read at the REST layer, not through the CLI, so this is not a stale api-version artefact. The
MCP server's `get_defender_posture` fails `404 Secure score 'ascScore' does not exist` for
exactly this reason — the tool is right and the estate is empty.

**Nothing asserted it.** V9.5 checks that the Defender plan can be toggled on and off. A plan
that toggles perfectly and assesses nothing passes V9.5. That is the plumbing-without-water gap
§ D describes, in the security layer.

**The trap, and why the new criterion names it.** The Azure **Policy** half works:
`ASC Default` (`SecurityCenterBuiltIn`) is assigned and evaluating — **6 non-compliant resources
across 35 policies**. So an operator who asks "is the security initiative assigned?" gets *yes*
and concludes Defender is healthy. Assessments and secure score are a **different pipeline**, and
they are the one the demo reads. V9.6's failure message says this outright so the reader is not
sent to re-check an assignment that is already there.

**V9.6 added:** at least one secure score OR at least one assessment. Three outcomes, not two —
an endpoint that does not answer is **UNOBSERVABLE**, never "Defender produces nothing", because
reporting an absent control on the strength of a failed read is the class this repository pays
most for. Both failure paths are `-Final`: Defender's assessment surface fills over hours, so a
five-minute retry cannot change the verdict and must not spend the wall clock reaching the same
one. Mutation-tested; 21 L9 audit tests pass.

**Cause not established, deliberately.** `FoundationalCspm` and `Discovery` are `Standard`, the
provider is registered, 30 resources exist and 1,302 assessment definitions are visible — yet no
assessment has ever been produced. That is recorded as the observation it is rather than a
diagnosis, per the register's own habit of distrusting confident first explanations.

### F152 — the ZAP scan has been assessing a login redirect *(fixed 2026-09-02)*

V9.4 passes. It asserts "ZAP report artifact exists with 0 High", and that is a true statement
about **a door**.

`launch-ops` runs behind Container Apps Easy Auth with
`unauthenticatedClientAction: RedirectToLoginPage`. An anonymous request gets a **302 to
login.microsoftonline.com with a zero-length body**, so an unauthenticated baseline scan never
reaches the application. Pulled from the last run's own artifact:

    sites scanned            : 1
    distinct URLs in alerts  : 3   ->  /   /robots.txt   /sitemap.xml
    alerts                   : 17  ->  all describing the REDIRECT

Every finding is about Easy Auth's own response: "Cookie with SameSite Attribute None" (Easy
Auth's cookies), "Session Management Response Identified" (the login flow), CSP and
anti-clickjacking headers missing **on a 302**. Zero application URLs were assessed.

**Third time this criterion has reported a verdict it never earned.** F102: the gate step was
skipped and its failure read as a security failure. F144: the target was a hostname from an
environment that no longer existed. Now: the target resolves, answers, and is a login wall.

**Why it cannot simply be authenticated.** Checked before designing anything: the launch-ops app
registration has **no `identifierUris` and no exposed OAuth2 scopes**, so no token can be minted
for its audience — `az account get-access-token --resource api://<clientId>` returns
`AADSTS500011: resource principal not found`. Easy Auth there is interactive sign-in only.
Adding an API audience so a scanner can get in would widen a UI app's auth surface for the
scanner's benefit, which is a poor trade; driving a real user login needs a stored password,
which is a rule-5 credential.

**Fixed by scanning what an unauthenticated attacker actually reaches, and by refusing to call
the other thing a pass.** The estate's real external surface, enumerated:

    mls-control-tower-demo-ca   external   Easy Auth (RedirectToLoginPage)
    mls-launch-ops-demo-ca      external   Easy Auth (RedirectToLoginPage)
    mls-compliance-demo-ca      external   Easy Auth (RedirectToLoginPage)
    mls-mcp-demo-ca             external   NO platform auth - app-level bearer only
    mls-data-api-demo-ca        INTERNAL   -
    mls-vuln-lab-demo-ca        no ingress -

`zap.yml` now classifies the target anonymously before scanning (`content` / `auth-wall` /
`unreachable`), scans the **API surface** when the app is a wall, and the gate **fails as
UNOBSERVABLE** when nothing but a redirect was assessed. A "0 High" that describes a login page
can no longer be recorded as a pass.

### F151 — the closed credential list was not closed *(closed 2026-09-02)*

CLAUDE.md rule 5 states "the complete list of long-lived credentials" and names two Key Vault
entries. **The vault holds four.** Alongside the Direct Line secret and `mcp-auth-token` it
carries `mls-github-token` and `mls-data-api-github-token`, which are referenced **nowhere** in
`infra/`, `.github/` or `apps/`.

The list is closed precisely so this cannot happen, and it happened anyway. The cost is not
hypothetical: `gitleaks.yml`'s incident text is the rotation runbook, and it agreed with
CLAUDE.md rather than with the vault — so a leak would have rotated four credentials and left
two behind, unnoticed, because nothing named them.

**Contained, not resolved.** Both are now in the rotation table and CLAUDE.md records the
discrepancy. What is still owed is the decision: establish whether anything reads them by a name
built at runtime, then either rotate-and-delete them as orphans or promote them into the list
with a written reason. **Do not delete on the strength of a grep** — F147 is a fresh reminder
that a value can be read under a name no static search will match.

Found by taking a census rather than by a check, which is itself the finding: nothing asserts
that the vault's contents match the documented inventory. That is a cheap check nobody has
written.


**RESOLVED 2026-09-02.** Both secrets are accounted for, and the sponsor confirmed the GitHub
side independently: repository and environment secrets are **exactly the six** rule 5 documents,
with nothing extra. The discrepancy was Key Vault only.

- `mls-data-api-github-token` — legitimate. G0 step 11b creates it for F116; it is the read-only
  GitHub PAT behind the control tower's Dev and Sec tabs. Now named in rule 5 with that reason.
- `mls-github-token` — its own pre-rename name. The timestamps settle it: 13:53 versus 18:09 the
  same day. **Key Vault has no rename**, so a rename is create-new plus delete-old and only the
  first half happened. Nothing read it. **Deleted**; soft-delete retains it until 2026-12-02.

The vault now holds three secrets and rule 5 names all three. What makes this closed rather than
merely tidied is F164's sweep: every secret a runbook creates must be named in rule 5 *and* in
gitleaks.yml's rotation table, so the list cannot quietly stop being complete again.

### F150 — my recovery link signed the user out and left no way back *(fixed 2026-09-02)*

F149 shipped a "Sign in again" link. The sponsor clicked it, chose their account, **was signed
out**, and landed on:

> **Agent unavailable** Could not read this session's Entra token from /.auth/me...

Worse than the expired token it was meant to repair, and the message offered nothing.

**Two mistakes, one in each half.**

**The link pointed at `/.auth/logout`.** The reasoning was that ending the session would let the
app's own `unauthenticatedClientAction: RedirectToLoginPage` start a fresh flow. It does not
reliably: the post-logout redirect lands on `/`, which the browser can answer **from its own
cache** - the SPA shell was already loaded - so the page renders with no session and never
reaches the middleware that would have redirected it. `/.auth/login/aad` re-runs the
authorization-code flow *keeping* the session, and is a server endpoint that cannot be cached.

**Verified against the deployed app this time rather than reasoned about:**

    GET /                                           302 -> login.microsoftonline.com
    GET /.auth/me                                   302 -> login.microsoftonline.com
    GET /.auth/login/aad?post_login_redirect_uri=/  302 -> login.microsoftonline.com
    GET /.auth/logout?post_logout_redirect_uri=/    302 -> login.microsoftonline.com

**And `readEasyAuthToken` could not tell "signed out" from "no token".** `/.auth/me` answers an
unauthenticated caller with a **302**, and a default `fetch` follows it to
login.microsoftonline.com where CORS throws - so both states collapsed into one null and one
message. It now reads with `redirect: "manual"` and returns three outcomes: a token, **signed
out** (offer the link), or **signed in with no token in the store** (F135's case - offer nothing,
because signing in again cannot fix a deployment).

**The test that should have caught it asserted the defect.** `it("ends the session rather than
just visiting the login endpoint")` passed, because it encoded exactly the same wrong assumption
as the code. A test written from the same mistaken premise as the implementation is not
independent evidence - it is the premise, restated. It is now inverted and says why.

Mutation-tested both ways: restoring the logout URL fails three tests, removing
`redirect: "manual"` fails a fourth. 121 passing.

**Standing limitation, not a defect:** the link is the correct FALLBACK, but it should be rare
rather than hourly. It is hourly because Easy Auth here has no client secret and no
`offline_access`, so no refresh token exists. Configuring both makes renewal silent - at the cost
of a long-lived credential, which is a rule-5 decision and not one to take quietly.

### F149 — I fixed the expiry with a refresh the provider cannot perform *(fixed 2026-09-02)*

F142's fix reached the browser and produced exactly the message it was written to produce:

> **Agent unavailable** This sign-in has expired, so the Ask tab cannot prove who is asking.
> Reload the page to sign in again - the agent itself is fine.

**Both halves of that fix were wrong, and the configuration says so plainly:**

    az containerapp auth show -n mls-control-tower-demo-ca ...
      identityProviders.azureActiveDirectory.registration
        clientSecretSettingName : (none)
        login (scopes)          : (none - so no offline_access)

Redeeming a refresh token is a **confidential-client grant**. With no client secret and no
`offline_access`, **no refresh token is ever issued**, so `/.auth/refresh` had nothing to redeem
and could not have succeeded on any run. And the fallback advice was equally empty: **reloading
does nothing**, because the session cookie is still valid and Easy Auth serves the SAME stored
token rather than re-authenticating. That is precisely why an Incognito window worked and F5 did
not - evidence that was already in hand when F142 was written.

**This is F135's class for the third time in two days.** F135: verified a token without checking
one could be obtained. F142: verified expiry without asking what happens when it expires. F149:
wrote the renewal without asking whether renewal was possible. Each time the code was careful
about the half already in hand and silent about the half it depended on.

**Fixed with what the provider can actually do.** Ending the Easy Auth session and letting the
app's own `unauthenticatedClientAction: RedirectToLoginPage` run the login flow again needs no
credential; Entra answers it from the live browser SSO session, so it is normally a redirect
rather than a password prompt, and it puts a new `id_token` in the token store. The error now
carries a `signInUrl` and the tab renders **a link the user clicks** - never an automatic
navigation, which is how one bad token becomes a redirect loop. The link is present ONLY for an
expired sign-in: a 500 offers none, because signing in again would not fix the deployment.

`/.auth/refresh` is kept but is no longer load-bearing - a fork that configures a client secret
gets silent renewal from it for free - and its comment now states the precondition instead of
assuming it. Mutation-tested: removing the recovery URL fails the test. 118 passing.

**Checked at the same time, because the sponsor asked whether the two tabs trade off:** they do
not. `data-api` over the last 24 h shows `GET /feeds/:name` **200 x 98** and **304 x 21**, latest
17:12 UTC, with the last **502 at 15:19 UTC** and none since - the F139/F140 cost-cache work
holding. Ops and Ask are independent subsystems that happen to share a page; nothing about
fixing one has ever broken the other.

### F147 — the eval looked for the Direct Line secret under a name nothing creates *(fixed 2026-09-02)*

L8's eval job has reported, on every run:

    mls-sec-demo-kv holds no 'directline-secret', so the agent cannot be evaluated
    and no artifact was produced.

**The vault holds `mls-directline-secret`.** The estate names it in the `demo` environment
variable `MLS_DIRECTLINE_SECRET_NAME`, which is what L6 hands the Bicep and what the Function's
Key Vault reference resolves - V6.8 confirms that reference resolves, so the secret has been
readable all along. The eval job hardcoded `directline-secret`, the name in the **G0 bootstrap
runbook**, and never read the variable.

**The invisible-value class again** (F122, F123, F124, F125): a value that exists, is spelled
correctly, and cannot be seen by the thing that reads it. What makes this one expensive is the
MESSAGE - "holds no 'directline-secret'" reads as *nobody has created it yet*, and it sent a
reader off to publish an agent and mint a secret that had been in the vault for a day.

**Four criteria skipped on it - V8.2, V8.3, V8.4, V8.5 - on every run, while the job reported
success**, which is correct: skipping cleanly is exactly what that job is designed to do when it
cannot evaluate. Nothing was lying. The wrong name simply meant it could never evaluate.

**I repeated the error in my own reporting**, which is worth recording: I told the sponsor the
Direct Line golden-question eval "passed" after the 1.0.3.0 import, and offered it as evidence
the agent still answered. It never ran. A job whose success means "I correctly declined to do
anything" is not evidence that the thing works.

**Fixed:** the job reads `vars.MLS_DIRECTLINE_SECRET_NAME`, and distinguishes the two states
that used to collapse into one message - an **unset variable** is configuration, a **missing
secret** is the G0 item, and they need different fixes. Encoded as a class: `az keyvault secret
show/set --name` must take an expansion, never a literal, because a name written in a workflow
is a second source for a value the environment already owns and outranks it silently. Mutation-
tested.

### F146 — I broke L9's startup with F144's own fix *(fixed 2026-09-02)*

The full L9 run dispatched to **prove** F144's fix reported:

    conclusion: startup_failure     jobs: []

No jobs, no logs, no annotation naming the cause. A reusable workflow cannot ask for a
permission its **caller** has not granted, and `zap.yml` had just started needing
`id-token: write` to read the live ingress FQDN. `layer-09-devsecops.yml`'s `zap:` job granted
`contents: read` and nothing else, so the whole workflow refused to start - not the one job at
fault, the whole thing.

**The diagnostic is the finding.** Every other failure in this repository leaves a log to read;
this one leaves an empty array. That makes it exactly the shape worth spending a check on, and
`verification/tests/failure-classes.Tests.ps1` now unions every `write` permission any job in a
called workflow declares and asserts the calling job grants each one. Deliberately over-strict:
it does not reason about which callee jobs actually run, because a caller granting slightly more
than one run needs is a far cheaper mistake than a workflow that cannot start. Mutation-tested -
removing the grant fails it, naming the job, the callee and the permission.

Worth stating plainly: **the check that would have caught this did not exist because I wrote the
defect and the fix in the same change.** F144 was verified as YAML that parses; nothing asked
whether the caller could satisfy what the callee now asked for.

### F145 — V8.1 could never have passed, and the recorded reason was wrong *(fixed 2026-09-02)*

The L8 run that imported solution 1.0.3.0 reported:

    [FAIL] V8.1  Deployed agent's solution ... match the committed solution exactly
           observed: components missing [] extra [Conversation Start, Conversational
           boosting, End of Conversation, Escalate, Fallback, Goodbye, Greeting,
           Meridian Launch Copilot, Meridian Ops Tools, mls_MeridianLaunchCopilot.
           shared_..., Multiple Topics Matched, On Error, Reset Conversation,
           Sign in , Start Over, Thank you]

**Sixteen confident, specific, wrong names.** Every one is a legitimate component of the agent,
committed to this repository, and a reader would have gone hunting for drift that does not
exist.

**The register's recorded cause - "V8.1 still fails on a Verifier Dataverse read permission" -
was wrong.** The read succeeded on every run; that is where the sixteen names came from. This is
why CLAUDE.md says to check a blocker's evidence yourself before acting on it.

**The real defect: the expected set was built from one of three files.** `Other/Solution.xml`
lists *root* components - one, the connector - while `msdyn_solutioncomponentsummaries` reports
*every* component, because a Copilot Studio agent's topics belong to the solution without being
roots of it. Set equality between those two vocabularies could never hold. **A criterion that
cannot pass is not a strict criterion, it is a broken one**, and it hid the question it existed
to ask.

**The committed side is fully enumerable, so the fix makes the check stronger, not weaker:**

    Other/Solution.xml                  RootComponent/@schemaName                     1
    botcomponents/*/botcomponent.xml    <name>                                       15
    Assets/botcomponent_connection...   @connectionreferenceid.…logicalname           1
                                                                                 -----
                                                                                    17

which is exactly what Dataverse reported. `<name>` is returned verbatim in `msdyn_name` - down
to the trailing space in `'Sign in '` - so the comparison stays exact rather than normalised; a
helper that trimmed there would hide a real rename behind a cosmetic one. V8.1 now compares
seventeen components where it compared one.

**Unobservable, never absent.** If the component files cannot be enumerated the criterion says
so. A truncated expected set turns every deployed component into an "extra", which is precisely
how this produced sixteen false names rather than one honest "I could not read the expected
list".

**A second defect fell out of the first, and it is the more instructive one.** V8.3 counted
"tool/connector components" by filtering the *same* list for `connector|connection|tool|agent`.
Enriching that list for V8.1 silently widened V8.3: a topic whose display name is
**"Meridian Ops Tools"** would have counted as a tool, and V8.3 would have failed on a correct
solution - trading one broken criterion for another. Widening one check's input widened a
different check's meaning. Roots and connection references are now their own fields: two
questions, two lists.

**The fixture was part of the problem.** It wrote a lone `Solution.xml` into a temp directory,
so it exercised a parse the production code no longer performs and would have stayed green
while the thing it stands for was broken. It is now a real solution tree.

Twenty L8 tests pass, four of them new.

### F144 — the ZAP scan has been pointed at a host that does not exist *(fixed 2026-09-02)*

An L9 diagnostic run to re-check V9.1 turned this up on the way past:

    Job spider failed to access URL
    https://mls-launch-ops-demo-ca.thankfulisland-7f9b1aba.centralus.azurecontainerapps.io
    check that it is valid : Name or service not known

The live app answers on `...happymeadow-9e15a087...`. `vars.STAGING_URL` was set at
2026-09-01T00:19Z and was correct then; the apps environment was recreated later that day
while fixing F129, and **a Container Apps environment domain is assigned at creation and
changes on every rebuild** - the one thing this demo exists to do. So every ZAP baseline since
has scanned nothing.

**This is F129's class and F90's before it**, in the one place the existing sweep cannot see: a
GitHub variable is not a committed artifact, and an absent or stale variable is a well-formed
string rather than an error.

**The gate behaved correctly, and that is the good news.** The scan produced no report and the
step said *"An unreachable target is a FAILURE, not a pass (L09 V9.4)"* rather than passing on an
empty result. That is F102's fix working on a defect nobody had found yet.

**Two things were wrong, not one.** The target was stored rather than derived; and the
resolution step asserted the URL was well-*formed* without asking whether it was
**reachable** - so the failure surfaced as `docker failed with exit code 3` inside a
third-party action, which names the symptom and not the cause. That is F135's rule again:
verify the input can be obtained before verifying that it is valid.

**Fixed:** `zap.yml` reads the live ingress FQDN from Azure and prefers it; an explicit
`target_url` input still wins; `vars.STAGING_URL` is a last resort for a checkout with no Azure
credentials, and when it disagrees with the live value the run says so rather than silently
preferring or silently ignoring it. The target must now resolve in DNS before the scan starts.
The Azure-login guard is a **step-level** `if:`, because a job-level one is evaluated before the
environment resolves and would mean "skip always" (F125).

**Encoded as a class:** a job that reads a stored estate hostname must derive the live one in
the same job. Mutation-tested - breaking the derive fails it. On its first run the sweep flagged
`layer-09-devsecops.yml` too; that one was prose drift in an input description rather than a
second hole, and the description was corrected.

### F143 — one idle database is 99% of the bill, and auto-pause is working correctly *(accepted 2026-09-02)*

Measured directly from Azure Monitor rather than inferred, because Cost Management was
throttling (F140, and retrying deepens the window):

    mls-launch-ops-demo-sqldb   GP_S_Gen5 serverless, min 0.5 vCore, max 2, autoPauseDelay 60
    31 Aug 00:00 - 2 Sep 18:00Z (66 h): 61,596 vCore-seconds billed = 17.1 vCore-hours
    app_cpu_billed non-zero in 34 of 66 hours; cpu_percent non-zero in only 16

Month-to-date spend is **$7.70**, of which **$7.65 is SQL**. Everything else in the estate -
five Container Apps, two Function Apps, storage, Log Analytics, Key Vault - is four cents.

**Auto-pause is not broken. V6.4 is not lying.** Long stretches bill exactly zero, which is the
proof. Two things about the shape of serverless billing make an idle database expensive anyway:

1. **Every connection buys a minimum of 60 minutes online.** 60 minutes is the *floor* Azure
   allows for `autoPauseDelay`; it cannot be set lower. A single one-connection wake at 02:17
   costs a full hour.
2. **While online but idle it bills ~0.68 vCore/hour, above the 0.5 floor.** Serverless bills
   `max(CPU, memory/3GB)`, and `cpu_percent` is non-zero in half as many hours as
   `app_cpu_billed` - so this is the memory of a warm cache, not work being done.

**What wakes it, and none of it is wrong:** `data-api` serving the Ops tab (the daytime
clusters), `compliance.yml` at 02:17 daily, `self-heal.yml` every six hours at :13. Those are
the estate verifying itself, which is the thing this repository is *for*.

**So this is a decision, not a defect, and it is the sponsor's:**

- **Do nothing.** ~$120 of a $200 ceiling over the remaining 30 days. It fits, with less
  headroom than the old $1.40 figure implied.
- **Wake it less.** Drop `self-heal.yml` from every 6 hours to daily: up to 3 fewer hour-long
  wakes a day, maybe $1.50/day. It costs self-healing latency, on the one showpiece that is
  still not demonstrated.
- **Ask whether the database is needed at all.** The lakehouse already holds the launch data,
  and `data-api` reads Fabric for most feeds. If Azure SQL only backs one feed, retiring it is
  the whole $120. That is a design question worth an hour before it is worth a change.

**DECIDED 2026-09-02: run as is.** The sponsor's words - *"we seem to be ok at the burn rate we
have for 3 more weeks. If it starts feeling like pressure and we need relief, we can turn off
then."* Option 1, with an explicit trigger rather than an open question.

That is a reasonable call on the numbers: ~$120 of a $200 ceiling leaves headroom, the demo
window closes ~2026-09-21, and both cheaper options cost something real - self-healing latency on
the one undemonstrated showpiece, or an hour of design work on whether the database is needed at
all. **The relief lever stays documented above** so that if pressure does arrive, the next reader
finds the options already costed rather than starting the analysis over.

### F142 — the sign-in expires after an hour and nothing renewed it *(fixed 2026-09-02)*

The Ask tab answered at 11:00 and returned 401 by 15:30, with:

> `{"error":"A valid Entra user token is required to request a Direct Line token."}`

Tenant and audience were provably correct - the Function expects `c3571944…` / `88106f53…` and
Easy Auth issues for exactly those - and `/.auth/me` succeeded, so the page had a token and sent
it. The failure was **expiry**, the fourth thing the Function verifies.

**The `id_token` is issued at sign-in with about an hour's life, and nothing renewed it.** The
token store persists what Easy Auth received; refreshing needs a client secret, which this design
deliberately does not have. So the control worked for an hour after sign-in and then locked the
user out of their own agent, with a 401 that reads like an outage.

**Confirmed before fixing, not assumed:** a fresh Incognito sign-in answered immediately.

This is **F135's shape a second time**. There I verified a token without checking one could be
*obtained*; here I verified its expiry without asking what happens when it *expires*. Both times
the check was correct and the lifecycle around it was not.

**Fixed:** a 401 from the token endpoint triggers one `/.auth/refresh`, re-reads `/.auth/me`, and
retries once. **No navigation happens automatically** - redirecting to a login endpoint on failure
is how a bad session becomes a redirect loop, and a loop is worse than the bug. When the retry
also fails the tab says *"This sign-in has expired… Reload the page to sign in again - the agent
itself is fine"*, which is true, actionable, and distinguishes a session problem from an outage.
Mutation-tested: disabling the refresh fails both new tests.

### F141 — nothing validated Bicep, so a typo cost a twenty-minute deploy *(fixed 2026-09-02)*

A malformed params file reached a deployment and failed there rather than in CI. The reason the
existing check missed it is worth keeping: **`az bicep build` on a template passes while its
params file is invalid** - only `build-params` reads the params file at all. A validation step
that names the thing it does not read is the same defect class as an audit that cannot see what
it reports on.

**Fixed:** `.github/workflows/lint-ci.yml` gained a `bicep` job that builds every template **and**
every params file, so the twenty-minute failure is now a sixty-second one.

### F140 — every page load was a retry, and so was the diagnosis *(fixed 2026-09-02)*

Cost Management throttles **per principal**, and each refusal lengthens the window. The Ops tab
had no cooldown: a reader pressing refresh on a 502 was extending the outage they were trying to
end. **I did it to myself during the diagnosis** - throttling my own admin identity by retrying
the query, which is precisely the mistake the code was making.

**Fixed:** `cloud.ts` records `costUpstreamBlockedUntil` on a 429 and serves the persisted answer
as `stale: true` until it passes, without calling upstream.

**Two bugs in my own fix, both caught by tests before deploy.** `isThrottled` read only
`err.message` when the status is in `detail`; and the detection regex was `/\x08429\x08/` -
`\b` had been corrupted into a literal backspace byte on its way through a heredoc. The second is
why `verification/tests/control-characters.Tests.ps1` now sweeps the repository for control
characters, and why CLAUDE.md carries a rule about how these files get edited.

### F139 — an in-memory cache on a scale-to-zero container is not a fallback *(fixed 2026-09-02)*

The Ops tab showed:

> **Data unavailable.** API `/api/feeds/azure-cost` responded 502. The Cost Management
> upstream did not answer successfully.

**Cost Management really is throttled** — verified directly, `HTTP 429 "Too many requests"` —
so this is an external rate limit, not a regression. And `cloud.ts` already handles it
correctly: a 429 with something cached is served with **`stale: true`** rather than silently,
because *"a retained figure presented as current is the same defect as an empty list presented
as zero"*.

**The problem is that the cache is almost never there to be served.**

    private costCache: AzureCostFeed | undefined;   // in-memory instance field
    mls-data-api-demo-ca  minReplicas: 0            // scales to zero

The comment beside the retry logic says *"the hour-long cache above is the real fallback"* —
and on a container that scales to zero, and is redeployed several times an hour during active
work, that premise is false. The cache dies with the process. So the fallback exists, is
correct, and is empty at precisely the moment it is needed: after a restart, when the first
request must go upstream, into a throttle that lasts minutes.

**Why it matters beyond today:** the Ops tab is half of showpiece 2, and this will recur at
demo time by construction — a cold container's first request is exactly when a demo begins.

**Two honest fixes, and they are not equivalent:**

1. **Persist the last good answer** (blob, written by data-api's existing identity) so a
   restart inherits it and the `stale: true` path can actually fire. Durable, ~45 minutes,
   costs nothing meaningful, and keeps the $0-idle guarantee.
2. **`minReplicas: 1` on data-api** — the cache survives because the process does. Simpler,
   but it is a **G2 spend increase** and it treats a caching problem with money.

(1) is the better answer; (2) is what to reach for only if idle cost is not a constraint.

**Fixed with (1), and the sponsor chose it explicitly.** `apps/data-api/src/backends/costCacheStore.ts`
persists the last good answer to a blob written by data-api's existing identity, with two
properties that matter more than the caching: **nothing in it may fail a request** (every method
swallows its errors and reports "no value", because a cache is an optimisation), and it always
writes `stale: false` - whether a reader should call a figure stale depends on when it is *read*,
which is `cloud.ts`'s decision, not the writer's. Idle cost is unchanged; `minReplicas: 0` stands.

**One thing needed a human to break a deadlock.** data-api's identity was already throttled by
Cost Management, so it could never complete the query that would populate its own cache. Seeded
once from an unthrottled admin identity, using the same API, subscription, query shape and
document shape the service writes itself - **$7.70 MTD**, of which **SQL Database is $7.65, 99%
of all spend**, which is worth a look given V6.4 asserts auto-pause. The grant was removed after
seeding.

### F138 — the agent answered a different question, because its tools told it to *(fixed 2026-09-02)*

Asked *"How much have we spent to date in our tenant subscription"*, the Ask tab replied:

> Total spend to date in the tenant subscription is **$23,561,191.14999999 USD**, based on the
> full history in the `cost_daily` dataset. Source: aggregated from the `cost_daily` table in
> the Meridian operations lakehouse. I also attempted to retrieve the spend history from the
> Azure Cost Management feed, but that request was **rate-limited (HTTP 429)**, so the total
> above comes from the lakehouse cost records instead.

**Two of the three things here are the agent behaving well.** It has the right tool
(`get_cost_series`), it tried it, it was throttled by Azure's Cost Management API — a known,
external, minutes-long rate limit where retrying deepens the throttle — and it **said so**
rather than presenting a number as though nothing had gone wrong. That is the honesty property
working.

**The third is a real defect, and it is not the 429.** `cost_daily` is *Meridian's fictional
business ledger*:

    columns: cost_id, date, cost_center, amount_usd, budget_usd, currency
    row:     CST-00001, 2024-01-01, "Propulsion", 9435.57, 8610, USD

Cost centres like "Propulsion", dated 2024. It is **not Azure spend**. The real subscription
has consumed roughly **$1.40**. So the fallback was not a fallback: **it answered a different
question and kept the original question's framing**, opening with "Total spend to date in the
tenant subscription is $23,561,191". A reader who stopped at the first clause — which is what
a reader does — would carry away a number that is wrong by seven orders of magnitude, about a
thing the dataset does not measure.

Citing the source does not repair this. "Based on the `cost_daily` dataset" is true and does
not tell a reader that `cost_daily` has nothing to do with their subscription.

**Why it matters here more than elsewhere.** This estate spends its verification budget on
refusing to overstate itself, and the outbrief's sharpest argument is that it catches its own
false claims. An agent that substitutes a synthetic business ledger for a cloud bill, and
narrates the substitution accurately while mislabelling the result, is the failure mode that
argument exists to rule out.

**The diagnosis above was wrong about whose defect this is, and the correction is the
useful part.** I recorded it as an agent that substituted a dataset. It did not choose to.
Reading its actual contract - the only thing an orchestrator reasons over when picking a tool -
the substitution was **written down as guidance**:

    get_cost_series      "Fetch the daily Azure spend series … The five cost centers are
                          'Propulsion', 'Avionics' … for whole-history aggregates query the
                          cost_daily table with query_lakehouse_sql instead."
    query_lakehouse_sql  "Use this for … daily cloud spend …"

Every clause there is false in cloud mode. `cost_daily` is the fictional ledger; cloud-mode cost
centres are `costCenter` **tag** values, not "Propulsion"; and the recommended fallback is the
exact wrong answer. **The agent followed its instructions precisely.** Blaming the model for a
contract we wrote is the comfortable reading and it would have sent the fix to the wrong place.

**This is the `strftime` defect again** - a description written for one backend and shipped with
another. That one told the agent to write `strftime('%w', actual_date)` against T-SQL, which has
no such function; it was fixed by generating the description from the active backend's declared
dialect. Same fix here: `CostSeriesBackend` now declares its `source`
(`lakehouse-ledger` | `azure-cost-management`) and `get_cost_series`'s description is **built,
not written**, so it cannot promise Azure spend while reading a synthetic ledger, cannot
advertise cost centres that exist only in the other mode, and states the non-substitution rule
in the direction that applies. `query_lakehouse_sql` no longer offers itself for "daily cloud
spend", and the schema listing labels `cost_daily` as the business ledger where a model actually
reads column names.

The agent instructions gained the rule too - **one dataset never stands in for another** - made
in the solution rather than the portal, because the next import reverts a portal edit (F131), and
version-bumped to 1.0.3.0, because the import is idempotent on version rather than content
(F130). Currency now presents to two decimals: `$23,561,191.14999999` was floating-point residue,
not precision the data has.

**Eleven tests, and the eval suite still passes 10/10.** The 429 remains external and correct
to report - what changed is that being unable to answer is now the answer.

### F136 — the Functions host owns the preflight *(fixed 2026-09-02)*

"Failed to fetch", with DevTools showing:

    me      200          fetch       <- /.auth/me works; the token store is fine
    token   CORS error   fetch
    token   204          preflight   <- 204 with no CORS headers

A POST **without** the `Authorization` header returned `Access-Control-Allow-Origin`
correctly, so the function's own CORS handling was never broken. Forwarding the caller's
token added an `Authorization` header, which makes the request **preflighted for the first
time** — and the Functions host answers `OPTIONS` *itself*, before any function code runs.
With no platform CORS list it replied 204 with no headers, while the function's own correct
allow-list sat one layer below, never consulted.

**CORS worked for every request except the one the browser had to ask permission for first.**

The old comment — *"configuring the platform CORS list as well would give two places to be
wrong and one of them silent"* — was right when written, and held for exactly as long as
every request was **simple**. Both layers now read the same derived origin: the platform for
the preflight it owns, the function for the response it owns.

### F135 — the token store was off, so /.auth/me had no token to forward *(fixed 2026-09-02)*

The Ask tab reported, against a correctly signed-in user: *"Could not read this session's
Entra token from /.auth/me."* `login.tokenStore.enabled` was **false**, and Container Apps has
no built-in store — without one `/.auth/me` returns **claims and no raw token**.

**The verification was shipped without checking that the token it verifies could be
obtained.** The Function-side work was careful — real key pairs, twelve negative cases — and
none of it tested the browser's ability to get a token at all.

**The design had already named this condition.** The block read *"No downstream API is ever
called on the signed-in user's behalf, so no provider token is worth persisting"* — true of
three static dashboards, and false the moment the Ask tab began calling the directline-token
Function on the signed-in user's behalf. Enabling the store is that premise being met, not an
override of it. Still no client secret: the store persists the id_token issued at sign-in, and
the blob path authenticates with a managed identity.

Infrastructure: a user-assigned identity for the control tower (**it had none**), one
Standard_LRS account with one private container, shared-key access disabled, and Storage Blob
Data Contributor scoped to that account.

**`workload-rbac.Tests.ps1` failed on the fourth role GUID** — this layer's documented set was
read-only and Easy Auth writes. That is the check working: a new role appearing silently is
either an undocumented grant or an escalation. It is now argued for where it is defined, and
the test's name no longer claims *read-only*, because a name that lied would be the failure
that suite exists to prevent.

### F134 — mcp-tools had no Fabric role at all *(fixed 2026-09-02)*

With the tool server finally in cloud mode, the agent issued a real lakehouse query and got:

    "The data source returned: 'Could not login because the authentication failed.'"

`infra/fabric/provision-workspace.ps1` grants workspace roles **per principal** — `data-api`
and `mls-verifier` as Viewer, `cost-ingest` as Contributor — and there was **no entry for
`mcp-tools`**. Its identity held no role on the workspace whatsoever.

**Why it stayed hidden for the life of the project:** mcp-tools ran in local backend mode
(F133), so it never asked Fabric for anything and the missing grant cost nothing observable.
F133 turned a dormant gap into a live failure — and the failure surfaced **inside a Copilot
answer**, three systems away from the file that decides workspace roles, phrased as
*authentication* when it was *authorisation*.

Granted Viewer, matching the other readers, in the existing F24 pass rather than a step of its
own: both identities live in `RG_APPS`, both take the identical role, and that step already
holds the Fabric token. An absent mcp-tools identity now emits a **warning naming the exact
error it would otherwise produce**.

### F133 — the MCP server read data/generated, so the agent worked and answered nothing *(fixed 2026-09-02)*

The Copilot chain reached end-to-end for the first time, and the answer was:

    "I couldn't determine which day of the week has the most launches because the
     launch-history query failed. The lakehouse tool returned: 'Generated data not
     found at /repo/data/generated.'"

`mls-mcp-demo-ca` shipped with `MLS_TOOL_BACKENDS=local`, reading a directory that is not in
the image, while the lakehouse it should query holds 1,200 rows. **Section D's exact shape:
every layer working and the answer empty.**

`data-api` has read the lakehouse correctly all along **from the same template**, deriving its
mode from whether L5 handed over a Fabric SQL endpoint. mcp-tools did not, for a reason that
reads well and was wrong: its parameter defaulted to the literal `'local'` so the mode would
always be *"an explicit deployment decision rather than an omission"* (F2). **That made
explicit-local and nobody-said indistinguishable**, so the template could not derive — and the
omission it was guarding against arrived anyway, wearing the default as a disguise.

Empty now means derive; an explicit value still wins. L7 prints the resolved mode and warns
when it is not cloud — the treatment data-api already had, and whose absence is why nobody
noticed.

### F131 — the committed solution carried the settings that break Direct Line *(fixed 2026-09-01)*

**Caused by me, and the finding is bigger than the mistake.** The agent had been fixed by
hand — Settings → Security → Authentication → "No authentication" — and published. Re-importing
the solution to fix F129's connector host **silently reverted it**, because the committed
`bot.xml` carried:

    <authenticationmode>2</authenticationmode>       "Authenticate with Microsoft"
    <authenticationtrigger>1</authenticationtrigger>  require users to sign in

The next publish made that live and the agent went straight back to
`IntegratedAuthenticationNotSupportedInChannel`, costing a full round trip.

**`agent-definition.md` §7.1 was wrong about this, and the wrongness is the danger.** It said
*"after a solution import the auth settings are blank and must be reconfigured by hand"*. They
are not blank — they are **restored from the solution**, which is worse: reconfiguring by hand
produces a working agent that the next import quietly undoes, and nothing reports it. In a
repository whose claim is *the repo is the product*, the repo was carrying a configuration that
cannot work on the channel this demo uses.

**The enum is now OBSERVED rather than guessed**, which is what makes editing it legitimate
where this register earlier said it would not be: with the UI showing "No authentication",
Dataverse read `authenticationmode 1`; the committed `2` reproduced the channel error. So
1 = No authentication, 2 = Authenticate with Microsoft — measured, not remembered.

Fixed in the source: mode `2 → 1`, trigger `1 → 0`, and the tool's
`connectionProperties.mode` from `Invoker` to `Maker` — end-user credentials being the other
half of the contradiction, since an agent that authenticates nobody has no end user to run a
tool as. All three now survive an import.

### F130 — a green import that deployed nothing, because the check is version-keyed *(fixed 2026-09-01)*

The first L8 re-import after F129's fix reported `import the Copilot Studio solution = success`
and changed nothing. `import-agent.ps1` is idempotent on the solution **VERSION** — it compares
the online version with the committed source and skips when they match — and the fix changed
*content* (the connector host) without changing the version. Dataverse still read the dead host
after a green run.

The version is a **proxy** for "has the content changed", and it failed in exactly that way —
the estate's own recurring shape, this time in the deploy path rather than a verification. A
version bump is the honest remedy rather than `-Force`, because the content really did change.

**What did NOT catch it:** V8.1 compares the deployed component list against the committed one,
and it is red for an unrelated reason (16 platform-generated topics). A real content drift
arrived while the criterion that would have named it was already failing for something else — a
red check is not a working check.

### F132 — L8 has not genuinely deployed in a long time *(fixed 2026-09-02)*

Every L8 run on 2026-09-01 failed, and the ones whose import job read `success` had **skipped**
(F130). The first run that actually packed produced:

    Error: Solution package type did not match requested type.
    Pack 'MeridianLaunchCopilot' as Managed failed

`layer-08-copilot-studio.yml` defaults `deploy_as_managed: true`, but the committed source is
`<Managed>0</Managed>` and the installed solution reports `ismanaged: False`. So the default has
never been satisfiable, and every import either skipped or failed. It only succeeded once
dispatched with `deploy_as_managed=false`.

**The decision, taken 2026-09-02: the default changes to match the artifact.** Microsoft's
"deploy managed" guidance assumes a **separate authoring environment**. This demo has ONE Power
Platform environment, which is both the maker environment and the deployment target, so unmanaged
source is correct and the managed default was the misconfiguration. Deploying managed would need
a managed export from a second environment - a change to the ALM topology, not a flag, and not
one a $0 developer plan supports.

Three changes, because a flag flip alone would leave the trap armed:

- The default is `false`, **in both trigger declarations** - F132 survived in both copies, so a
  check reading only the first would have passed.
- `import-agent.ps1` asserts the requested package type against the committed `Solution.xml` **in
  preflight, before any tenant write**, and names which way to resolve the disagreement. This is
  the "constant that names something in another system" rule pointed inward: the other system is
  the solution tree, and it is right there to read.
- `verification/tests/failure-classes.Tests.ps1` encodes the class. Mutation-tested: restoring
  `default: true` fails it in **31 ms**, against a full L8 run to learn the same thing.

The unmanaged-import `::warning` is gone. It fired on the correct path, and a warning that is
right by default trains people to ignore warnings.

### F129 — the copilot connector points at an environment that no longer exists *(fixed 2026-09-01)*

Chasing F128's `AuthenticationNotConfigured` into the tool's own panel produced the real
cause, and it is not an auth problem at all:

    Connector request failed
    "The remote name could not be resolved:
     'mls-mcp-demo-ca.thankfulisland-7f9b1aba.centralus.azurecontainerapps.io'"

The live server is `mls-mcp-demo-ca.**happymeadow-9e15a087**.centralus.azurecontainerapps.io`.
The committed connector definition hardcoded the old one:

    "host":"mls-mcp-demo-ca.thankfulisland-7f9b1aba.centralus.azurecontainerapps.io"

**`thankfulisland-7f9b1aba` is a Container Apps environment that no longer exists.** Azure
assigns that domain segment randomly, once per environment, and a teardown/rebuild gets a new
one. So the literal was **guaranteed to be wrong after the very kill-and-rebuild this demo
exists to showcase** — and it broke the copilot silently, surfacing three layers away as
"Connector request failed" with nothing anywhere naming a hostname.

**This is F90's class exactly**: a name from another system, written into a committed
artifact, surviving the change it should have tracked. F90 was 22 Entra names surviving a
rebrand; the answer there was to tokenise `infra/entra/manifest.json` with `${prefix}`/`${env}`
and resolve it in the one place that reads it. Same answer here.

**Fixed** in three parts:

- The connector definition keeps **`"host":"${mcpHost}"`** — no environment-shaped literal in
  the repository.
- `import-agent.ps1` resolves the live FQDN (`-McpHost`, `MLS_MCP_HOST`, or an `az` lookup),
  copies the source to a staging tree, substitutes, and packs **from the copy** — so the
  package carries real values and the repo keeps the token. It **fails loudly** when it cannot
  resolve one, rather than importing a connector aimed at a dead host.
- `verification/tests/failure-classes.Tests.ps1` rejects any deployable artifact containing a
  Container Apps environment domain. Mutation-tested. Scoped deliberately: documentation
  quoting a live FQDN as evidence is honest; **configuration** carrying a random segment
  nothing regenerates is not.

**A red herring worth recording, because it is a real demo risk on its own.** The MCP server
runs at `minReplicas: 0` for the $0-idle guarantee and takes **26 seconds** to cold-start, which
also produces "Connector request failed" when Copilot Studio's connector times out first. That
was the first hypothesis and it was wrong here — but it will bite the **first question of any
live demo**. Holding one replica warm costs **~$14.04 / 30 days (0.25 vCPU, 0.5 GiB, after the
free grant)** and is a **G2 decision**, deliberately left to the sponsor.

### F128 — the Ask tab connects, and the agent refuses on an auth mode it cannot use *(2026-09-01)*

**The entire chain works.** Opened by a signed-in human, the Ask tab minted a token,
connected Direct Line, created conversation `7BwKu2KdUX8BKPJKFrcsIk-us`, sent *"Which day of
the week has the most launches"* — and the agent replied:

    Sorry, something unexpected happened. Error code:
    IntegratedAuthenticationNotSupportedInChannel

Every link F122 and F124 fixed is confirmed by this: the secret resolves, the Function mints
tokens, the bundle carries the endpoint, Web Chat initialises, and the agent is reachable and
answering. **What fails is one setting on the agent itself.**

**Confirmed from our own committed artifact, not from the error text.**
`infra/copilot-studio/solution/.../bots/mls_MeridianLaunchCopilot/bot.xml` carries
`<authenticationmode>2</authenticationmode>` — "Authenticate with Microsoft" (integrated),
which Direct Line does not support. `agent-definition.md` §7.1 already flagged this on
2026-08-31: *"Current state is NOT this. `settings.mcs.yml` reads
`authenticationMode: Integrated` — that is 'Authenticate with Microsoft', the option this
section rejects."* It was a known deviation waiting for a channel to prove it.

**The design's own fix is the wrong one here, and §3 says why.** §7.1 prescribes
*Authenticate manually* with Entra ID V2, which needs the `mls-copilot-auth` and
`mls-copilot-canvas` registrations — **neither declared in `infra/entra/manifest.json`**
(F106), so neither will ever exist. But that whole requirement descends from §3.3, whose
purpose is to obtain a `User.AccessToken` for the **connected Fabric data agent** — and §3
opens by stating that path is the **paid-F2 upgrade**, G2-gated, explicitly not the default:

> *"Fabric data agents require a paid F2+ capacity… During the trial phase this agent runs
> **tools-only via MCP**, answering lakehouse questions through the MCP server against the
> SQL analytics endpoint."*

The MCP server authenticates with **its own API key** (`mcp-auth-token`, Key Vault). No user
token is involved in the data path that is actually deployed. So **"No authentication" is not
a compromise for this configuration — it is the correct setting**, and it sidesteps F106
entirely. If the estate ever moves to paid F2 and attaches the Fabric data agent, §7.1's
manual mode becomes necessary again *and* F106 must be closed first.

**AND THE AUTH MODE WAS ONLY HALF OF IT.** With "No authentication" saved and published -
Copilot Studio's own Agent status confirms it: *"Anyone can view this agent's content because
it doesn't require users to sign in"*, state **Draft, Published** - the agent still answered
`AuthenticationNotConfigured`. The remaining half is the tool, read live from Dataverse:

    component: Meridian Ops Tools
    connectionProperties:
      mode: Invoker

**`Invoker` means the MCP connection runs as the INVOKING USER.** With no authentication
there is no invoking user, so the connection cannot be established. The two settings
contradicted each other, and fixing one without the other just moved the error.

This is §3.3's *"User authentication or Agent author authentication"* choice, and the same
reasoning applies as to the auth mode: user authentication exists so Fabric can enforce
per-user permissions on the **connected Fabric data agent**. On the deployed path there is no
Fabric data agent - the MCP server answers everyone with **one API key** - so running the
connection as the invoker buys no segregation and costs the whole feature. **Agent author /
Maker mode is correct here**, for exactly the reason "No authentication" is.

Both revert together the day the estate moves to paid F2 and attaches the Fabric data agent,
and F106 must be closed before either can.

**The change is a human one, and deliberately not automated.** Auth settings are blank after
a solution import (§6) and take effect only on publish, both of which are Copilot Studio UI
steps:

    Copilot Studio -> the agent -> Settings -> Security -> Authentication
      -> "No authentication"  -> Save                                   [done]
    Copilot Studio -> Tools -> "Meridian Ops Tools" -> connection
      -> run as AGENT AUTHOR (Maker), not the invoking user             [required]
    -> Publish

Afterwards run `infra/copilot-studio/export-agent.ps1` so the committed solution captures the
real value rather than anyone guessing the option-set integer — the repo's own round-trip,
and the reason not to hand-edit `bot.xml` to a number nobody has verified.

### F127 — V7.7 measured Microsoft's login page and blamed our app *(fixed 2026-09-01)*

With F104 fixed, L7 ran to completion for the first time and reached **6/7** — V7.5 and
V7.6 passing on their first-ever evaluation. V7.7 failed:

    launch-ops    /.auth/me answered 200 with no x-ms-middleware-request-id
    control-tower /.auth/me answered 200 with no x-ms-middleware-request-id
    - Easy Auth is not handling /.auth, so the sign-in callback has nowhere to land

**Easy Auth was handling it perfectly.** `curl` against the same URLs returns **401 with the
header present**, and all three container apps carry identical, correct auth config.
Reproduced the discrepancy directly:

    maxRedirect=-1 (default)  ->  HTTP 200, middleware header ABSENT
    maxRedirect=0             ->  HTTP 302, middleware header PRESENT

The probe followed the redirect. `/.auth/me` answers **302 to the Entra sign-in page**, and
the criterion dutifully followed it and reported **`login.microsoftonline.com`'s 200** as our
container's answer. It was measuring Microsoft's login page and attributing the result to our
app. Both frontends failed a control that works.

This is the **same trap that bit V12.4 hours earlier** — the reason `-MaximumRedirection`
was added to `Invoke-MlsHttp` in the first place. V7.7 predates it and never adopted it.

**Fixed** with `-MaximumRedirection 0`, and the assertion widened from `401` to *any refusal
carrying the middleware header* — because **Easy Auth picks its refusal by the caller**: 302
to PowerShell, 401 to curl, same app, same minute. Pinning 401 fails a working control on the
User-Agent of whoever ran the audit. A **2xx still fails**, which is the SPA-fallback state
the criterion was written for (F110).

**Confirmed against the live estate 2026-09-01**: a filtered re-run
(`only_criterion: V7.7`) reports **PASS** in **4 minutes** rather than the ~55 a full L7
costs, because V7.5 alone waits up to 30 for scale-in. The run exits 3 - `DIAGNOSTIC -
filtered run; no verdict, and no layer can be signed off from it` - which is correct and is
why the job shows red. **L7's verdict is therefore still 6/7 on the record.** The evidence
for 7/7 is strong but spans two runs: a full run that reached 6/7 with V7.7 failing on this
bug, plus a filtered run showing V7.7 now passes. A single unfiltered run is what would make
it a sign-off, and it has not been paid for yet.

**A note on the test, because it is the more useful lesson.** The first version of the
regression test *passed with the defect reintroduced* — a mirror, not a test. It captured the
probe's argument into a `$script:` variable that did not survive Pester's scoping, so the
assertion compared `$null` and never fired. Only the mutation run exposed it. It now uses
`Should -Invoke -ParameterFilter`, asserts that **no** `/.auth/me` probe follows redirects,
and separately asserts the probe ran at all so the first assertion cannot be vacuous.

### F126 — the self-heal notice named a remedy that was already done *(fixed 2026-09-01)*

`SELF_HEAL_TOKEN` was re-scoped to a repository secret and **the chain immediately started
working**: the selector reads the alert surface, **V10.3 PASSES**, and the Dependabot lane
runs instead of skipping. It then stopped on this:

    notice: No Dependabot PR to gauntlet
    ... so this path needs 'Dependabot security updates' switched ON in repository settings.

**The setting was already on.** `gh api repos/.../automated-security-fixes` →
`{"enabled":true,"paused":false}`. A confident, specific, *wrong* remedy is worse than no
remedy: it sends the reader to change something already correct and stops them looking.

**The real cause**, established by elimination rather than asserted:

| Checked | Result |
|---|---|
| `automated-security-fixes` | **enabled, not paused** — not the cause |
| Alerts have patched versions | all four do (`minimist` 1.2.6, `semver` 7.5.2, `json5` 2.2.2, `esbuild` 0.28.1) |
| Ignore conditions | Dependabot: *"No dependency name (minimist) or ignore conditions found to unignore"* — **none exist** |
| Lingering `dependabot/**` branch | only PR #102's; the vuln-lab ones are gone |
| Prior security PRs | **#30, #35, #36 opened 2026-08-28 and closed unmerged 2026-08-29 04:45**, all in one minute |

**Dependabot does not reopen a security PR that was closed unmerged, and records no ignore
condition when it happens** — so the alert stays open forever with no PR and nothing
anywhere explains why. `@dependabot reopen` does not bring it back either.

**A full heal-and-re-arm cycle was run, and it did NOT fix it.** PR #148 bumped the three
pins to their patched versions (all three alerts went to `fixed`); PR #149 ran
`apps/vuln-lab/reseed.ps1` to restore the vulnerable pins. The advisories came back — but
**GitHub REOPENED alerts #2, #3 and #4, with their original `created_at` of
2026-08-28T23:52, rather than creating new ones.** The premise the cycle rested on ("a newly
raised alert carries no association with a closed pull request") therefore never applied:
they are the same alerts. Ten minutes after the re-arm, still no Dependabot security PR.

**So the cause is still not established, and this entry does not pretend otherwise.** What
is now ruled out: the repo setting, missing patched versions, ignore conditions, lingering
branches, and a stale alert state.

**`open-pull-requests-limit: 0` is ALSO ruled out, and the evidence was in the repo the
whole time.** That was named here as the leading candidate; it is wrong. PRs #30, #35 and
#36 were security-update PRs *for `/apps/vuln-lab`*, opened 2026-08-28 — **while that
directory already had `open-pull-requests-limit: 0`**. The limit demonstrably did not stop
them, so `dependabot.yml`'s comment on the subject is correct after all. Anyone tempted to
test it by raising the limit would be disarming the seed for nothing.

**`esbuild` (#5) looks like a counter-example and is not.** It sits in the ROOT manifest,
where the limit is 5, and has never had a PR either — but it is a **transitive dev
dependency**, so there is no direct pin for Dependabot to bump and no fix it can author. Its
silence is expected and says nothing about the three seeded CVEs, which are direct
dependencies.

That leaves the closed-unmerged history of #30/#35/#36 as the only explanation still
standing, and the reopened-alert cycle showed it survives a fixed/open transition. **The next
useful observation is free:** Dependabot re-evaluates on its own weekly schedule (Monday
06:00 per `dependabot.yml`), so a scheduled pass may open the PRs without anyone doing
anything. Sponsor decision 2026-09-01: **wait for that rather than spend more on it** — there
is a month of runway and nothing else depends on it.

The cycle was not wasted: it proved the lab's heal/re-arm machinery works end to end, and
`reseed.ps1` verified its own output (3 advisories present, 2 code flaws restored).

**Fixed** by replacing the single asserted remedy with three candidate causes in order,
each with the command that tests it, and an explicit note that the first one being already
on means *it is not your cause*.

### F125 — a job-level `if:` cannot see environment variables, so two verify jobs never ran *(fixed 2026-09-01)*

Found by dispatching `compliance.yml` to prove L12's new audit runs in CI rather than only
locally. It did not run: `verify L12 (mls-verifier) = skipped`. **The guard I had just
written was the cause**, which is the point — this class is easy to write and impossible to
see.

    verify:
      environment: verify
      if: ${{ ... && vars.AZURE_VERIFIER_CLIENT_ID != '' && ... }}

**A job-level `if:` is evaluated BEFORE the job's environment is resolved.** So `vars.` is
the empty string there even though the job declares `environment: verify` and the variable
is set on it. This repository has **zero repository-level variables** — every one lives in
`demo` or `verify` — so any `vars.` in a job-level `if:` is unconditionally empty, and a
guard meaning *"skip when no verifier is configured"* actually means **"skip always"**.

`layer-05-fabric.yml` has an identical-looking guard that has always worked, because it is
**step-level**, where the environment has resolved. Same expression, different line,
opposite behaviour.

**What it cost:** `self-heal.yml`'s `verify` job **has never been able to run.** That
compounds BLOCKER-4 exactly — even with a readable alert surface and a healed alert, the
audit that judges the chain would still have skipped. Nobody noticed, because **a skipped
job is green**.

**Fixed** by moving the guard to a step inside each job, where `vars.` resolves. The
behaviour it was written for is preserved and now actually works: a stranger cloning this
repo without an `mls-verifier` identity gets a clear `::notice` saying the layer is
*unverified, which is not the same as broken*, rather than a red run.

`verification/tests/failure-classes.Tests.ps1` now fails any `vars.*` reference in a
job-level `if:` — mutation-tested: with the defect reintroduced it names
`compliance.yml::verify gates on vars.AZURE_VERIFIER_CLIENT_ID`.

**This is the fourth instance of one shape in a single session** (F122, F123, F124, F125):
*a value that exists, is spelled correctly, and is invisible to the thing that reads it* —
failing silently and green every time.

### F124 — the Ask tab's endpoint never reached the bundle, and the image was newer than the variable *(fixed 2026-09-01)*

**Everything on the server side works.** The agent is published, the Direct Line secret is
in Key Vault, F122's identity fix landed, and the token endpoint mints real tokens:

    POST https://mls-directline-demo-func.azurewebsites.net/api/directline/token
    HTTP 200  {"token":"eyJ...","expires_in":3600,"conversationId":"Lh8SX4GBfTCJQGdSUsKiBh-us"}

The Ask tab still renders "not configured", because **the deployed bundle contains no token
URL.** Pulled the running image from GHCR and grepped its layers directly rather than
inferring: `usr/share/nginx/html/assets/index-CfaMGZ2F.js` matches `directline/token` — from
a *documentation string inside an error message* — and does **not** contain `azurewebsites`
anywhere.

**The image was NEWER than the variable, and still did not have it.** `MLS_DIRECTLINE_TOKEN_URL`
was set at 15:08; the running image was built at 16:13. The inference "the build is newer, so
it picked the value up" is exactly the reasoning this repository keeps paying for, and it is
wrong here:

    app-control-tower-ci.yml
      preflight   environment: demo     <- builds nothing
      image       (no environment)      <- BUILDS THE BUNDLE, reads vars.MLS_DIRECTLINE_TOKEN_URL
      deploy      environment: demo     <- builds nothing

`VITE_DIRECTLINE_TOKEN_URL` is a **Vite** variable: inlined into the bundle at `npm run
build`, which happens inside the `image` job's docker build. That job declared no
environment, so `vars.MLS_DIRECTLINE_TOKEN_URL` resolved to the empty string — silently,
because **an absent GitHub variable is the empty string, not an error**. The value was
reaching the two jobs that did not need it and missing the one that did, and a reviewer
asking "does this workflow use the demo environment?" would have seen *yes*.

**This is the THIRD instance of one shape in a single session**, which is why it is now a
test rather than three findings:

| | What was invisible | To what |
|---|---|---|
| **F122** | the identity that resolves a Key Vault reference | the site holding the reference |
| **F123** | `SELF_HEAL_TOKEN` (an environment secret) | every job that uses it — none declares an environment |
| **F124** | `MLS_DIRECTLINE_TOKEN_URL` (an environment variable) | the one job that builds the bundle |

Each is *"the value exists, is spelled correctly, and cannot be seen by the thing that needs
it"*, and each failed silently and green.

**Fixed** by declaring `environment: demo` on the `image` job.
`verification/tests/failure-classes.Tests.ps1` now fails any job that reads a `vars.MLS_*`
estate setting without declaring an environment — mutation-tested: with the fix reverted it
names `app-control-tower-ci.yml::image reads MLS_DIRECTLINE_TOKEN_URL`.

**Rebuilt and confirmed, 2026-09-01.** Image `sha-941f286`, revision `--0000010` at 100%
traffic; its `index-BCApny3-.js` now contains the real endpoint. A redeploy could not have
helped — the value is baked in at build time.

The `image` job also now says, in its own log, whether the image will carry an endpoint. It
is a **warning, never a failure**: this repository is meant to be cloned by strangers into
their own tenants, and building with no published agent is a supported path. What was
missing was never a gate — it was that `''` and "deliberately unset" looked identical.

### F123 — self-healing was never "nothing to heal"; it could not look *(fixed 2026-09-01)*

**BLOCKER-4's diagnosis was wrong, and this entry is the correction.** It read *"nothing to
heal — the alerts have to be live for the chain to have a subject."* The alerts have been
live all along. There are **four open Dependabot alerts** — `minimist` (critical), `semver`
(high), `json5` (high) in `apps/vuln-lab`, plus `esbuild` (low) at the root — which is
exactly the seeded set `apps/vuln-lab` pins on purpose. A dispatched run says what is
actually happening:

    notice  Could not read alerts
    gh: Resource not accessible by integration (HTTP 403)

**The cause is a credential SCOPE, not a permission grant.** `SELF_HEAL_TOKEN` was created
as a **`demo` environment secret**. Every job that consumes it — `self-heal.yml`'s `select`,
`autofix` and `dependency`; `compliance.yml`'s `commit`; `gitleaks.yml`'s `scan`;
`layer-09`'s `ghas` — declares **no `environment:`**, so `secrets.SELF_HEAL_TOKEN` is empty
in all of them and the `|| GITHUB_TOKEN` fallback takes over. `GITHUB_TOKEN` cannot read
`/dependabot/alerts`. The repo's own rotation table in `.github/workflows/gitleaks.yml` —
which CLAUDE.md designates as the source of truth — says plainly:

    | `SELF_HEAL_TOKEN` | repository secret — a PAT with `repo` write | ... |

Spec and live state disagreed, and **every consumer degraded silently.** This also means
F120's compliance fix has been inert for a different reason than recorded: not "the secret
does not exist", but "the secret cannot be seen".

**Why it survived: the chain reported a denial as an absence.** The select step set
`found=false` on a 403 — the identical output it sets when the repository genuinely has no
open alerts. Every lane then skipped and the run reported success. That is the
absence-vs-denial class this repository has now paid for **seven** times, occurring inside
the self-healing showpiece itself. Worse, the one state most needing an auditor was the one
that skipped it: `verify` was gated on `found == 'true'`.

**Fixed** in three places:

- `select` now emits a **`readable`** output distinct from `found`, and a denial raises a
  **warning** naming the environment-vs-repository scope trap. The run still succeeds — a
  self-healing chain must not be able to break the repository it heals.
- `verify` now also runs when `readable == 'false'`, so the unreadable case reaches its
  auditor instead of skipping it.
- **V10.3** fails on `readable=false` with the remedy in `Detail`, and fails as
  **UNOBSERVABLE** when the chain reported nothing — never "healthy by default".

**THE ONE MANUAL ACTION LEFT:** `SELF_HEAL_TOKEN` must be re-created as a **repository**
secret (Settings → Secrets and variables → Actions → *Repository secrets*), not an
environment secret. The PAT itself is fine — only its scope is wrong. Deleting the `demo`
copy afterwards keeps the rotation table honest. **This single change unblocks four
workflows at once**, and is all that stands between here and the first end-to-end
self-healing run.

### F122 — the Direct Line secret never reached the Function, and *nothing* said so *(fixed 2026-09-01)*

Everything about this one was correct except the part no tool showed. The agent was
published, the Direct Line secret was in Key Vault under the right name, the app setting on
`mls-directline-demo-func` was present and well-formed, the identity existed, the
`Key Vault Secrets User` grant was in place, the deploy was green, and **L6 signed off
green on all six criteria.** The Function received an empty string.

    az rest --url .../config/configreferences/appsettings
    status:  MSINotEnabled
    details: Reference was not able to be resolved because site Managed Identity not enabled.

A `@Microsoft.KeyVault(...)` app setting is resolved by the platform using the site's
**system**-assigned identity unless the site sets `keyVaultReferenceIdentity`
(`keyVaultAccessIdentityResourceId` on the AVM site module). This site has **only** a
user-assigned identity — because Flex Consumption needs an identity *resource id* at
site-creation time, which a system-assigned identity does not have until the site exists.
The two requirements are in direct tension and **satisfying the first silently breaks the
second**.

**Why it was invisible, which is the part worth keeping.** `az functionapp config
appsettings list` prints the reference back verbatim whether or not it resolves — the
artefact is perfect from every angle a person would check. And the downstream symptom was
the Ask tab reporting *"the channel is not configured"*, which is a state this estate
**deliberately supports and ships as the honest default** before an agent is published. So
the single visible signal was indistinguishable from correct behaviour. There was no error
anywhere, at any layer, at any time.

**Fixed** by naming the identity in `infra/bicep/platform/main.bicep`. Two checks now cover
the class, deliberately at different costs:

- **V6.8** (`verification/layer-06-audit.ps1`) asserts every Key Vault reference in every
  Function App reports `status == Resolved` — the capability (*the secret arrives*), not the
  artefact (*the setting is present and points somewhere real*). It reads
  `/config/configreferences/appsettings`, which returns names and statuses but never values
  — which is exactly why a Reader-authenticated Verifier can be the one asking. Unresolvable
  responses are `UNOBSERVABLE`, never "no references".
- **`verification/tests/failure-classes.Tests.ps1`** catches the class statically, in a
  second, with no estate: any Bicep site block containing `@Microsoft.KeyVault(` must name
  an identity. This is the one that matters going forward — the next Function App to want a
  secret will be copied from the one that has one.

### F121 — the label policy was published to recipients that cannot exist *(fixed 2026-09-01)*

L4's first real run created all four labels and then failed:

    New-LabelPolicy: ManagementObjectNotFoundException
    The specified recipient "mls-flight-operations" couldn't be found.

The group exists — L3 creates it. But `-ExchangeLocation` takes a **recipient**, and L3
creates pure **security** groups (`mailEnabled=False`, no mail address), which Security &
Compliance cannot resolve however correct the name is. Two layers disagreeing about what a
group is, invisible for the life of the project because **L4 had never run**: the
credential to run it did not exist until BLOCKER-1 closed.

Published to `All` instead. The alternatives — M365 groups (which provision a mailbox,
SharePoint site and Teams surface each, and are referenced by L3's CA policies) and
mail-enabled security groups (Exchange-side, not creatable via Graph) — are recorded in
`Get-LabelPolicyScope`. **What it costs:** the policy no longer expresses "these four
teams", so the *scoping* half of the segregation story is not demonstrated by this object.
The labels themselves are unaffected.

**Two test suites pinned the unachievable scope** and would have failed the fix for the bug
they encode — `verification/tests/layer-04-audit.Tests.ps1` and
`infra/purview/tests/labels.Tests.ps1`. That is the fourth occurrence of that shape in two
days.

### ~~BLOCKER-1 — No GitHub secrets exist. Not one.~~ **CLOSED 2026-09-01**

**All six of CLAUDE.md's permitted long-lived credentials now exist**, in the environments
the design calls for:

| `demo` | `verify` |
|---|---|
| `PURVIEW_CERT_BASE64` | `MLS_VERIFIER_CERT_BASE64` |
| `PURVIEW_CERT_PASSWORD` | `MLS_VERIFIER_CERT_PASSWORD` |
| `SELF_HEAL_TOKEN` | `MLS_VERIFIER_GH_TOKEN` |

The `mls-purview` app registration (`838332d8-16f9-4a83-82af-80a97502b6e6`) was created for
the Security & Compliance app-only identity, holds a certificate valid to 2027-09-01, has
**Exchange.ManageAsApp** granted and is a member of **Compliance Administrator**. Both
grants were verified by READING THEM BACK, which mattered — see the two notes below.

**Two things went wrong provisioning this, and both are the estate's own recurring class.**

1. **A silent failure.** The setup script's `az ad app permission admin-consent` exited 0
   and granted nothing: the permission was correctly *requested* on the app and no
   `appRoleAssignment` was ever created. It was caught only because the grant was read back
   rather than assumed from the exit code, and fixed with a direct Graph POST. A script
   that reports success while its work did not happen is the same shape as F119 and F120,
   committed while writing the fix for them.
2. **A false alarm, from a blind read.** The same script's Compliance Administrator
   assignment DID work, and was briefly reported as failed because
   `GET /v1.0/directoryRoles/{id}/members` **does not enumerate service principal
   members** — it returns `[]`. `GET /beta/directoryRoles/{id}/members` and
   `GET /servicePrincipals/{id}/memberOf` both show it. An empty list read as absence,
   which is the absence-vs-denial class, committed inside the verification of a fix for it.
   **Use `memberOf` to check a service principal's directory roles.**

What this unblocks, now actionable: L4 can apply the label taxonomy for the first time;
V11.2 and L4's audit can be signed off; L10's Dependabot lane can author and auto-merge;
F120's compliance fix is live rather than inert; and V9.1 can read `security_and_analysis`
if the verifier PAT carries **Administration: Read**.

*Original entry follows, kept because a register that quietly edits itself is not a
register.*

### BLOCKER-1 (original) — No GitHub secrets exist. Not one. *(P-12, confirmed 2026-09-01)*

```
gh api repos/paulcfuqua/azure-devsecops-demo/actions/secrets      -> {"total_count":0,"secrets":[]}
gh api .../environments/demo/secrets                              -> {"total_count":0,"secrets":[]}
```

CLAUDE.md hard rule 5 permits exactly six long-lived credentials and **none of them has
been created**. This is unfinished G0, not a new decision — no written justification is
needed, because all six are already inventoried as permitted.

| Credential | What it unblocks | Consequence today |
|---|---|---|
| `PURVIEW_CERT_BASE64` / `_PASSWORD` | L4 **applies** the label taxonomy | No sensitivity labels exist in the tenant at all |
| `MLS_VERIFIER_CERT_BASE64` / `_PASSWORD` | L4's audit and **V11.2** | The teardown's safety criterion cannot be signed off; L4 is never independently verified |
| `SELF_HEAL_TOKEN` | L10's Dependabot lane **and F120's fix** | **Read this one twice.** The F120 fix ships a `SELF_HEAL_TOKEN` push path so the nightly compliance PR gets checks and can merge — and with the secret absent it falls back to `GITHUB_TOKEN` and the PR still cannot merge. The fix is correct and inert until this exists |
| `MLS_VERIFIER_GH_TOKEN` | The Verifier reads GitHub as **itself** | It falls back to the workflow's `GITHUB_TOKEN`, so L9's stated design — *"GitHub is read with the Verifier's own read token"* — is not true today |

Two are X.509 certificates because Security & Compliance PowerShell has no federated path;
two are PATs. All four are portal/CLI work measured in minutes. **Human-only** — an agent
cannot mint them.

**Unblocks:** L4 entirely, V11.2, half of showpiece 3, and makes the F120 fix live.

### ~~BLOCKER-2 — The Copilot Studio environment cannot be reached~~ **RESOLVED 2026-09-01**

**The Copilot Studio solution imported successfully** - the first time in this project's life.

**IT IS NOT THE SAME AS THE AGENT BEING PUBLISHED, and I recorded it as if it were.**
`import-agent.ps1` says so in its own header - "--publish-changes publishes solution
CUSTOMIZATIONS. That is NOT the same thing as publishing the agent in Copilot Studio" -
and prints "PUBLISH the agent in Copilot Studio. Nothing works until you do." I wrote
"imported and deployed" into this register, two pull requests and the session memory
anyway. The import step passing is evidence of an import, and nothing more. Publishing
remains a human step in Copilot Studio and is the next action for showpiece 1.

**The cause was not what this entry predicted, and that is recorded rather than edited
away.** The text below reasoned toward the Developer environment type being the wall:
Developer environments are provisioned for one individual, so a service principal was
expected to be unable to access one. That was wrong. A Developer environment accepts
application users perfectly well.

The actual cause was simpler: **a service principal gets no Dataverse access from Entra
alone.** `mls-github-deployer` had to be registered as an APPLICATION USER inside
`mls-authoring` and given **System Administrator**, which a solution import requires
(System Customizer routinely fails partway through an import, which is worse than failing
at the start). Once added, L8's import step passed on the next run.

**A second app user is needed and is not yet solved.** `mls-verifier` must also be an
application user there for **V8.1** to read the deployed solution's metadata, and finding a
read-only role for it is genuinely hard:

**SOLVED, and the read-only property survived it.** The sequence:

| Roles held | V8.1 |
|---|---|
| `Basic User` | 403 |
| `Basic User` + `Export Customizations (Solution Checker)` | 403 |
| + `Service Reader` + `Solution Checker` (all four) | **reads the solution** |

The 403 is gone and V8.1 now fails on CONTENT rather than permission - a different and far
healthier failure, described below.

**None of those four is `System Customizer` or `System Administrator`**, so `mls-verifier`
still cannot write customizations to the environment it audits. That was the reason for
refusing System Customizer earlier, and the read was obtained without giving it up: the
stated design claim is intact rather than quietly compromised.

**The minimal role has NOT been isolated, and nobody should assume it was.** All four were
granted together. The enabling one is `Service Reader` or `Solution Checker` - almost
certainly the latter, since reading a solution's component list is its purpose - and
proving it means removing one, re-running L8, and watching whether V8.1 reverts to 403.
Three cycles would pin it. That is hygiene, not a fix, and it is left undone deliberately.

**What V8.1 now says, and the open question it raises:**

    components missing []  extra [Conversation Start, Conversational boosting,
    End of Conversation, Escalate, Fallback, Goodbye, Greeting,
    Meridian Launch Copilot, Meridian Ops Tools, ..., Sign in, Start Over, Thank you]

**Nothing is missing.** The deployed agent carries 16 components the committed solution
does not list, and most are Copilot Studio's DEFAULT SYSTEM TOPICS - Greeting, Goodbye,
Escalate, Fallback, Multiple Topics Matched - which the platform adds to every published
agent. So the criterion compares an exact set against a solution export that never
contained them.

That is a real judgement, not a bug to paper over: either the committed export is stale and
should be re-exported to include what a published agent actually contains, or V8.1 should
tolerate platform-generated topics while still failing on a missing or unexpected CUSTOM
component. The second is probably right - a criterion that breaks every time Microsoft adds
a default topic is measuring the wrong thing - but it must not become "ignore extras",
which would let a real stray component through.

Two cautions for whoever picks this up. **Dataverse role changes take minutes to
propagate**, and both failures above were tested immediately after the change - so neither
is a safe conclusion on its own; re-run unchanged before adding another role. And if no
read-only combination works, the honest resolution is **System Customizer recorded as a
deliberate compromise in L08.md**, stating that Dataverse offers no clean read-only grant
for solution metadata - because "the Verifier reads as a read-only identity" is a STATED
design claim, and it is about to be either true-with-effort or quietly false.

*Original entry follows, kept because a register that quietly edits itself is not a
register.*

### BLOCKER-2 (original) — The Copilot Studio environment cannot be reached

L8 now gets *past* the `pac` PATH problem (F113 is fixed and confirmed: `pac help` runs) and
fails on the next thing:

```
Error: The value passed to '--environment' is invalid. No Dataverse organization was
found matching the specified criteria (--environment https://org67cdd5cc.crm.dynamics.com/)
```

`MLS_POWER_PLATFORM_ENV_URL` and `POWERPLATFORM_ENVIRONMENT_URL` both point at
`https://org67cdd5cc.crm.dynamics.com/`. Three candidate causes, **not yet distinguished** —
do not guess, check:

1. the environment was deleted or recreated and the URL moved;
2. the deploying service principal has no access to that Dataverse org;
3. the URL is right but the org is in a different tenant/region than `pac` is authenticated
   against.

**NARROWED 2026-09-01 to a single question.** The three candidate causes above are
resolved: the environment **exists and is healthy**. It is `mls-authoring` — Developer
type, State Ready, **Dataverse: Yes**, region United States — and L8's configured URL
points at it. (The tenant's other environment, `Default Directory`, is in Canada and has
**Dataverse: No**, so it was never a candidate. Region is not the cause either: L8 passes
the environment URL explicitly rather than inferring it.)

What remains is that L8 authenticates as the SERVICE PRINCIPAL — `pac auth create
--managedIdentity`, i.e. `mls-github-deployer` over OIDC — and `pac` reports
`No Dataverse organization was found matching the specified criteria`. That message is what
`pac` returns when the authenticated principal cannot ENUMERATE the org, not necessarily
when the org is absent. A service principal gets no Dataverse access from Entra alone; it
must be registered as an **application user** inside the environment and given a role.

**THE ONE TEST THAT SETTLES IT:** `mls-authoring` → Settings → Users + permissions →
Application users → **+ New app user** → `mls-github-deployer` → **System Administrator**.

- If it is accepted, L8 is unblocked with no environment change and no spend.
- If the portal refuses, the **Developer environment type is the wall** — those are
  provisioned for one individual developer — and the fork is worth naming rather than
  grinding at:
  - a **Sandbox** environment would work but needs capacity, which is **paid**, a **G2
    gate**, and contradicts the recorded "$0 Developer Plan" decision for C5;
  - or accept **"a human publishes the agent once"** as a documented limitation.

The second is the better trade. The showpiece is *the agent answering from the lakehouse*,
not the mechanism that imported it, and buying capacity to automate a one-time import
spends real money on the least interesting part of the story. **But it must be written
down as a deliberate limitation, not left looking like something that never worked.**

Note also: `fabric@` owns the Fabric trial, and switching CI to authenticate as it was
considered and rejected — it needs a stored password, which breaks hard rule 5 and would
fail against MFA, and it turns an operator account into a shared automation credential.
The owner's job here is to GRANT access to the service principal, not to be it.

**Unblocks:** L8 → the Direct Line channel → the Direct Line secret → the Ask tab →
**showpiece 1**. Also the only path to giving showpiece 3 something to heal that is not a
dependency alert.

### BLOCKER-3 — The Direct Line secret does not exist *(downstream of BLOCKER-2)*

The infrastructure is now complete and waiting: `mls-directline-demo-func` is deployed,
`VITE_DIRECTLINE_TOKEN_URL` is wired into the control-tower image build, and
`directlineSecretName` is a supported-empty parameter. The Ask tab stays dark, honestly,
until a published agent produces a Direct Line channel whose secret can be put in Key Vault
as `mls-directline-secret` and named in the `demo` environment variable
`MLS_DIRECTLINE_SECRET_NAME`.

**Do not start here.** Nothing about this is actionable until BLOCKER-2 clears.

### BLOCKER-4 — Self-healing has nothing to heal, and would stall if it did

Two independent problems, both needed:

1. **Nothing to heal.** Every scheduled run reports `select the alert to heal: success`
   and then skips every lane. `apps/vuln-lab` pins three known-vulnerable packages on
   purpose; the alerts have to be live for the chain to have a subject.
2. **It would stall anyway.** The Dependabot lane needs `SELF_HEAL_TOKEN` (BLOCKER-1),
   because a `GITHUB_TOKEN` push does not trigger the workflows the gauntlet depends on.

**Unblocks:** showpiece 3. Note the demo needs the chain to run **once, end to end,
observed** — not to run nightly and report green, which it already does and which means
nothing.

### BLOCKER-5 — L12 has no audit script

The compliance platform is the only layer with no `verification/layer-*-audit.ps1`. It is
therefore the only layer whose claims rest on itself. For a showpiece whose entire argument
is *"this estate catches its own false claims"*, that is the wrong layer to leave unaudited.

**Unblocks:** showpiece 4 moving from partial to done. **Agent-doable** — no credential, no
tenant access beyond what already exists.

---

## IN FLIGHT AS OF 2026-09-01 19:20 UTC — check these first

Three things were running when this was written. **Check their outcome before starting
anything new**, because two of them change the scorecard above.

| What | Run | What it proves |
|---|---|---|
| **L6 re-run** | `33547680971` | Whether the F119 storage-firewall fix let the Function Apps finally receive code. **V6.7 answers this explicitly** — it asserts each Function App contains functions, and distinguishes "empty" from "could not look" |
| **L4 re-run** | `33548766843` | Whether the F121 fix publishes the label policy cleanly. The four labels already exist; this is the policy and then the audit |
| **compliance re-run** | `33548856920` | **Whether F120 is actually fixed.** PR #88 was closed and its branch deleted deliberately, so the repaired `SELF_HEAL_TOKEN` path recreates it. If the new PR has checks attached, F120 is proven; if it does not, F120 is not fixed and the entry should be reopened |

That last one is a deliberate test rather than a workaround. #88 could never merge because
its head commit was pushed by `GITHUB_TOKEN` and had **zero check runs attached** — nothing
retroactively attaches checks to a commit, so reopening the PR ran workflows against the
merge ref and left the head unchecked. The artifact is regenerable from the workflow, so
nothing was lost by deleting the branch.

**Do not assume any of the three succeeded.** Every one of them is a fix whose predecessor
looked fine and was not.

---

## HOW TO USE THIS DOCUMENT

- **Sections A–E below are the historical register** — what was found, when, and what was
  wrong about earlier diagnoses. It is deliberately not rewritten when a finding is closed;
  a register that quietly edits itself is not a register.
- **This scorecard and blocker tree are the working surface.** If you have just been handed
  this repository, or your conversation has been compacted: read the two tables above, pick
  the highest blocker you can actually act on, and check its evidence yourself before
  acting on it — several entries below record a confident diagnosis that a second sample
  disproved.
- **The finding numbers are the trail.** F1–F120 are greppable across `docs/`, `CLAUDE.md`,
  the runbooks under `docs/runbooks/layers/`, and the tests in `verification/tests/`. A
  finding with a test is closed; a finding with only prose is not.

---

## A. Verified by the Verifier, and genuinely working

| Layer | Evidence |
|---|---|
| **L2** landing zone | V2.1, V2.2 PASS — management group, subscription-wide DENY policies, NIST initiative. V2.3 SKIP (policy evaluation lag) |
| **L3** Entra | V3.1–V3.4 PASS — 5 users, 7 groups, app registrations, CA policy state, licence assignment |
| **L6** platform | V6.x PASS — Azure SQL serverless, Container Apps environment, observability |
| **L7** apps | V7.1–V7.5 PASS — endpoints return 200 with the audited image digest, golden specs validate, OTel spans correlate end to end, per-app CI green, replicas scale 0→N→0 |
| **L11** down half | V11.1 PASS — all four resource groups absent after teardown |

That is a real achievement and it is worth saying plainly: the estate deploys from a cold
dispatch, in layer order, with independent sign-off at each step, and it can be torn down
and rebuilt.

**It is also entirely about infrastructure.** Read the criteria again and notice what none
of them touches: a row of data, a rendered page, a working answer.

---

## B. Known broken

> ## Update, 2026-09-01 — the data path is FIXED, and B1/B4 below are history
>
> The dashboards now sign in, fetch real rows and render them. Four separate defects sat
> between the estate and a working page, and **every one was found by opening the product**,
> not by a check:
>
> | | |
> |---|---|
> | **F110** | `enableIdTokenIssuance` defaults to false and nothing set it, so Easy Auth's login could never complete. **Nobody could sign in - ever** |
> | **F109** | The SQL grant searched the wrong resource group and skipped with a plausible wrong reason |
> | **F112** | The SQL server had no managed identity, so no automation could create the database user |
> | **F111** | `ajv.compile()` needs `'unsafe-eval'`; the CSP forbids it, so every spec was reported invalid |
>
> **F101 was a misdiagnosis on my part and narrows sharply.** Seven of the ten tables are
> Azure SQL (`TABLE_STORE` in `apps/data-api/src/contract/allowlist.ts`); only
> `telemetry_summary`, `cost_daily` and `findings_history` are lakehouse. `launches` never
> touched Fabric. I observed a SQL failure and explained it with a Fabric limitation I had
> established only from documentation. Fabric's TDS endpoint genuinely does reject
> user-assigned managed identities - it is just not why the dashboards were empty.
>
> **Section D still stands, and is now evidenced rather than argued.** Every fix above was
> invisible to the criteria: V7.1 checks `/healthz`, which nginx answers without touching
> application code; V7.3 authenticates with a bearer token and never touches the interactive
> login; `frontend-auth.Tests.ps1` checks configuration, not behaviour. **V7.6** now asserts
> that the API answers with rows, and the F20 step queries the database instead of reporting
> that a script ran - but nothing yet opens a page.
>
> The original text is kept below because a register that quietly rewrites itself is not a
> register.

> ---
>
> **UPDATE 2026-09-01, later the same day — the apps were opened and every route probed.**
>
> **F101 is closed outright, not merely narrowed.** The claim that Fabric's TDS endpoint
> rejects user-assigned managed identities was established from documentation and is
> contradicted by the running estate: through `data-api`'s own managed identity, over the
> same proxy a browser uses, `cost_daily` returned **4,515 rows** and `telemetry_summary`
> returned **1,200**. No federated identity credential was ever created. The fix listed
> below as "understood and unstarted" was not needed and must not be built.
>
> Launch Ops renders **20 real launches** from Azure SQL. Control Tower's **Ops tab renders
> fully** — KPIs, a 30-point monthly spend line, a cost-centre donut, anomaly counts — all
> from the lakehouse. **Phase 2 of the Direction is met for those surfaces.**
>
> **All eight Control Tower routes, probed from the authenticated browser:**
>
> | Route | Status | Reality |
> |---|---|---|
> | `feeds/workflow-runs` | 503 | `MLS_GITHUB_TOKEN` unprovisioned **by design** |
> | `feeds/code-scanning-alerts` | 503 | same |
> | `feeds/dependabot-alerts` | 503 | same |
> | `feeds/secure-score` | 200 | `{"value":[]}` — **empty, and nothing asserts why** |
> | `feeds/secure-score-controls` | 200 | **empty, same caveat** |
> | `feeds/app-requests` | 200 | real rows |
> | `tables/cost_daily` | 200 | **4,515 rows** |
> | `tables/telemetry_summary` | 200 | **1,200 rows** |
>
> **F116 — one dead feed blanks a whole tab.** Each tab fetches its feeds with
> `Promise.all`, so a single rejection discards the panels that did resolve. The Dev tab
> has `app-requests` in hand and renders nothing. Five of eight routes carry data and the
> default view shows none of it. Per-panel degradation is the fix.
>
> **The two Defender feeds are an absence-vs-denial case and are NOT yet resolved.** They
> answer `200 {"value":[]}`. The identity does hold **Security Reader** at subscription
> scope, so this is probably a genuine empty rather than a silent denial — but "probably"
> is exactly what the working agreement forbids. Nothing establishes that the caller
> *could* have observed a score before reporting there is none, and the dashboard will
> render "0" either way. Until something distinguishes the two, treat these panels as
> **UNOBSERVABLE, not zero**.
>
> **The GitHub 503s are a deliberate default, not a defect.** `infra/bicep/apps/main.bicep`
> says so in terms: the token is "deliberately NOT set here … a better default than a
> half-wired secret path". Sponsor decision the same day: wire it. The plumbing now exists
> (`githubTokenSecretName`, resolved by reference from Key Vault via data-api's own UAMI,
> empty still supported); only the secret value is outstanding. Note the repo is **public**,
> so `actions/runs` reads **200 anonymously** — `code-scanning` and `dependabot` are the two
> that genuinely require the credential.
>
> **Operational trap, and a correction.** `mls-sec-demo-kv` is **RBAC-mode**: Owner and
> Global Admin grant *no* data-plane access, so `az keyvault secret set` fails
> `ForbiddenByRbac / Assignment: (not found)` for an account that can otherwise do anything
> in the subscription. The operator needs **Key Vault Secrets Officer** on the vault.
> I first recorded this as undocumented; that was wrong. `docs/runbooks/g0-bootstrap.md`
> item C11 already carries the grant, for `mcp-auth-token`. What was actually missing is
> that `mls-github-token` (**renamed `mls-data-api-github-token` later the same day** -
> three GitHub tokens now exist and the old name could not say which) is a NEW secret with
> no runbook step of its own, so anyone
> following the runbook provisions the vault without it and the GitHub feeds stay 503 with
> nothing saying why. That step now exists.

> ---
>
> **UPDATE 2026-09-01, third pass - the token landed, and the Ops tab was measuring the
> wrong thing entirely.**
>
> With `mls-github-token` provisioned and L7 redeployed, **all eight Control Tower routes
> answer 200**: 2,587 workflow runs, **76 open code-scanning alerts**, 4 Dependabot alerts,
> real CVEs from CodeQL, Dependabot and Trivy. The Dev and Sec tabs render.
>
> **F116's second half was found in a PIXEL, not an audit line.** The live Sec tab displayed
> `Defender secure score 0.0%` - the most alarming figure that panel can show, produced by
> `{"value":[]}` and the expression `score ? round(...) : 0`. An empty list is also what
> Defender's ARM API returns to a caller who may not read it, so 0.0% stood in for two
> states, one of them "you are not allowed to know". Absent inputs now render
> `"not reported"`. This is the sixth instance of the absence-vs-denial class and the first
> in a rendered UI, where a reader has no verification report to check against.
>
> **The Defender emptiness is real, and this time that was established rather than assumed.**
> Sibling endpoints under the same provider were probed: `assessments` -> 0,
> `secureScoreControls` -> 0, `Microsoft.Security` **Registered**, FoundationalCspm on
> (paid CloudPosture off, so no spend), 25 resources present. Everything under the provider
> is empty, which is the initial-computation delay, not a denial and not a missing grant.
>
> **F117 - the Ops tab was showing the FICTIONAL company's money.** Sponsor caught it: the
> tab is meant to answer "what does this landscape cost to run" and was rendering
> `cost_daily`, the generator's synthetic launch-programme budget split across Propulsion,
> Avionics and Range Operations. Worse, fixing the data source alone would not have fixed
> the tab: `cost-ingest/normalise.ts` aggregates even genuine Cost Management rows onto a
> `costCenter` **tag** whose demo values are those same fictional units, so real Azure money
> arrives wearing a costume.
>
> Three facts settled the design. The Cost Management **export** exists and is Active Daily
> but has **never run** (0 runs; its recurrence window opened today, recreated by the
> rebuild). The **query** API is throttled hard - 429 on four consecutive calls. And the
> flight-telemetry half of the tab was fictional too. So: a new `azure-cost` feed queries
> Cost Management directly with data-api's managed identity, **cached an hour** because the
> figures settle daily and the API will not tolerate more, grouped by **Azure service and
> resource group** - what actually incurs the charge. The flight telemetry is gone from Ops.
> `stale` is in the contract: a retained figure presented as a current one is the same
> defect as an empty list presented as a zero.
>
> Still open: the Ops tab's real numbers are unverified against the live tenant, because the
> throttle blocked a direct read while this was written. First deploy will show it.

### B1. The API serves no data (F101) — the biggest hole *(RESOLVED 2026-09-01, see above)*

`data-api` returns **502** on every `/api/tables/*` route. Fabric's SQL endpoint accepts
Entra users and *application objects*; `data-api` authenticates as a user-assigned managed
identity, which is neither. The lakehouse is fine — ten tables, `launches = 1,200`,
verified over TDS as `mls-verifier`.

**Consequence: both dashboards render empty.** Every number, chart and table in launch-ops
and control-tower is downstream of this.

The fix is understood and unstarted: give the app registration a federated identity
credential whose subject is the managed identity, so the container presents an SPN to TDS.
Secretless, $0, GA — and it fixes `mcp-tools` at the same time, which has the identical
identity shape.

### B2. Purview labels have never been applied

`layer-04-purview.yml` has **run zero times**. Every `infra-up` L4 apply step **skipped**,
because `PURVIEW_CERT_BASE64` does not exist (P-12). There are **no sensitivity labels in
the tenant** — not mislabelled, absent.

The label taxonomy is a load-bearing part of the compliance story. L4's audit is equally
blocked (`MLS_VERIFIER_CERT_BASE64`), and it says so honestly rather than passing:
*"Nothing was verified and nothing was faked."*

### B-1. The nightly compliance artifact has not reached main since 2026-08-30 (F120)

PR #88 has been open, BLOCKED, with **no failing checks — because it has no checks at
all**.

`compliance.yml` tries a direct push to `main` and falls back to a branch plus a pull
request when branch protection refuses. That fallback worked exactly as designed; the
file's own comment predicted the day it would be needed. What it could not predict is that
the pull request would be **unmergeable**: a branch pushed with `GITHUB_TOKEN` triggers no
workflow runs — GitHub's recursion guard, which this same workflow relies on deliberately
two steps earlier — so no required status check ever reports and branch protection refuses
the merge forever.

The artifact was safe on a branch and the nightly job was green, while the thing the job
exists to do had silently stopped happening. **Nine days of compliance state never reached
`main`.**

Fixed by pushing the fallback branch with `SELF_HEAL_TOKEN`, which hard rule 5 already
describes as existing for this exact reason. The `GITHUB_TOKEN` path is kept for a clone
with no PAT and now warns that the resulting pull request will carry no checks.

### B0. NO FUNCTION APP HAS EVER RECEIVED CODE (F119)

Found 2026-09-01 while deploying the Direct Line Function. Every zip publish to
every Function App in this estate has failed, and L6 has reported **success** each
time.

    InaccessibleStorageException: Failed to access storage account for deployment:
    BlobUploadFailedException: ... 403 (This request is not authorized to perform
    this operation.)

`mlsfuncdemost` never declared `networkAcls`, so the AVM storage module applied
its own secure default - `defaultAction: Deny`, `bypass: AzureServices`. That
default is correct and is kept. What nobody noticed is that Flex Consumption's
package upload is performed by the platform's deployment service against the blob
endpoint, and the `AzureServices` bypass **does not cover it**. The fix is a
resource instance rule naming each site, which keeps the firewall shut for
everything else.

**It was invisible because both publish steps carried `continue-on-error: true`.**
That is this repository's own recurring defect turned on its own pipeline: a step
that reports success while the work it names did not happen. L6 has signed off
green while `mls-cost-ingest-demo-func` held no functions at all.

**Consequence, and it is larger than the Ask tab.** The cost-ingest FinOps leg has
never run - not because of the Cost Management export that has never fired
(recorded separately), but because *the Function that would consume it was never
deployed*. Two independent failures pointing at the same dead pipeline, each of
which fully explains the symptom, which is precisely why neither was investigated.

**My first diagnosis was wrong and is recorded here rather than quietly
replaced.** I attributed the 403 to RBAC propagation - the storage grant had been
created seconds earlier in the same deployment - and shipped a bounded retry for
it. The retry is defensible on its own terms and is kept. But the second run, 27
minutes later with the grants demonstrably present, failed identically, and
cost-ingest failed with it. I had asserted a cause from a single sample that a
second sample disproved: the same mistake as F107, made the same day I wrote the
note about F107.

### B3. The Ask tab has never been lit - and two links of the chain have no infrastructure (F118)

The Copilot Studio agent is **exported into the repo** but has never been imported,
published, or given a Direct Line secret in Key Vault. It ships dark by design at L7; it
has never been anything else.

**CORRECTED 2026-09-01 after opening the tab in the deployed estate.** The paragraph above
was true and incomplete, in the way that matters: it described the agent as unpublished and
left the impression that publishing it would light the tab. It would not. The chain has
five links and **two of them do not exist as infrastructure at all**:

| Link | State |
|---|---|
| Agent imported + published in Copilot Studio | never done (above) |
| Direct Line channel + secret in Key Vault | never created (above) |
| **`apps/directline-token` deployed** | **no Bicep, no CI workflow - it cannot deploy** |
| **`VITE_DIRECTLINE_TOKEN_URL` in the control-tower build** | **set by no workflow, so every image is built dark** |
| Entra registrations for agent user-auth | blocked, F106/B4 below |

`apps/directline-token` is an Azure Function - `host.json`, no Dockerfile - with a README, a
package, source and tests. It is a member of the root npm workspace and has its own
Dependabot entry, so it is maintained like a deployable component. `grep -r directline
infra/` returns exactly one hit, in a Copilot Studio markdown file. **Nothing declares it,
no workflow builds or deploys it, and no environment points at it.**

The tab's own message is misleading about this, and in the familiar direction: it says
*"Ask is offline in local mode"* and *"this tab needs the deployed environment"* while
running IN the deployed environment. The cause is not local mode - it is that
`VITE_DIRECTLINE_TOKEN_URL` is a BUILD-time Vite variable that no pipeline sets, so the
deployed bundle is identical to a laptop one. A reader is told to deploy something that is
already deployed.

The last link (F106) is needed for the agent to authenticate USERS. It is not on the
critical path for the tab merely rendering a conversation: the Direct Line secret flow -
exchanged server-side by the token function, never reaching a browser - stands on its own.
So the Ask tab can be lit without solving F106, and should not wait for it.

### B4. The agent's authentication is blocked permanently, and no gate will ever say so (F106)

`agent-definition.md` 7.2 names two app registrations the agent's Entra ID V2
authentication needs: `mls-copilot-auth` (the provider, exposing an API scope) and
`mls-copilot-canvas` (the SPA the control-tower canvas uses for MSAL).

**Neither is declared in `infra/entra/manifest.json`**, which is the only thing L3 creates
from. So L3 has nothing to create, no layer fails, and every gate stays green forever.

This is the night's recurring defect in its purest form. V3.1 confirms object counts
*against the manifest*, so a registration nobody declared is **unfalsifiable by
construction**: a criterion that validates reality against a declaration can find drift,
never omission. Something outside the declaration has to notice.

**The fix is not two lines in the manifest.** Its schema carries only `displayName`,
`appKey`, `signInAudience`, `notes` and `verifierProbeRole` - it cannot express an exposed
API scope, an SPA redirect URI, or an authorized client application, which are exactly the
three things 7.2 requires. Declaring the names alone would create two empty shells: L3
creates them, the count matches, every gate greens, and authentication is still blocked -
**the gap made invisible instead of merely present**, which is worse than today.

Real fix: extend the manifest schema and `apply-entra.ps1` to configure all three, then
declare them. Identity-workstream call. `failure-classes.Tests.ps1` carries the check,
skipped with that reason rather than deleted or satisfied.

### B5. Cost dashboards have no data

The `cost-ingest` Function has produced **zero telemetry in 24 hours** — it appears never
to have executed. Whatever the cost tab renders, it is not rendering ingested cost data.

---

## C. Never run, never verified

| Thing | State |
|---|---|
| **L10 self-healing** | Never run. Both tracks are armed — CodeQL alert #2 (`js/command-line-injection` in vuln-lab) and three seeded pins (`minimist` critical, `json5` high, `semver` high) |
| **Control-tower Dev/Sec feeds** | L9 deploy step 3 wires the tabs to the GitHub Security and Defender APIs via a config PR. No evidence it was ever done |
| **Defender secure-score feed** | The plan is `Free` — correct, and it means the feed has little to show |
| **Fabric teardown/rebuild** | L11 ran with `skip_fabric: true`. The item tombstone-and-recreate path is untested |
| **V11.2 tenant-objects-intact** | SKIPPED for want of a certificate. Verified by hand on 2026-09-01 (RGs gone, 7 groups and 6 app registrations intact) — but a human check is not a Verifier sign-off |

---

## D. The structural gap, which is the real finding

Every hole in section B was survivable **because no criterion looks for it**:

- **No criterion asserts that the API returns a row.** V7.1 checks `/healthz`, which nginx
  answers from its own config without touching application code. That is why L7 could sign
  off 5/5 for two days over an estate serving 503s (F98).
- **No criterion opens a page.** There is no assertion anywhere that a dashboard renders,
  that a chart has data, or that a human would see something other than an error state.
- **No criterion asserts the demo's narrative works end to end** — ask a question, get an
  answer drawn from the lakehouse, see it on a card.

The layers verify that the *plumbing* exists. Nobody wrote the criterion that says *water
comes out of the tap*.

That is not an oversight in any single layer. Each layer's criteria are correct for its own
scope; the gap is between the layers, which is exactly where nobody owns it.

---

## E. What to do about it, in order

1. **Fix the identity (F101).** One federated credential pattern fixes `data-api` and
   `mcp-tools`. Nothing else in section B matters until data flows — the dashboards, the
   copilot's answers and the eval all sit downstream of it.
2. **Create the four missing credentials (P-12).** All four are already inventoried in
   CLAUDE.md as permitted long-lived credentials, so this adds no new secret and needs no
   written justification - it is unfinished G0, not a new decision. What each one buys:

   | Credential | Unblocks | Consequence today |
   |---|---|---|
   | `PURVIEW_CERT_BASE64` / `_PASSWORD` | L4 **applies** the label taxonomy | No sensitivity labels exist in the tenant at all |
   | `MLS_VERIFIER_CERT_BASE64` / `_PASSWORD` | L4's audit, and **V11.2** | The teardown's safety criterion cannot be signed off; L4 is never independently verified |
   | `MLS_VERIFIER_GH_TOKEN` | The Verifier reads GitHub as **itself** | It currently falls back to the workflow's `GITHUB_TOKEN`, so L9's stated design - *"GitHub is read with the Verifier's own read token"* - is not true |
   | `SELF_HEAL_TOKEN` | L10's Dependabot half | A `GITHUB_TOKEN` push does not trigger workflows, so that track stalls (honestly, with a summary line) |

   Two of these are certificates for Security & Compliance PowerShell, which has no
   federated path - that is why they are certificates and not OIDC. The two tokens are
   PATs. All four are portal/CLI work measured in minutes, and between them they close
   one broken layer, one unprovable safety criterion, one false design claim and half a
   showpiece.
3. **Open the applications and look at them.** Before writing another criterion. The
   fastest way to find the next ten holes is to use the product for five minutes.
4. ~~**Add the criterion nobody wrote.**~~ **DONE 2026-09-01 — V7.6.** L7 now asserts that
   the data API answers with **rows**, not merely with a status code, and deliberately does
   not accept a 2xx alone: an empty array is a well-formed HTTP 200 and is exactly what a
   broken backend and an empty lakehouse both return, so the criterion separates them and
   names which it saw. **It fails today**, correctly, on F101 - so L7 signs off 5 of 6
   rather than 5 of 5, which is the honest number and was not available before. The
   remaining half of this item is still open: nothing yet opens a page or asserts the demo's
   narrative end to end.

5. **The original item, for the record:** An end-to-end check that a dashboard renders real
   rows, and that the copilot answers a golden question from the lakehouse. It belongs at
   L8 or in a new L12, and it is the only criterion that would have caught F98, F101 and
   B4 on its own.

# Finding register — 2026-09-20

The tiered-data-access day: two mixed-sensitivity lakehouse tables, column- and row-level
controls over them, and the criteria that judge both. Everything here was found by
**deploying it**, not by reasoning about it. Nothing has been removed.

Continues [2026-09-16](2026-09-16-finding-register.md) (F201–F217).

**Seven findings.** Three share one shape worth naming up front: **a Fabric lakehouse SQL
analytics endpoint is not a SQL database, and its unsupported surface is discovered rather
than documented.** `CREATE USER`, `DATABASE_PRINCIPAL_ID` and `EXECUTE AS` — all ordinary in
any SQL Server reference — are each refused here, each with a distinct message number, and
each was found only by running it.

Three more (F221, F222, F224) share a different shape, and it is the more uncomfortable one:
**the checks written to catch a defect class contained that class.** A sweep that would have
passed on the defect it was written for; a syntax check trusted in place of a test; and an
observability guard that proved a neighbouring view and concluded about the target one. Each
was caught, but only by deliberately trying to break it.

---

## F218 — a lakehouse SQL endpoint cannot have database users, so role-based tiering is impossible on it

**Status:** OPEN. The deployed controls work; one of the two is narrower than its design.

### Expected

`infra/fabric/protect-tables.ps1` creates `<prefix>_data_standard` and
`<prefix>_data_privileged`, denies three `hr_roster` columns and the `defect_reports` base
table to the standard role, and filters 3PPI rows from anyone outside the privileged role.
The two-agent demo then places each agent's identity in one role, and the same question
returns different data to different callers.

### Observed

```
CREATE USER [x] FROM EXTERNAL PROVIDER  ->  Msg 22424: CREATE USER is not a supported statement type
CREATE USER [x] WITHOUT LOGIN           ->  Msg 22424: same
```

The endpoint's only database principals are `dbo`, `guest`, `sys` and `INFORMATION_SCHEMA`.
No principal can be created, so **no principal can ever join either role**:

| Control | Deployed | Binds anyone? |
|---|---|---|
| RLS filter on `v_defect_reports` | yes, `is_enabled = 1` | **YES** — the predicate requires privileged membership, nobody has it, so every caller is filtered |
| `DENY SELECT (salary_usd, …) ON hr_roster` | yes, recorded per column | **NO** — targets a role that can never have members |
| `DENY SELECT ON defect_reports` | yes | **NO** — same |

Measured live: a caller in neither role reads **900** rows from `defect_reports` and **761**
from `v_defect_reports`, with **139** classified restricted. 900 − 139 = 761. The filter is
real. The denials are inert.

### Why the spike missed it

The spike proved `CREATE ROLE`, `GRANT`, `DENY SELECT (cols)`, `CREATE VIEW … WITH
SCHEMABINDING` and `CREATE SECURITY POLICY … STATE = ON`. Every one of those creates an
**object**. Nothing asked whether a **principal** could be created to put into them — the
single question the tiering depends on.

The artefact was verified and the capability assumed, which is this repository's most
frequently recorded defect family. A `DENY` row in `sys.database_permissions` looks identical
whether or not any principal can ever be subject to it.

### Consequences for the criteria

- **V4.5 is sound but narrower than its name.** It proves the row filter filters. It cannot
  prove tiering, because both tiers are empty.
- **V4.4 checks column DENYs that can never bite.** It is explicit about being an artefact
  check, but on this endpoint that artefact is permanently disconnected from any capability —
  a criterion that will pass forever while enforcing nothing.
- **V4.6 was already right** to call the column denial unobservable, for a weaker reason than
  the true one: not merely "EXECUTE AS is unsupported" but "no principal can exist to deny".

### Options

1. **A Fabric Warehouse item** for the sensitive tables — Warehouses support `CREATE USER`,
   database roles, CLS and RLS. The SQL already written is nearly unchanged.
2. **Separate lakehouses or workspaces per tier**, enforced by Fabric workspace roles, which
   *do* apply to service principals. Coarser, and the mechanism Fabric intends.
3. **Drop the tiering claim** and keep what is real: 3PPI is hidden from every automated
   caller, including the agent.

What must **not** happen is pointing one agent at `v_defect_reports` and another at
`defect_reports` and calling it enforcement. Both are readable by every caller; that is
presentation, not a control.

---

## F219 — `DATABASE_PRINCIPAL_ID` is unsupported, and nineteen unit tests passed anyway

**Status:** CLOSED — fixed, and swept for.

`protect-tables.ps1` first guarded `CREATE ROLE` with
`IF DATABASE_PRINCIPAL_ID('x') IS NULL`. Against the live endpoint:

```
Msg 15871: FUNCTION 'DATABASE_PRINCIPAL_ID' is not supported.
```

The guard threw, the role was never created, and every `GRANT` and `DENY` after it failed
with *"Principal could not be found"*. **All nineteen unit tests passed throughout**, because
they inspect the generated SQL text and cannot inspect what the endpoint does with it.

`sys.database_principals` works, and `CREATE ROLE` is content inside an `IF` — only
VIEW/FUNCTION/POLICY must begin a batch. A test now asserts the string appears nowhere in the
emitted SQL.

---

## F220 — `EXECUTE AS` is unsupported, so a read-only audit cannot provoke a refusal

**Status:** CLOSED as a documented limit (V4.6).

The intended V4.5 was: impersonate a member of the standard role, read `salary_usd`, require
a permission error.

```
Msg 15868: EXECUTE AS is not supported.
```

A **feature-level** refusal, not a permission one, so no credential makes it work. Combined
with F218 there is also nothing to impersonate.

**The half that IS observable was nearly missed.** The row predicate keys on the
*privileged* role, so it filters every caller *outside* it — including the auditor. V4.5 was
originally a blanket SKIP; half of what it called unobservable was observable all along.
Under-claiming a control is still a wrong answer.

---

## F221 — the L4 verify job could not read SQL, and said so correctly

**Status:** CLOSED — fixed, and swept for per job.

V4.4 and V4.5 read the SQL endpoint. The verify job had no SqlServer module, so both
reported:

> `UNOBSERVABLE: the SQL analytics endpoint could not be read - 'Invoke-Sqlcmd' is not available on this machine`

— against an estate whose protection had just been confirmed correct by hand.

**The criteria behaved perfectly.** They said they could not look rather than claiming the
protection was missing, which is the entire point of the UNOBSERVABLE rule, validated
against a cause nobody anticipated. But a *permanently* blind criterion verifies nothing
while looking like diligence.

`layer-05-fabric.yml` has carried the same install step since the identical problem was found
for V5.3; its comment calls it *"a runner gap reported as an estate defect"*. Adding
SQL-reading criteria to another layer without bringing the step was that lesson going
unlearned one layer over.

**The first sweep written for this was useless.** It asked whether the workflow *file*
mentioned `Install-Module SqlServer`. `layer-04-purview.yml` already did — in the `protect`
job — while `verify` had none, so it would have passed on the exact defect it was written
for. Proven by breaking the workflow and watching it stay green. It now resolves the **job**
that runs the audit and checks that job's own steps.

---

## F222 — a comment between backtick-continued lines silently unbinds a parameter

**Status:** CLOSED — fixed, and swept for.

V5.5's retry-window justification was placed here:

```powershell
-RetryWindowMinutes 10 `
# ten minutes because ...
-Test { ... }
```

A backtick continues onto the next line; when that line is a comment the continuation is
consumed and everything after starts a fresh statement. `-Test` stopped binding. CI:
*"Cannot process command because of one or more missing mandatory parameters: Test."*

**The file parses clean.** `ParseFile` was run after the edit, said yes, and that was taken
as verification. A syntax check structurally cannot see this; running the tests catches it in
seconds.

The sweep for it also needed two passes: the first reported **23 defects, all false
positives**, because this repository's prose is full of `` `inline code` `` spans and a
backtick ending a *comment* continues nothing. It now ignores comment lines and carries three
self-tests proving it still catches the real shape.

---

## F223 — a newly loaded Delta table is invisible to the SQL endpoint for about a minute

**Status:** CLOSED — measured, and the measurement is now the justification.

After the L5 seed, Fabric's `/tables` route reported all **12** tables while the SQL analytics
catalog still reported **10**. Reading only the SQL endpoint would have concluded the seed
had failed on a run that succeeded.

Measured: the two new tables appeared in the SQL catalog after **63 seconds**.

V5.5's retry window was already 10 minutes, but nobody had measured anything — it was a
number somebody picked. CLAUDE.md asks a check to declare how long it is willing to wait
*and why*; it now cites the observation and the propagation it waits on, and says to
re-measure rather than double it.

**This is also why V5.2 reads the table list over a route it has established it can see.**
One route's silence is not the other route's answer.

---

## F224 — the guard against reporting a control absent reported a control absent

**Status:** CLOSED — guard fixed. The criterion it guards is still under review (see F218).

V4.4 announced, on the live estate:

> `hr_roster.salary_usd carries no DENY for mls_data_standard; ... the security policy
> sp_defect_tier does not exist`

Every one of those objects had been confirmed present and enabled, by hand, minutes earlier.

### The guard that should have caught it

V4.4 was written with an explicit observability probe, precisely because
`sys.database_permissions` answers a caller without catalog visibility with an **empty set**
rather than an error. The probe counted visible database **roles**:

> *Every database has built-in roles, so a caller that can see principals at all sees
> several. Zero means we are blind, not that the estate is unprotected.*

`mls-verifier` **can** see roles — built-in roles are visible to everyone — and **cannot**
see permission rows. The guard passed; the criterion then read an empty permission set and
reported the protection missing.

Measured as `admin@` on the same database: **284** rows in `sys.database_permissions`, **1**
security policy, **12** roles. The verifier saw enough of the third to satisfy the guard and
none of the first two.

### What the mistake actually was

The probe asserted a **neighbouring** view and concluded about the **target** view. Seeing
principals was taken as evidence of seeing permissions. That is the artefact substituted for
the capability — committed *inside the guard written to prevent that substitution*, which is
what makes it worth recording rather than merely fixing.

Break-glass readiness meant "an account is in the group" and passed on one holding no role.
V3.3 meant "an enabled CA policy exists" and failed on a tenant whose MFA came from Security
Defaults. This is the same error one level further in: the guard protecting against the error
made the error.

**Fix:** probe the exact view the criterion reads. `SELECT COUNT(*) FROM
sys.database_permissions` — every database carries baseline rows (public's CONNECT and
SELECT), so zero in the whole view means blind, never empty.

### The larger question this leaves open

With a correct guard, V4.4 will report UNOBSERVABLE **every time** it runs as `mls-verifier`.
Combined with **F218** — the column DENYs target a role that can never have members, so they
are inert — V4.4 is a criterion that can neither see its subject nor would find a working
control if it could. V4.5 already proves the thing that matters, by measurement, and passes.

V4.4 should be narrowed or retired rather than left to emit UNOBSERVABLE forever. A criterion
that can never reach a verdict is not a safeguard; it is noise that looks like diligence.

**RESOLVED the same day: V4.4 is retired.** V4.5 proves the policy *filters*, which strictly
implies it exists and is enabled — a disabled policy returns every row and fails V4.5. So the
artefact check asserted nothing V4.5 does not already prove, and unlike it, V4.5 is
observable by the verifier. Restore V4.4 if the sensitive tables ever move to a Fabric
Warehouse, where database principals exist and the column DENYs would actually bind.

L4 now reads: V4.1 labels, V4.2 (deferred to L11), V4.3 label policy, **V4.5 the row filter
enforces**, V4.6 the column denial is unobservable and says so.


---

## F225 — a binding error is reported as a failed criterion, on a run that evaluated none

*2026-09-21, rebuild attempt 3, L4.*

The data-layer criteria moved from L4 to L5 (following the protect step #294 had already
moved) and their **parameters moved with them**. `layer-04-purview.yml` kept passing
`-SqlEndpoint`, `-LakehouseName` and `-ProtectionPrefix`. Every audit script carries
`[CmdletBinding()]`, so PowerShell refused the call and not one criterion ran.

That part is an ordinary half-finished move. What is worth recording is **the verdict the
run announced**:

> `FAIL — at least one criterion FAILed`

No criterion had been evaluated. Measured rather than reasoned:

```
pwsh -NoProfile -NonInteractive -File <[CmdletBinding()] script> -Bogus y
→ "A parameter cannot be found that matches parameter name 'Bogus'."   exit 1
```

and `1` falls through the layer-audit action's `case` to `*)`, whose verdict is that
sentence. Exit **2** — `COULD NOT START` — is a code the audit chooses **for itself, after it
has started**; a bind failure happens before the script's first line, so the audit never gets
to choose anything. `action.yml` asserted the opposite in a comment ("which this action
reports as COULD NOT START") and had done since 2026-08-24. That comment is now corrected
against the measurement above.

The cost is a misdirection, not a delay. A reader who is told a criterion failed goes to look
at the estate. The transcript held no criterion table to contradict it, and an empty table
reads like a truncated log rather than like a call that never happened.

**This is F102/F103/F105's class in a new place.** Those were audits reporting a control
absent when they could not observe it. This is the *harness* reporting a criterion failed
when it could not run one. Same substitution: a non-zero exit stood in for a verdict, exactly
as an empty API response stood in for absence.

**Closed as a check, not as prose.** `verification/tests/failure-classes.Tests.ps1` now parses
every `uses: ./.github/actions/layer-audit` step in every workflow, reads the parameter names
in its `args:` block, and compares them against the param block of
`verification/layer-<nn>-audit.ps1`. Run against the pre-fix tree it names all three orphans
by name; it also asserts it discovered more than ten invocations, so it cannot pass by
finding nothing.

What it does **not** cover, so a green run is not mistaken for more: it checks that a passed
name exists, not that a value follows a flag that needs one (the action deliberately does no
pairing validation — a switch legitimately has no value — and that case fails loudly with
"Missing an argument for parameter"). It sees only invocations through the composite action,
which is all fifteen of them today.

---

## F226 — the estate's real tenant and subscription ids were committed, in docs, for sixteen days

*2026-09-21, found by V1.3 on a routine `verify-l1` run against `main`.*

`docs/findings/2026-09-05-acr-basetrigger-spike.md` (10 occurrences) and
`docs/superpowers/specs/2026-09-05-operationalize-self-healing-design.md` (1) carried the
live tenant and subscription GUIDs, pasted verbatim out of `az account show` and out of an
ACR error message. CLAUDE.md rule 5 is explicit that these live in GitHub environment
*variables*. Redacted to `<AZURE_TENANT_ID>` / `<AZURE_SUBSCRIPTION_ID>`, which loses nothing
the documents were using them for — in both files the id is incidental to the narrative.

**Why it survived sixteen days is the interesting half.** V1.3 runs two sweeps. The *generic*
GUID sweep — any GUID not on the reviewed allowlist — carries the pathspec `:!docs`. The
*specific* sweep, for the three real identifiers, carries no exclusion and greps everything.
So docs are covered by exactly one of the two, and that one needs `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID` and `FABRIC_CAPACITY_ID` present in the Verifier's environment —
absent, V1.3 returns **SKIP**, saying so honestly ("the half that greps the three real
identifiers could not run").

So the check was correct, honest about its own blindness, and reported the truth the first
time it ran with its inputs. Nothing here needs fixing. It is recorded because it is the
counter-example to most of this register: **an audit that said "I could not look" rather than
"there is nothing there", and was believed, and was right.** The gap it names is real — docs
are the one place a real identifier is most likely to be pasted and the least likely to be
swept — but closing it by dropping `:!docs` from the generic sweep would flood V1.3 with the
public and invented GUIDs that documentation legitimately quotes. The specific sweep is the
right instrument; it simply has to be given its inputs.

`FABRIC_CAPACITY_ID` was checked at the same time and is not committed anywhere.

---

## F227 — the rebuild proof reported a working estate as broken, because its child audits could not start

*2026-09-21, the first full teardown/rebuild cycle since 09-03.*

V11.2 and V11.3 both FAILed the up phase. The evidence they carried:

```
L1=FAIL(2) L2=FAIL(2) L3=FAIL(2) L4=FAIL(2) L5=FAIL(2)
L6=FAIL(2) L7=FAIL(2) L8=PASS L9=FAIL(2) L10=FAIL(2)
  L1: layer-01-audit could not start: Required input 'Repository' was not supplied.
  L2: layer-02-audit could not start: Required input 'SubscriptionId' was not supplied.
  L3: layer-03-audit could not start: Required input 'Domain' was not supplied.
  L4: layer-04-audit could not start: Required input 'Organization' was not supplied.
```

**Exit 2 is `COULD NOT START`.** Nothing was evaluated. The estate was never looked at. And
the estate was *fine*: L2, L3, L4, L5, L6 and L7's own audits had all passed, green, minutes
earlier in the same workflow run — L7 at 7 of 7.

### Two defects, stacked

**First, the inputs could not reach the child audits.** `layer-11-audit.ps1` launches
`layer-01..10-audit.ps1` in their own `pwsh` processes with only `-ReportRoot`/`-NoRetry`.
Every other input has to arrive through the inherited **environment** — there is no other
channel across a process boundary. `infra-up.yml`'s `layer-11-up` job declared no `env:`
block at all.

`infra-down.yml`'s verify job has carried exactly the needed block since F170, with exactly
this reasoning written in a comment above it:

> *Consumed by the CHILD L3/L4 audits, which layer-11-audit.ps1 launches in their own pwsh
> processes with only -ReportRoot/-NoRetry. They inherit this environment, and every input
> they need has an environment-variable fallback — which is the only channel available
> across that boundary.*

Somebody worked this out precisely, for one of the two callers, and it never reached the
other. **A fix applied to one of two call sites is half a fix** — the same shape as F145,
and F124's class in the medium of process environment: a value that exists, is spelled
correctly, and cannot be SEEN by the thing that reads it.

The proof is in the same cycle: the *identical* V11.2 **PASSED** in the down phase two hours
earlier, from the job that has the block.

**Second, and worse: a could-not-start was reported as a failed layer.**
`Invoke-LayerAuditSet` computed `Passed = ($run.ExitCode -eq 0)` and everything else was a
failure. But the audits emit three distinct non-zero codes — `2` could not start, `3`
filtered diagnostic, anything else a genuine criterion failure — and the layer-audit action's
own `case` statement already distinguishes them. Collapsing them made "I was never given the
tenant domain" indistinguishable from "the teardown deleted your Entra objects".

V11.2's detail text on failure reads: *"Any regression here means down.ps1 crossed the
tenant-object line: stop, do not run up.ps1, escalate."* A missing environment variable was
therefore dressed as a G3-boundary violation and a G4 event.

### This is F102/F103/F105 with the harness in the API's chair

Those three were audits reporting a control **absent** when they could not observe it. This
is the rebuild proof reporting a layer **broken** when it could not run one. Identical
substitution — a non-zero exit stood in for a verdict, exactly as an empty API response stood
in for absence — and it had been sitting inside the criterion whose entire job is to be the
last word on whether a rebuild worked.

It also explains the long-standing register note that **V11.3 "has never reported at all"**.
Not bad luck: a structural inability to start, on every run it has ever had.

### Fixed, in both halves

- `layer-11-up` now carries the env block (plus `FABRIC_CAPACITY_ID`, which the down phase
  does not need because it re-runs only L3/L4 while the up phase re-runs L1–L10), the S&C
  certificate staging, and the cleanup step.
- `Invoke-LayerAuditSet` now returns `Blind` for exit 2 and 3, and V11.2/V11.3 report
  **UNOBSERVABLE, naming the layers and codes**. The env fix removes today's cause; this
  removes the class, because the next missing input will be a different one and it must not
  be able to masquerade as a broken layer.

**It stays RED, and that is deliberate.** The first version of this fix recorded the blind
case as SKIP. That was wrong in the other direction: SKIP does not fail a run, so the
workflow would have printed *"PASS — no criterion FAILed"* over a rebuild proof that proved
nothing — the symmetric error CLAUDE.md names, *"an auditor that cannot see a control must
not be able to report it as PRESENT either"*, and the more dangerous half, because nobody
investigates green. The blind case is therefore a FAIL whose observed text begins
`UNOBSERVABLE:` and names the cause.

What changed is not the colour but the **claim**. Before, a missing environment variable
read as *"down.ps1 crossed the tenant-object line: stop, do not run up.ps1, escalate."* Now
it reads as *"these layers could not be examined; check the job's `env:` block before
suspecting the estate."* Same red, opposite instruction. `-SkipChildAudit` remains a SKIP,
because a caller that deliberately did not ask is the genuine *not asked* case — the same
distinction V5.6 draws between "no endpoint was supplied" and "an endpoint was supplied and
could not be read".

---

## F228 — a criterion that had never read a single response, and was right by accident

*2026-09-21, found while investigating V8.4's failure on the rebuild.*

`layer-08-audit.ps1` read three fields off each question in the agent-eval artifact:
`card`, `answer`, `responseText`. `apps/mcp-tools/evals/agent-eval.ts` writes `cards` and
`responses` — **both arrays** — and has never written any of the three.

**The card half was wrong and looked right.** `$card` was always `$null`, `$cardCount` always
`0`, and V8.4 always returned *"no Adaptive Card payload was recorded for any question"*. On
the day it was found that verdict was **factually correct** — the artifact really did carry
zero cards across all ten questions — and it was correct **by accident**. The identical
branch fires over ten valid cards.

**The other half is the serious one.** V8.4's second assertion is that no HTML, JS or JSX
comes back from the agent. It built its input as
`"$(...-Name 'answer')$(...-Name 'responseText')"` — two fields that do not exist,
concatenating to the empty string — and ran `Test-MlsGeneratedUi` over that. A
security-relevant check had examined **nothing, on every run, for the life of the project**,
while reporting PASS whenever a card happened to be present.

V8.2 read the same non-existent fields, and additionally requires a `referenceSql` per
question that the eval has never emitted at all (see F229).

**The fixture agreed with the audit, which is why nothing caught it.**
`verification/tests/layer-08-audit.Tests.ps1` built its questions with `answer`, `card` and
`referenceSql` — the schema the audit *believed in*, not the one the eval produces. Fixture
and audit agreed with each other and both disagreed with reality, so nineteen tests stayed
green over a criterion that could not work against anything the estate actually emits. That
is precisely the mirror CLAUDE.md forbids: *a fixture that re-wraps a return value is not a
test.*

**Closed as a check.** `failure-classes.Tests.ps1` now parses the keys of the
`results.push({ ... })` literal in `agent-eval.ts` — in both JavaScript spellings, since
`pass,` is ES6 shorthand and a parser that saw only `name:` invented a defect on its first
run — and compares them against every `Get-MlsProperty -InputObject $question -Name 'x'` in
the L8 audit. Run against the pre-fix tree it names all three orphans: `answer, card,
responseText`. The fixture now emits the real schema, and three new tests pin the
distinction the fix exists for: an artifact that could not be READ reports UNOBSERVABLE, an
artifact whose responses were readable and carried no card reports the missing card and says
how many responses it examined.

---

## F229 — V8.2 asks for evidence the eval cannot produce, and must not fake it

*2026-09-21.*

V8.2's premise is independence: the Verifier re-runs each question's reference query against
the lakehouse **itself** and compares, because *"accepting the artifact's own score would be
trusting the claim the criterion exists to check."* It reads `referenceSql` off each question
to do it.

No artifact has ever carried `referenceSql`. The golden questions in
`apps/mcp-tools/evals/questions.ts` define their expectations as
`expected: () => Promise<ExpectedFact[]>` — a **function** that queries the lakehouse inside
the eval process. There is no query string to hand on. The artifact carries the *computed*
`expectedFacts` and `missingFacts` instead.

**The tempting fix is the wrong one.** Reading `expectedFacts` would make V8.2 compare the
eval's answer against the eval's answer — a mirror, and the exact thing the criterion was
written to avoid. It would also look like a fix and report green.

So V8.2 now records **SKIP/UNOBSERVABLE** naming the missing input, rather than failing the
agent for the harness's gap or passing on the eval's own score.

**The real remedy is a decision, not a patch:** have the eval serialise each question's
reference SQL into the artifact so the Verifier can re-run it independently. That changes the
eval's question schema and changes what the demo claims about independent verification, so it
is recorded here for the sponsor rather than decided unilaterally. Until then V8.2 is honest
about being unobservable, which is the only other acceptable state.

The schema sweep in `failure-classes.Tests.ps1` exempts `referenceSql` **by name**, so
closing this gap removes an exemption rather than quietly widening a filter.

---

## F230 — the tiered-access demo segregated objects, not people, and the agent could name either

*2026-09-21. Found by asking "how soon can we test this", and testing it.*

The sponsor's ask was **"standard accounts don't see 3PPI, admin accounts do."** What the
estate does is **"the view hides 3PPI, the base table doesn't, and everyone can query both."**

Measured on the rebuilt estate, as the tenant's **Global Administrator**:

```
dbo.defect_reports    900 rows    (all 139 THIRD_PARTY_PROPRIETARY included)
dbo.v_defect_reports  761 rows
IS_ROLEMEMBER('mls_data_privileged') = 0
IS_ROLEMEMBER('mls_data_standard')   = 0
SUSER_SNAME() = admin@...onmicrosoft.com
```

**Nobody is in either role, and nobody can be.** F218: `CREATE USER` is unsupported on the
Fabric SQL analytics endpoint, so no principal can ever join one. Therefore:

| statement | intended effect | actual effect |
|---|---|---|
| `DENY SELECT ON dbo.defect_reports TO [standard]` | standard tier cannot read the base table | binds to **no principal** |
| `GRANT SELECT ... TO [privileged]` | admin tier can | binds to **no principal** |
| `IS_ROLEMEMBER('privileged')` in the RLS predicate | 1 for admins | **0 for everyone** |

The row filter on the **view** therefore works — and works identically for everyone. V5.6
passing is real and was never in doubt; what it proves is that *the filter filters*, not that
*a user is restricted*. Those are different claims and only one of them was ever being made.

### The half that made it a live problem

The agent's `query_lakehouse_sql` accepts any single SELECT. Its own header states the limit
plainly — *"That stops writes. It does not stop reads."* — and nothing restricted **which
object** a query could name. So "show me all the defect reports" returned third-party
proprietary rows, and "what does everyone earn" returned `salary_usd`.

`hr_roster` was worse than `defect_reports`: it had **no governed view at all**. Its entire
protection was a column-level `DENY` against the role nobody can join.

### Fixed as an application control, and that is a real limitation to say out loud

Identity-based enforcement needs database principals, which needs a Fabric **Warehouse**, not
a lakehouse SQL endpoint. That is not a six-day change. So the control now lives where it can
actually bind:

- **`v_hr_roster`**, the missing counterpart to `v_defect_reports`, projecting the roster
  without `salary_usd`, `bonus_target_pct` or `performance_band`. A view needs no role
  membership to be true.
- **A restricted-object gate** in the agent's SQL tool: `defect_reports` and `hr_roster` are
  refused, `v_defect_reports` and `v_hr_roster` are served, and the refusal **names the
  governed alternative** — the caller is an LLM that retries, and a bare "no" makes it guess.
- **V8.8** asserts this against the **deployed** tool, both directions. A gate that refuses
  everything is an outage wearing a control's clothes, so the criterion requires the base
  tables refused *and* the views answering, in the same run.

**The honest claim is "the agent cannot reach it", not "the data is protected".** Anyone with
direct lakehouse access still reads the base table. Saying the stronger sentence over this
implementation would be the exact overstatement this register exists to catch.

### A denylist, deliberately, with its weakness closed somewhere else

Enforcement matches restricted names as **whole identifiers** against SQL whose comments and
string literals have been scrubbed. That is sound here in a way a denylist usually is not: a
statement cannot read a table without naming it, and every route to an unnamed read is
already refused — `EXEC` and dynamic SQL by the verb list, a second statement by the
single-statement rule, `OPENROWSET`/`OPENQUERY` by the T-SQL extras.

Whole-identifier matching is also what keeps `v_defect_reports` available while
`defect_reports` is refused: there is no word boundary between `_` and `d`.

A denylist's real weakness — a new sensitive table permitted by default — is closed at
**build** time instead: a test asserts every table in `schema-manifest.json` is explicitly
either restricted or permitted, so adding one fails the suite until somebody classifies it.

### The bypass the tests found, which is the part worth remembering

The first version of the gate ran against `scrubSql`'s output. That function replaces every
quoted identifier form — `[brackets]`, `"quotes"`, `` `backticks` `` — with a neutral
placeholder, which is **correct** for the checks it was written for (a column named
`[delete]` must not read as the DELETE verb) and **exactly wrong** for matching object names:

```
SELECT * FROM [dbo].[defect_reports]   ->   SELECT * FROM  id  .  id
```

The gate saw nothing and allowed it. **An agent writing T-SQL emits bracketed identifiers as
a matter of course**, so this was not an exotic evasion — it was the likely shape of an
ordinary query, and the control would have shipped with a bypass its own author would have
triggered on the first live demo.

Caught by the bypass tests, which is what they are for, and fixed with a second scrub mode
that unwraps identifiers rather than erasing them. Every quoting form is now a test case.

The general lesson is not about SQL: **a check that reuses a transform built for a different
question inherits that question's assumptions.** The scrub was right; it was right about
something else.
## F231 — showpiece #3's product claim was resting on a 24-second race, which it lost every time after the first

*2026-09-21. Found because it blocked three of this session's own pull requests in a row.*

CLAUDE.md states it as a product claim, explicitly not a convenience:

> *A security patch GitHub generated for a named advisory that cleared the full gauntlet
> auto-merges unattended in **both** modes — that is the product claim, not a development
> shortcut.*

It does not. It arms, and then it stalls.

### The mechanism, measured

| fact | value |
|---|---|
| `main`'s ruleset | `strict_required_status_checks_policy: true` — a branch must be up to date with base |
| the `compliance` workflow | commits verification state to `main` **after every merge** — 7 of the last 12 commits |
| GitHub auto-merge | does **not** update a branch that falls behind; it waits for conditions that will never become true on their own |

So an armed PR goes `BEHIND` the moment anything else lands, and waits there.

**PR #285** — a Copilot Autofix for code scanning alert #8 — green, auto-merge enabled,
**30 commits behind**, open since 09-17. **PR #291**, 17 behind.

**PR #286 is the one heal that ever did merge unattended**, and it is the whole story:

```
created  2026-09-18T06:37:32Z
merged   2026-09-18T06:41:39Z
compliance commit lands 06:42:03Z   <- twenty-four seconds later
```

It won a race. Had the compliance job pushed first, #286 would have gone `BEHIND` and
stalled exactly like #285 — and the register would have recorded showpiece #3 as never
having worked at all, rather than as working once.

**The estate's own automation defeats its own showpiece, on a schedule.** Nothing external
is required.

### It also blocked this session, three times

#302 and #303 both went `BEHIND` between going green and being merged, and #303 twice. That
is how it was found: not by auditing the showpiece, but by being unable to merge anything
without racing a robot.

### Fixed: a job that updates armed pull requests that have fallen behind

Added to `self-heal.yml`, which already owns the showpiece and already runs every six hours.
It updates any open PR with auto-merge **armed** that is behind its base, which re-runs its
checks and lets auto-merge fire. It merges nothing itself and arms nothing: a PR nobody armed
is left alone, and the gauntlet still decides. The stall is bounded to one scheduled interval
instead of forever.

A PAT is required rather than preferred: a branch update pushed with `GITHUB_TOKEN`
triggers no workflow runs (**F120**), so the required checks would never report on the new
head and the PR would be stuck in a different way. Without `SELF_HEAL_TOKEN` the job says so
and exits rather than creating that.

### The bug inside the fix, which is the part worth keeping

The first version selected PRs with
`select(.autoMergeRequest != null and .mergeStateStatus == "BEHIND")`. Tested against the
live repository seconds after a rebase moved `main`, it returned **nothing** — then
`291,285` on each of the next three calls.

**`mergeStateStatus` is computed lazily.** Immediately after the base moves it reads
`UNKNOWN`, and that is *exactly* the window this job runs in. An empty result is
indistinguishable from "nothing to do", so the job would have announced **"No armed pull
request is behind base"** at precisely the moment the most had just fallen behind — a
confident, specific, wrong answer that nobody would have investigated, because it was green.

That is F102/F103/F105's class occurring **inside the fix for a defect of the same family**,
and it was caught only by running the filter against the live repository instead of reading
it.

Detection now asks the **commit graph** instead: `repos/{}/compare/{base}...{head}` returns
`behind_by` as a number, immediately, every time. Verified live — `#285: behind_by=30`,
`#291: behind_by=17`. A compare that does not answer is reported as UNKNOWN and never as
"up to date".

**The lesson is the one this register keeps paying for in new clothes:** a field that
describes a *prediction* (will this merge?) is computed when someone asks and may not be
ready; a field that describes the *graph* (how many commits apart are these?) is a fact.
Prefer the fact, especially in a check that runs at the moment the prediction is most stale.

---

## F232 — the heal PR is blocked by a comment the scanner wrote about the alert it is fixing

*2026-09-22. Found by checking whether F231's fix actually made the showpiece work, rather than assuming it had.*

F231 unstuck the heal PRs from being **behind** base. Both were updated, both stopped being
behind, and **neither merged.** They moved from `BEHIND` to `BLOCKED`.

`main`'s ruleset also sets **`required_review_thread_resolution: true`**. Copilot Autofix
opens the heal PR, and the **`github-advanced-security`** bot posts a review comment
describing the alert being fixed. That comment is an unresolved review thread. Nothing
resolves it. Auto-merge never fires.

| PR | state | review threads | unresolved |
|---|---|---|---|
| #286 | **MERGED** | **0** | 0 |
| #285 | OPEN | 1 | **1** |
| #291 | OPEN | 1 | **1** |

**#285 had all twelve required checks green, `mergeable: MERGEABLE`, auto-merge `ARMED` — and
was still `BLOCKED`.** Every gate the product claim talks about was satisfied.

So showpiece #3 has worked exactly once, and it worked because **#286 happened to carry no
review comment at all**. Not because the gauntlet passed — because the scanner stayed quiet.

### Two independent defects, and the first fix hid the second

F231 (behind base) and F232 (unresolved thread) are unrelated causes with the same symptom.
Fixing F231 was necessary and did nothing observable, because F232 was waiting behind it.
That is worth recording on its own: **a fix that removes one of two blockers produces no
change in behaviour, which reads exactly like a fix that did not work.** The only reason this
was found is that the claim was re-checked after the fix instead of being marked closed.

### The fix, and the boundary that matters more than the fix

A step in `self-heal.yml` resolves unresolved review threads on PRs that have auto-merge
armed — **only where every comment on the thread was written by a known scanner bot**
(`github-advanced-security`, `github-actions`, `dependabot`). A thread carrying even one
human comment is left alone and reported.

That boundary is the whole design. `required_review_thread_resolution` exists to stop a
human's review being steamrolled, and a heal a human paused must stay paused. Resolving a
machine's description of the alert it just fixed is what a human would do on merging;
resolving a person's objection is not, and no amount of green makes it so.

A refused mutation is reported as a warning naming the missing permission, never swallowed —
the PR stays BLOCKED and says why.

### Not fixed by widening the rule

Turning `required_review_thread_resolution` off would unblock these PRs and every other one,
including a PR where somebody raised a genuine concern. The narrow fix costs a bot allowlist;
the wide one costs the control.

---

## F233 — the cards were always there, in the other field, and the probe I built to check agreed with me

*2026-09-22. Found because the sponsor said "I have seen adaptive cards in responses I asked".*

V8.4 reported zero Adaptive Cards across ten golden questions, and I concluded from that
artifact that **"the agent answers in prose"**. The sponsor had watched the control tower's
Ask tab render cards. Both observations were of the same system; at most one could be about
the agent.

Captured from the deployed agent over Direct Line:

```
attachments on the wire : 0
text (1007 chars)       : Meridian's operations lakehouse shows Falcon 9 Block 5 leading
                          with 486 launches.
                          { "type": "AdaptiveCard", "version": "1.6", "body": [ ... ] }
```

**The agent emits Adaptive Cards embedded in the message TEXT, not as attachments.**
`apps/control-tower/src/agent/transcript.ts` has always known this — *"only adopt the
text-borne cards when the activity carried none as attachments"* — which is exactly why the
Ask tab renders them and the eval recorded none.

### V8.4 was wrong twice about the same capability, in opposite directions

| | what it read | result |
|---|---|---|
| originally (F228) | `card` — a field the eval never wrote | always zero |
| after F228's fix | `cards` — the **attachments** array | always zero, because the cards are in `text` |

**I fixed the field name and kept the wrong transport.** A name and a channel are different
mistakes, and repairing one while preserving the other produces a change that looks like
progress and measures exactly as much as before: nothing.

### The part that matters more than the bug

When the artifact said zero, I wrote a probe to check — and **built it to count attachments**,
because that is where I believed cards lived. It returned zero. I reported that as
confirmation.

**An instrument built from the belief it is testing cannot disconfirm that belief.** Three
separate observations agreed with me (the artifact, the criterion, my probe) and all three
shared one assumption. It took a person contradicting the result to break it, and the fix was
then twenty minutes of work.

This is the sharpest instance of the session's recurring class, and the only one that no
sweep would have caught: every sweep here compares a check against a *declaration*, and the
declaration was wrong too.

**Closed as a check.** The eval now extracts text-borne cards, mirroring the control tower,
with attachments still preferred if Copilot Studio ever sends them properly. The tests are
pinned against the **real captured reply**, committed as
`apps/mcp-tools/tests/fixtures/agent-reply-with-text-borne-card.txt` — a hand-written fixture
would have encoded the same wrong assumption faithfully.

### The version, resolved separately and deliberately

The real card declares **1.6**; V8.4 pinned **1.5** and compared exactly, so the corrected
criterion first failed with *"version is '1.6', expected '1.5'"* — **true**, where *"no
Adaptive Card payload was recorded"* had been false.

The pin moved to 1.6 by sponsor decision, on evidence rather than convenience:

- the card uses `TextBlock` and `FactSet`, both **1.0** elements, so the version gates hosts
  and describes nothing the card needs;
- **there are no card builders in this repository** — Copilot Studio composes the card and
  chooses the version, so pinning 1.5 would mean instructing an LLM to comply indefinitely;
- the 1.5 rationale was *"Teams is limited to 1.5"*, explicitly marked `[derived]`, and Teams
  is not a surface this demo uses.

The **element allowlist was not widened**: accepting a 1.6 declaration is not accepting every
1.6 element.

---

## F234 — a backspace where a word boundary was meant, in a test written an hour earlier

*2026-09-22, caught by the repository's own control-character sweep.*

```
apps/mcp-tools/tests/sql-dialect.test.ts line 589 : 0x08
```

A reference-query test added an hour before carried **four literal BACKSPACE characters**
where `\b` word boundaries were meant:

```
/<0x08>(strftime|julianday|group_concat)<0x08>/i
/<0x08>LIMIT<0x08>/i
```

**Those regexes match nothing.** The test passed — vacuously — and would never have caught a
golden question written with SQLite-only syntax, which is the only reason it exists.

CLAUDE.md documents this class in the words it happened in: *"a regex of `/<0x08>429<0x08>/`
where `\b` was meant (a literal BACKSPACE character, matching nothing, in a security-relevant
throttle check)"*. The rule is that file **content** is written with a file tool, never
through a shell heredoc. It was written through a heredoc, the content crossed two escaping
layers, and `\\b` arrived as `\b` arrived as `0x08` — **within the hour, by someone who had
just written about the rule.**

**It is invisible to every ordinary check.** `git diff` renders it as nothing, the file
reader renders it as nothing, TypeScript compiles it, and vitest reported 90 passing. Only
the sweep that exists for this found it.

**Repaired by byte value rather than another escape sequence** — `chr(8)` → `chr(92) + 'b'` —
so the fix itself contains nothing that could be damaged the same way. Verified against the
**bytes**, not the rendering, and then verified the regexes *discriminate*, which is the part
that was actually broken:

```
/\b(strftime|julianday|group_concat)\b/i
  'SELECT strftime(...)'        -> true       'SELECT TOP 1 DATENAME(...)'  -> false
/\bLIMIT\b/i
  '... LIMIT 1'                 -> true       '... TOP 1'                   -> false
```

A passing test proves nothing until it can fail.

---

## F235 — V11.3 claimed all ten layers were green after examining two

*2026-09-22, run `35680129860`.*

The run was narrowed with `-ChildAuditLayer 3,4` to test a certificate fix without a
two-and-a-half-hour full pass. The report:

```
| **V11.3** | Post-up: all layer audits green | **PASS** |
  - Expected: PASS for every layer audit L1-L10 against the rebuilt environment
  - Observed: L3=PASS L4=PASS
```

**It examined two of ten and reported the whole claim as PASS.**

The evidence underneath was honest — the `Observed` line names exactly what ran, and the
preflight table says `Child audits | layers 3,4`. **The verdict was not**, and a criterion
table is read by verdict. `l11_child_audit_layers` documents the constraint in its own
description — *"narrowing the set narrows what V11.3 may claim"* — and **nothing enforced
it**, so narrowing silently bought a green for a claim nobody had checked.

### The symmetric form of this register's oldest rule

F102/F103/F105 say an auditor that cannot see a control must not report it **absent**. It
must equally not report it **present**. A partial run is a **diagnostic** — the standing
`-OnlyCriterion` already has, exiting 3 precisely so a filtered run cannot be mistaken for a
sign-off.

V11.3 now records SKIP, naming what it examined and what it never looked at.

### The branch that matters more than the fix

**A failure inside a narrowed set is still a failure.** Narrowing removes the right to claim
the whole; it does not excuse what was seen to be broken. Without that branch this fix would
have laundered a real failure into a SKIP — a worse defect than the one it repairs — so it
has its own test.

Found by narrowing the set and then reading the report instead of the console. The criterion
table is what people read, and it was the thing that lied.

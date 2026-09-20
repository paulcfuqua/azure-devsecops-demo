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


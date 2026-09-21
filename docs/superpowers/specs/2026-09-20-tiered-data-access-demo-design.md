# Tiered data access and access audit — design

**Date:** 2026-09-20
**Status:** design, approved in outline; not implemented
**Sponsor framing:** *"I want to demo data restrictions. Answering who CAN look is powerful.
Answering who DID look is even more powerful."*

---

## 1. What this demonstrates

Two new lakehouse tables carry genuinely mixed sensitivity. Two agent tiers query them. A
standard user and a privileged user type **the same question into the same box** and get
different answers — and the difference is enforced by the database, not by the agent, not by
a prompt, and not by the UI.

Then the estate answers the second question: **who actually looked.** Every query is
attributable to a principal, with its SQL text, its row count, and — for a refused query —
its error code.

### The claim, stated precisely

> Access is segregated by identity and enforced at the data layer. Every access attempt,
> allowed or denied, is recorded with the principal that made it.

Nothing here claims that a Purview sensitivity label enforces access. It does not, and
believing it did is how **F18** happened (see § 9).

---

## 2. What the spike proved — 2026-09-20

Three probes against the live estate. Throwaway objects, all named `zz_spike_*`, dropped,
and residue-checked against `sys.objects` and `sys.database_principals` rather than assumed.

| Probe | Question | Verdict |
|---|---|---|
| **A** | Can a *lakehouse* SQL analytics endpoint enforce CLS and RLS? | **YES, both** |
| **C** | Does Fabric expose query history naming the calling principal? | **YES, richer than expected** |
| **B** | Can a Purview label be applied to a Fabric item from code? | **UNRESOLVED** |

### A — enforcement mechanisms, confirmed

Against `mls_operations` on the endpoint resolved from the Fabric API (never stored — F129):

- `CREATE VIEW … WITH SCHEMABINDING` over a Delta table — **works**
- `CREATE FUNCTION … RETURNS TABLE WITH SCHEMABINDING` (RLS predicate) — **works**
- `CREATE SECURITY POLICY … ADD FILTER PREDICATE … WITH (STATE = ON)` — **works**, and the
  result is visible in `sys.security_policies` with `is_enabled = True`
- `CREATE ROLE` — **works**
- `DENY SELECT ON dbo.<table>(<column>) TO <role>` — **works**. This is column-level security

**Two earlier attempts failed on defects in the probe, not in Fabric**, and the record is kept
because the failure pattern is the point: attempt 1 bound a policy to a view that was not
`SCHEMABINDING`, and Fabric's error named the *policy*; attempt 2 used a column name written
from memory (`vehicle_name`) that does not exist, and the cascading failure then reported the
*policy* as unable to find its target. Both times the error named a system that was fine.
Resolve the schema from the endpoint before building against it.

### C — the audit surface, already present

`queryinsights.exec_requests_history` exists on the endpoint and carries, per statement:

| Column | Use |
|---|---|
| `login_name` | **the calling principal** — service principals appear as `<clientId>@<tenantId>` |
| `command` | the SQL text submitted |
| `row_count` | how much data was returned |
| `status`, `error_code`, `error_severity` | **a refused query is recorded here** |
| `submit_time`, `total_elapsed_time_ms` | when, and how long |
| `data_scanned_*_mb` | scan volume, which ties access to cost |

Sibling views also present: `exec_sessions_history`, `frequently_run_queries`,
`long_running_queries`, `external_api_call_stats`, `sql_pool_insights`.

**Consequence: the data-layer audit needs no new authenticated surface.** It is a `SELECT`
against the endpoint the MCP already queries. The agent can read its own audit trail through
the existing tool path.

**Consequence for the demo: a denial and its audit record are the same row.** The standard
tier's refused query appears with a principal, the attempted SQL, and an error code.

**Open refinement, not a blocker.** The probe read `queryinsights` as `admin@`, a wide
credential. Whether a low-privileged principal sees only *its own* statements is unverified.
If it does, the audit reader needs a privileged identity of its own. Establish this before
building the audit tool — and if it cannot be established, the tool reports **UNOBSERVABLE**,
never "no access occurred" (§ 7.4).

### B — item labelling, unresolved

`POST /v1.0/myorg/admin/informationProtection/setLabels` is **reachable and authorised** —
the call returns HTTP 400 with payload-validation detail, not 401/403. Every artifact type
tried (`Dataset`, `Report`, `Lakehouse`, `SQLEndpoint`) was rejected with
`changeLabelDetails.artifacts: Invalid value`, while a well-formed `labelId` passed
validation.

So the original Wall-3 prediction — that licensing or entitlement blocks this — is **wrong
about the reason**. The blocker is the artifact model of a Power BI-era API. This gets one
timeboxed follow-up (§ 10); it must not block §§ 5–7.

---

## 3. Architecture — three planes

A secure enterprise separates these and never lets one do another's job.

| Question | Plane | Mechanism |
|---|---|---|
| What is this data? | **Classify** | Purview label taxonomy (§ 8) |
| Who *can* look? | **Control** | Entra group → agent; agent identity → DB role; CLS/RLS at query time (§ 5, § 6) |
| Who *did* look? | **Observe** | Entra sign-in + agent span + `queryinsights` (§ 7) |

### The chain that connects them

```
human  ──(Entra SignInLogs)──▶  which agent
       ──(MCP tool span)─────▶  which service principal
       ──(queryinsights)─────▶  which query, how many rows, allowed or denied
```

Three logs, three joins, one answer to "who did look."

### Why two agents rather than per-user OBO

An agent querying data for a user is a **confused deputy**: more privileged than its callers
and unable to tell them apart, so whatever it can read, any caller who reaches it can read.

Two agents do not solve that — they **collapse** it. If each agent's caller population is
homogeneous, the deputy's privilege matches the caller's entitlement by construction, and the
agent makes no security decision at all.

Per-user on-behalf-of was considered and rejected for this iteration: nothing in the chain
carries user identity today (one shared inbound bearer token; one outbound managed identity),
and **F135** records the estate already hitting a precondition wall on user tokens.

---

## 4. Data model

Generated by `data/generators` — synthetic, deterministic, same pattern as the existing ten
tables. No real person's data (hard rule 4).

### 4.1 `hr_roster` — mixed sensitivity by **column**

| Column | Tier | Note |
|---|---|---|
| `employee_id`, `display_name`, `department`, `job_family`, `location` | open | ordinary roster data |
| `start_date`, `tenure_years` | open | the sponsor's example of non-sensitive HR data |
| `manager_id`, `employment_type` | open | |
| **`salary_usd`, `bonus_target_pct`, `performance_band`** | **restricted** | CLS denies these |

### 4.2 `defect_reports` — mixed sensitivity by **row**

| Column | Note |
|---|---|
| `defect_id`, `vehicle_id`, `reported_date`, `severity`, `subsystem`, `status` | ordinary |
| `summary`, `root_cause` | ordinary |
| **`classification`** | `INTERNAL` or `THIRD_PARTY_PROPRIETARY` — the RLS predicate reads this |
| `supplier_id` | joins `suppliers`; 3PPI rows reference third-party components |

`vehicle_id` and `supplier_id` must reference the existing `vehicles` and `suppliers` tables
so the referential-integrity tests in `data/generators/tests` extend naturally.

### 4.3 The two failure modes are different, deliberately

This contrast is demo material, and both behaviours are correct:

- **3PPI rows (RLS)** — rows silently vanish. The standard tier sees N−k of N defects with no
  indication the rest exist. No information leak, not even of existence.
- **Salary columns (CLS)** — a hard error naming the denied column. A visible refusal.

Choose per data type based on whether *existence itself* is sensitive. Say this out loud in
the demo; it is the kind of distinction an audience with auditors will recognise.

---

## 5. Enforcement design (plane 2)

### 5.1 Database objects

```
dbo.hr_roster                    base table (L5 seeds)
dbo.defect_reports               base table (L5 seeds)

dbo.v_defect_reports             schema-bound view over defect_reports
dbo.fn_defect_tier_predicate     schema-bound inline TVF
dbo.sp_defect_tier_policy        SECURITY POLICY, FILTER PREDICATE, STATE = ON

role: <prefix>_data_standard     the standard tier
role: <prefix>_data_privileged   the privileged tier
```

- **CLS:** `DENY SELECT ON dbo.hr_roster(salary_usd, bonus_target_pct, performance_band) TO <prefix>_data_standard`
- **RLS:** the predicate returns a row when `IS_ROLEMEMBER('<prefix>_data_privileged') = 1`,
  otherwise only for `classification <> 'THIRD_PARTY_PROPRIETARY'`

RLS binds to the **schema-bound view**, not the base table (proven in probe A). The standard
tier is granted the view and denied the base table, so the view is the only door.

### 5.2 Identities

| Tier | Principal | DB role |
|---|---|---|
| standard | `mls-mcp-demo-id` (existing) | `<prefix>_data_standard` |
| privileged | **new** user-assigned identity | `<prefix>_data_privileged` |

The new identity must be created where a rebuild reproduces it. `mls-rg-identity` already
exists outside the teardown blast radius for `mls-aws-demo-id`; decide deliberately whether
the privileged identity belongs there (survives teardown) or in the blast radius (rebuilt
each time). **Recommendation: in the blast radius**, so the rebuild proves it — the AWS
identity is outside only because an AWS trust policy pins to its `sub`.

### 5.3 MCP server changes

- Inbound: `auth-gate.ts` accepts **two** tokens and resolves a `tier` — no behaviour change
  when only one is configured, so the single-tier path stays intact
- Outbound: `tools/auth.ts` selects the managed identity by tier
- A tier is **never** taken from the request body or a tool argument. It comes from the
  presented credential only

### 5.4 Naming

`<prefix>` / `<env>` tokens throughout, resolved from `MLS_COMPANY_PREFIX` /
`MLS_ENV_SEGMENT`. No hardcoded `mls` — including in role names, which F90 shows is the half
of a rebrand nobody sees.

---

## 6. The Ask box and the entry guard

### 6.1 One box

The control tower keeps **one** Ask box. On load it resolves the signed-in user's group and
binds the box to the standard or privileged Direct Line endpoint. No mode selector, no second
tab.

Two labelled boxes were rejected: they make the UI look like the thing deciding, which
undermines the exact claim being demonstrated.

### 6.2 The precondition that must be checked FIRST

Binding by group requires the user's group to arrive in Easy Auth claims. **This is not
assumed.** Before anything is built on it, verify that `/.auth/me` actually returns a group
claim — `groupMembershipClaims` must be configured on the app registration; groups do not
appear by default.

This is **F135's lesson applied before the fact**: *verify that the input can be obtained
before verifying that it is valid.* F135 cost a shipped, mutation-tested token verifier that
could never execute because the token it verified was never present.

**Fallback if group claims cannot be obtained:** two tabs, the privileged one rendered only
for entitled users. Robust, less striking, small change. Decide on evidence, not preference.

### 6.3 Answering "how do I know the UI isn't just hiding it?"

Show the `queryinsights` row: that user's agent submitted the query and the *database* refused
it, with an error code. The enforcement is provably not in the browser. This is why plane 3
belongs in the demo and not only in the governance story.

---

## 7. Audit design (plane 3)

### 7.1 Entra sign-in — who opened which agent

**Verified 2026-09-20: no tenant diagnostic setting exists.** `SignInLogs` and `AuditLogs` are
routed nowhere.

This is a deliberate G0 human step, not an omission —
[`layer-06-platform.yml`](../../../.github/workflows/layer-06-platform.yml) explains that
creating it needs Security Administrator, and F8 specifically narrowed `mls-github-deployer`
to shrink that blast radius. It is `docs/runbooks/g0-bootstrap.md` § C item 12 and the sponsor
runs it.

**Until it is run, this leg does not exist and the spec must not imply otherwise.**

### 7.2 Agent call — which tier, which tool

The MCP already emits a span per tool call carrying `mls.tool.name`, `mls.tool.outcome`,
`mls.tool.row_count`, `mls.tool.duration_ms`, through a deliberate attribute allowlist.

Add **one** attribute: the caller tier. It goes through the same allowlist, which exists to
keep sensitive values out of telemetry — the tier is a label, never the query text, never a
row value.

### 7.3 Data layer — which principal, which query, allowed or denied

A read over `queryinsights.exec_requests_history` (§ 2). Exposed as a tool so the privileged
agent can answer "who queried HR data today" from the Ask box.

The tool is available to the **privileged tier only**: an audit trail naming who read what is
itself sensitive.

### 7.4 The rule every audit leg obeys

Audit pipelines lag. `queryinsights` retention and latency are finite, Log Analytics ingestion
is not instant, and the unified audit log can lag well over an hour.

**An audit that cannot see a window says so. It never reports the window as empty.** A leg
that cannot establish it could observe returns **UNOBSERVABLE**, never PASS and never "no
access occurred." This is F102/F105/F103's class, the most expensive defect family this
repository records, and an access audit is the worst possible place to repeat it.

Handled well this is not a caveat but a selling point: the estate refusing to overstate
itself, live, in front of the audience.

---

## 8. Classification (plane 1)

Two labels join the existing four-label taxonomy in
[`infra/purview/labels.ps1`](../../../infra/purview/labels.ps1), which is automated,
idempotent and already covered by V4.1/V4.3:

- `<prefix>-hr-sensitive`
- `<prefix>-3ppi`

Applying a label **to the Fabric item** is § 2's probe B, unresolved. It gets one timeboxed
follow-up. If it fails, the taxonomy is automated and item application is a documented manual
portal step, recorded plainly — the F18 treatment, which is the honest one.

**No criterion may assert that a label enforces access.** It does not.

---

## 9. What this design explicitly does not claim

- **Purview labels do not gate reads.** Classification, DLP, audit — not query-time access
  control. L04.md once claimed otherwise; that was **F18**, corrected rather than implemented
- **This is not per-user authorisation.** It is per-tier, and the tier is the agent's
  identity. A user's entitlement is expressed by which agent they can open
- **The audit covers the paths it covers.** `queryinsights` sees the SQL endpoint. Direct
  OneLake access, exports and semantic-model paths are different doors. Either instrument them
  or name them as uninstrumented — an audit's worth is bounded by the number of doors, and
  claiming completeness without enumerating them is the failure this whole document guards
  against

---

## 10. Sequencing, and the one rebuild that remains

The estate is scheduled for teardown around **2026-09-27**. There is **one rebuild left**, and
it is the only thing that can prove any of this survives a teardown.

**Everything durable must land before that rebuild.** Anything built after it is unproven
forever, because the estate will not exist to test it again. V8.6/V8.7 and the Key Vault grant
are in exactly that state today and are the cautionary example.

Order:

1. **Preconditions, cheap and blocking** — Easy Auth group claims (§ 6.2); whether a
   low-privileged principal can read `queryinsights` (§ 2); sponsor runs G0 § C item 12 (§ 7.1)
2. **L5 — the tables.** Generators, seed, referential integrity tests
3. **L4 — the protection.** Roles, CLS, RLS, security policy. L4 has not run since 2026-09-03,
   so schedule it early: its first run here also re-proves L4 itself
4. **Plane 3 legs** — span attribute, audit tool
5. **Plane 2 identity + MCP** — second identity, two tokens, tier resolution
6. **Copilot Studio** — two agents, connections, Entra group. Portal work, manual by nature
   (F202): a newly discovered tool arrives **disabled**, so confirm by arithmetic
7. **Timeboxed probe B**, then bake in if it resolves
8. **Rebuild** — the proof
9. **Capture screenshots while the estate is up.** Prose can be written after shutdown;
   screenshots cannot

**Honest assessment:** this is more than seven days of work alongside the queued
`#284 → L7 → rebuild`. The order above front-loads what must exist before the rebuild and
leaves the Copilot Studio tiering — the least automatable part — last. If the clock runs out,
what exists should be complete and true rather than half-wired, and the remainder ships as
this spec.

---

## 11. Verification

Every layer ships a triplet: deploy path, teardown, `verification/` audit script. New criteria
continue existing numbering — L4 ends at V4.3, L5 ends at V5.4, both confirmed 2026-09-20.

| ID | Layer | Asserts |
|---|---|---|
| **V5.5** | L5 | `hr_roster` and `defect_reports` exist and are populated — **row counts, not a status code** (the V7.6 lesson) |
| **V5.6** | L5 | 3PPI and non-3PPI rows both exist; a table with no restricted rows demonstrates nothing |
| **V4.4** | L4 | The security policy exists and `is_enabled = 1` in `sys.security_policies`; the column DENYs exist in `sys.database_permissions` |
| **V4.5** | L4 | **Enforcement, not configuration.** ⚠️ **Revised during implementation — see below.** Reports SKIP: the refusal cannot be provoked from this endpoint at all |
| ~~V4.6~~ | — | **Dropped.** V4.1 already asserts the taxonomy is *exactly* the six names, so a labels-exist criterion is two ways to learn one fact — the same redundancy V5.6 turned out to be against V5.3 |
| **V4.7** | L4 | The data-layer audit is readable and attributes a known query to a known principal — or reports **UNOBSERVABLE** with the reason. Never "no access occurred" |

The Entra sign-in leg (§ 7.1) is a **precondition, not a criterion**: it is a one-time G0 human
step, so a criterion asserting it would fail the estate for a thing the estate cannot do. The
audit tool reports its absence as UNOBSERVABLE instead.

**V4.5 is the criterion that matters, and it cannot be run here.** Established
2026-09-20, after the spec was written:

- **`EXECUTE AS` is not supported on a Fabric lakehouse SQL analytics endpoint** — Msg 15868.
  It is a *feature-level* refusal, not a permission error, so no credential makes it work.
- **There is nothing to impersonate anyway.** The endpoint's only database users are `dbo`,
  `guest`, `sys` and `INFORMATION_SCHEMA`. A database ROLE is not a user.
- **`mls-verifier` cannot join the standard role to test it**, because V5.3 requires it to see
  all 900 `defect_reports` rows and a member of the standard tier sees the filtered subset.

So V4.5 reports **SKIP**, names the blocker, and names where the capability *is* observable:
the two-tier agent path, where the standard tier's own identity is refused by the database.
That criterion belongs with the agent tiering, not here.

**V4.4 does not stand in for it, and says so.** The rule stands even though this instance
cannot satisfy it — break-glass readiness once meant "an account is in the group" and passed
on an account holding no role; V3.3 meant "an enabled CA policy exists" and failed on a tenant
whose MFA came from Security Defaults. An artefact check that quietly inherits the
capability's name is how that happens. **A criterion that cannot look must never report the
control present.**

**What V4.4 did gain from this:** it establishes that it *can see* before reading anything
into what it saw. `sys.database_permissions` answers a caller without visibility with an empty
set rather than a denial, and `mls-verifier` holds workspace Viewer — so empty would have
meant "no DENY exists" and V4.4 would have failed a *correct* estate. It now counts visible
built-in roles first: zero means blind, and it reports UNOBSERVABLE.

---

## 12. Open questions

1. Can a low-privileged principal read `queryinsights`, or only its own statements? (§ 2)
2. Do Easy Auth group claims reach `/.auth/me`? (§ 6.2)
3. Does probe B resolve within its timebox? (§ 8)
4. Does the privileged identity belong inside or outside the teardown blast radius? (§ 5.2)
5. Can an RLS policy bind directly to a lakehouse base table? Untested **by choice** — binding
   a policy to a live seeded table risked showpiece #2. The view path works and is sufficient

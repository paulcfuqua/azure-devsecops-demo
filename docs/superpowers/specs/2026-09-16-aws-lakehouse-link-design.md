# Cross-cloud lakehouse link — Azure agent, AWS Athena

**Status: SHIPPED, 2026-09-16 → 2026-09-17.** All nine plan tasks merged to `main`
(PRs #265, #266, #267, #269, #271, #272, #275, #276, #277). The agent answers from both
lakehouses and distinguishes them unprompted. Approved in conversation 2026-09-16,
sponsor-decided; built against a hard estate shutdown of ~2026-09-27.

**What shipping proved, and what it did not.** The link answered on 2026-09-16 at ~23:15Z —
`SELECT COUNT(*) FROM launches` → **286,473 rows in 4,431 ms** — with no redeploy and no
hand-patch, from an Azure-hosted agent holding no AWS credential. **V8.6 and V8.7 have
passed exactly once** (run `35166952968`, 2026-09-17T00:38Z) against an estate that has
never been torn down since they existed. That is an observation. The rebuild is what would
make it a property, and §2.2 already says so about the durability argument this whole design
rests on.

**Five design assumptions were wrong, all of them in instructive ways**, and each is
corrected in place below rather than being quietly overwritten:

| § | What the design assumed | What was true |
|---|---|---|
| 2.1 | audience `api://${prefix}-aws-athena-${env}` | rejected by this tenant's policy; the live value embeds the **tenant id** |
| 2.1 | one OIDC provider, v2.0 issuer | the token version was an **undeclared null**, meaning v1; two providers registered, and the version is now declared |
| 2.1 | data and results in **two** buckets | **one** bucket at two prefixes, which makes the write confinement load-bearing |
| 2.1 | **three** tables | **five** — two are Glue `VIRTUAL_VIEW`s needing `glue:GetTable` on their own ARNs |
| 7 | the eval would not grade AWS answers | it now grades **9/10**, and the answers carry AWS figures |

Four of the five are the same rule paying out: **a constant that names something in another
system is resolved against that system, not written from memory.** The fifth (the eval) is
a scope boundary that moved for an unrelated reason.

**Goal.** The agent answers questions about real launch-provider data held in an existing
AWS lakehouse (S3 + Glue, queried through Athena), alongside the synthetic Fabric lakehouse
it already queries — with **no data copied into Azure and no stored AWS credentials**.

---

## 1. What this is, and what it is not

**It is a live link.** Athena queries the data where it sits in S3. Only the result rows of
each query cross the cloud boundary. There is no replication, no sync job, no second copy
to keep current, and therefore no "which copy is authoritative" section in the outbrief.

**It is not a OneLake shortcut.** Fabric can shortcut to S3, and that is also a link rather
than a copy, and it would need no new tool at all. It was rejected for one reason:
**Fabric's S3 shortcuts authenticate with a stored access key.** The whole point of the
chosen design is that this estate holds no AWS credential, and a shortcut would trade that
away to save a day of work. Recorded here so the decision is not silently revisited.

**It is not a migration.** The Fabric lakehouse stays exactly as it is. This adds a second
source, it does not replace the first.

---

## 2. Architecture

Three parts. Only one is new territory; the other two are implementations of seams that
already exist.

```
Copilot / MCP client
        │
        │  query_aws_lakehouse_sql  (Trino dialect, advertised from the backend)
        ▼
mls-mcp-demo-ca ──► Entra token (IMDS, audience = the AWS-facing app id)
  (Azure)           │
                    ▼
              AWS STS AssumeRoleWithWebIdentity
                    │  short-lived credentials, per call
                    ▼
              Athena ──► Glue catalog ──► S3 (data stays here)
```

### 2.1 The trust anchor (AWS — sponsor-run scripts)

An IAM OIDC identity provider trusting the Entra tenant's issuer, and a role —
`mls-athena-reader` — whose trust policy conditions on **both** `aud` and `sub`.

**The audience is not a bare `api://name` URI.** That was the original shape
(`api://${prefix}-aws-athena-${env}`) and this tenant's default app-registration
policy rejects it: an `identifierUris` value must embed a verified domain, the
tenant id, or the app id. A verified domain doesn't exist here and an app id is
reassigned every time the registration is recreated, which would silently break
the AWS trust policy's `aud` condition on the next rebuild for a reason that
looks like an AWS problem and is not — the same durability argument as §2.2's
managed-identity blast radius, one layer up the chain. So the live audience
embeds the **tenant id** instead: `api://<tenant-id>/mls-aws-athena-demo`. The
tenant id is stable across every teardown and rebuild this estate performs, so
the value the AWS-side scripts consume does not move underneath them.

**Amended in Task 3's fix round 1, on three counts this section got wrong.**

*The token version is declared, and there are TWO providers.* Which issuer the
token carries is decided by the app registration's
`api.requestedAccessTokenVersion`, and the manifest declared none — so the whole
trust chain rested on Entra's null default, which means version 1 and issuer
`https://sts.windows.net/<tenant-id>/`. `infra/entra/manifest.json` now declares
`1` explicitly and the deploy path applies it. The sponsor scripts register both
that provider and the v2.0 one, with one self-contained trust statement each, so
a later change to version 2 needs no AWS-side edit.

*The role is not `mls-athena-reader`.* The sponsor's AWS identity may only manage
roles matching `launch-intel-*` (`IamManageProjectRoles` in that account's
`BOOTSTRAP.md`), so the role name is a required variable and the runbook
recommends `launch-intel-athena-reader`.

*Data and results share one bucket.* The table below assumed two. They are one
bucket at different prefixes, which makes the write confinement load-bearing
rather than incidental: `PutObject` is granted on `<bucket>/athena-results/*`
alone, never bucket-wide, or this role could overwrite the source data it reads.

Permissions are scoped to the minimum that answers a question — as shipped,
which is wider than this table first claimed, because a Hive-partitioned Athena
query needs more than the obvious six actions:

| Service | Allowed | Scope |
|---|---|---|
| Athena | `StartQueryExecution`, `GetQueryExecution`, `GetQueryResults`, `StopQueryExecution`, `GetWorkGroup` | one workgroup |
| Athena | `GetDataCatalog` | `AwsDataCatalog` only |
| Glue | `GetDatabase(s)`, `GetTable(s)`, `GetPartition(s)`, `BatchGetPartition` | one database, **five** named tables — see below |
| S3 | `GetBucketLocation` | the bucket |
| S3 | `ListBucket` (conditioned on `s3:prefix`) | the three data prefixes and the results prefix |
| S3 | `GetObject` | the three data prefixes, read only |
| S3 | `GetObject`, `PutObject`, `ListMultipartUploadParts`, `AbortMultipartUpload` | the Athena results prefix only |

The results prefix is the single place this role may write, because Athena cannot return a
result without staging it. Nothing else in the account is reachable.

*Three tables became five, and that one is worth the most.* The catalog holds
`launches`, `agencies` and `schedule_events` **plus two `VIRTUAL_VIEW`s**,
`launches_latest` and `agencies_latest`. A Glue view is a catalog object in its own right
and needs `glue:GetTable` on **its own ARN**; the base table's grant does not reach it. A
role built from the three names every document in this plan carried would have answered
every base-table question perfectly and `AccessDenied`-ed the views — a *partial* failure
that reads like a data problem rather than a policy one, which is the expensive kind to
diagnose live. It was caught by enumerating the live catalog instead of trusting the
written list. The S3 prefixes stay at three on purpose: a view holds no objects of its own.

**The issuer and audience values are resolved against the live tenant, never written from
memory.** CLAUDE.md's rule about constants that name something in another system applies
with full force here: an OIDC trust policy that is one character wrong fails as
`AccessDenied` with no indication of which field was rejected. The setup script prints both
resolved values and the role ARN, and re-reads them back before declaring success.

### 2.2 The blast-radius problem, which is F172 in a new cloud

**A trust policy pinned to a managed identity's object id would work perfectly and survive
nothing.** Managed identity principal ids are destroyed and reissued on every teardown —
the 2026-09-03 rebuild moved `data-api`'s client id from `3dadafd7` to `ba91c8ea`. An AWS
role pinned to one would break on the next rebuild with a permission error that looks like
an AWS problem and is not.

So the AWS-facing identity is a **user-assigned managed identity in a fifth resource group,
outside the four the teardown deletes by name** — the same move that closed BLOCKER-E for
the Fabric capacity, for the same reason, and its group is derived from `naming.bicep` so a
rebrand cannot move it back inside the blast radius. A test asserts the group is never one
of the four.

This estate is scheduled for shutdown, so the property will not in fact be exercised by a
rebuild. It is built anyway: the outbrief claims reproducibility, and a claim that happens
to be untestable this month is still a claim.

### 2.3 The backend (Azure)

`AthenaLakehouseBackend implements LakehouseSqlBackend` — the interface in
[`backends.ts`](../../../apps/mcp-tools/src/tools/backends.ts), which already has two
implementations and an explicit contract that a backend returns **byte-identical response
shapes** to its counterparts. `tests/shape-parity.test.ts` enforces that from one shared
shape function, so the third implementation is pinned by a test that already exists.

`query(sql)` returns the existing `LakehouseQueryResult` — `{columns, rows, rowCount,
truncated}` — capped at `MAX_RESULT_ROWS`.

Token acquisition reuses the injectable `options.tokens` provider the Fabric backend
already takes, so the AWS exchange hangs off a seam rather than introducing one.

### 2.4 The dialect

`SqlDialect` gains `"trino"`, and `DIALECTS.trino` carries the idiom paragraph that
[`sql-dialect.ts`](../../../apps/mcp-tools/src/tools/sql-dialect.ts) splices into the
agent-facing tool description. That module's existing reasoning applies unchanged: the
dialect is a property of the active backend and the description is generated from it,
because a translation layer would make the agent's errors unattributable and its results
unauditable.

Trino differs from both existing dialects where the golden questions actually touch:
`day_of_week(d)`, `date_format(d, '%Y-%m')`, `LIMIT n`. Advertising T-SQL idioms to an
Athena backend would reproduce, exactly, the latent break that module was written to fix.

**Two tools, not one tool with a `source` parameter.** Sponsor-decided. A single tool would
carry one description that is wrong for half its inputs; two tools each describe the engine
their query will actually hit.

### 2.5 The read-only gate, with one Athena-specific addition

`FORBIDDEN_BY_DIALECT` gains a `trino` entry. Beyond the common verbs it must include
**`unload`** — Athena's `UNLOAD` writes query results to S3 and is the one write path that
does not look like a write. `call`, `prepare`, `execute`, `deallocate`, `set`, `reset` and
`use` follow the T-SQL entry's reasoning about session and batch control.

**`scrubSql`'s comment nesting stays scoped to T-SQL.** Trino block comments do not nest,
so Trino behaves like SQLite here and the existing `dialect === "tsql"` condition is already
correct for it. Stated explicitly because the tempting "stricter" reading — track depth
unconditionally — is the bug that module's comment block documents at length, and a third
dialect is exactly when someone would reintroduce it.

---

## 3. Configuration — one source

Role ARN, AWS region, Glue database, Athena workgroup and results URI live as `demo` GitHub
environment variables, surfaced to the container through the deploy template.

These are stable AWS identifiers, so an environment variable is the right home — unlike the
control tower's origin, which was a GitHub variable holding a value the template should have
derived (F129). Nothing here regenerates on rebuild.

**No value is hand-set on a running app.** A change is finished when a rebuild reproduces
it (F159), and an Easy Auth audience hand-patched onto three running apps is the reason
that rule exists.

---

## 4. Verification

### 4.0 Adding a tool breaks an existing criterion, and that is F145's shape

**V8.3 asserts that no tool is invoked outside the tool allowlist and that the agent
declares exactly the expected set.** Registering `query_aws_lakehouse_sql` widens that set,
so V8.3 fails on a correct implementation until its expectation is updated — and a
criterion that fails for a reason unrelated to what it measures is worse than one that is
simply absent.

This is precisely F145: V8.1's expected component set was built from one of three files
that declare components, and widening it to fix one criterion silently changed the meaning
of V8.3, which filtered the same list. One broken criterion traded for another, with
nothing about V8.3 edited to show for it.

**So the first implementation task is to enumerate every reader of the tool list before
widening it** — `layer-07-audit.ps1`, `layer-08-audit.ps1` and the `verification/tests/`
suites all reference allowlists, and which of those read *this* list is a question to answer
by reading, not by assuming. Widen the list only after the readers are known, and add a test
that fails if a future tool is registered without the expectation moving with it.

### 4.1 The two new criteria

Both written against defects this repository has already paid for.

**They belong to L8, not L5.** L5's criteria are explicitly Fabric — *"Fabric REST: workspace
+ lakehouse exist"*, *"Capacity state == Paused"* — and an AWS criterion there would make the
layer's name a lie. L8 owns the agent's tool surface, which is what is actually being
verified. **V8.6** and **V8.7** are the next free numbers; V8.1–V8.5 are taken.

**V8.6 — the AWS lakehouse returns rows, not a status code.** V7.6's rule. A criterion that
proves plumbing without proving water is how an empty estate signed off 5/5 for two days.
This asserts a row count greater than zero from a known table, and records the observation
in the report: `authenticated Athena query -> N rows, M ms`.

**V8.7 — a denial is never reported as an empty dataset.** Athena against a Glue database
the role cannot read can answer emptily rather than 403 — F105's exact shape, where Fabric
answered `/tables` with `[]` to a caller without OneLake read and the audit called the
lakehouse empty while its SQL endpoint returned 1,200 rows. The criterion establishes that
it *could* observe before reporting what it saw, and fails **UNOBSERVABLE** when it could
not. It must be structurally incapable of reporting the link as absent, and equally
incapable of reporting it as present, when it cannot see.

**Both criteria declare their own timeout.** Athena is asynchronous — submit, poll,
retrieve — so the wait is real and must be stated with the number and what it waits on.
Nineteen of forty-seven criteria once inherited a 30-minute window nobody chose for them.
As built: V8.6 waits **4 minutes** (Container Apps scale-from-zero plus Athena's async
cycle), V8.7 **2 minutes** (catalog metadata, on a container V8.6 has already woken).

**Built and passed once — 2026-09-17T00:38Z, run `35166952968`.** Both PASS. Two things
about that verdict are load-bearing and easy to lose:

- **The criteria were unfed for a day.** They need a credential for the MCP endpoint
  (`mcp-auth-token`), which neither `mls-verifier` nor `admin@` could read — verified
  Forbidden, not assumed — so V8.6 reported SKIP and never a pass. A sponsor-approved grant
  of **Key Vault Secrets User scoped to that one secret** closed it. **That grant exists in
  Bicep and has never deployed**; the live assignment is hand-applied, so a teardown returns
  both criteria to SKIP. A criterion that stops asserting is indistinguishable from one that
  never did.
- **V8.6's floors are 100,000 and 1,000, against observed 286,473 and 7,969.** Deliberately
  loose, because the lakehouse is the sponsor's and refreshes from an upstream feed, so a
  pinned equality fails on correct data. The cost of that choice, stated plainly: **V8.6
  would not catch a lakehouse that lost 60 % of its rows.** It catches *nothing*, a status
  code, a denial, and a view the role cannot read — which is what it was written for. Exact
  counts belong to V5.3, over a dataset this repo seeds.

**A repo sweep asserts no AWS key material exists** anywhere in the repository, the CI
secret list or Key Vault. The claim is zero stored credentials; something must be able to
fail if that stops being true. This extends
`verification/tests/failure-classes.Tests.ps1`, where a class paid for once becomes a check.

---

## 5. Testing

- **Shape parity** extended to the third backend, from the existing shared shape function.
- **Mocked-Athena unit suite** covering the submit/poll/retrieve cycle, including a query
  that fails server-side and one that is still running when the timeout expires.
- **Read-only gate**: negative tests per forbidden verb, `UNLOAD` named explicitly, and a
  stacked-statement case.
- **Scrubber**: a Trino block-comment case asserting non-nesting behaviour matches SQLite.
- **Blast radius**: the AWS-facing identity's resource group is never one of the four,
  derived from `naming.bicep`.
- No `Set-StrictMode -Off` in any `*.Tests.ps1`, and no fixture that supplies the answer it
  is checking.

**The probe is made with the client that will make it.** F158 cost this project a security
scan that passed against a login page because the detector was validated with PowerShell and
CI runs `curl`. The Athena path is exercised from the container's own runtime, not from a
workstation with different credentials in the environment.

---

## 6. Gates

- **G2 (spend):** Athena bills per terabyte scanned and S3 bills for the results prefix.
  Real but small at demo volumes. Queries are capped at `MAX_RESULT_ROWS` and the workgroup
  should carry a per-query data-scanned limit. **The AWS account is the sponsor's and the
  spend is theirs**; no Azure spend profile changes, so G2 is not triggered on this side.
- **G3 (deletion):** deleting the IAM OIDC provider or the role is tenant-level in AWS's
  sense — it cannot be recreated by the Azure deploy path. The teardown script is
  sponsor-run and refuses to run unattended, matching the three existing tenant-level
  teardowns.
- **AWS writes are performed by the sponsor**, running scripts authored here. The hard rule
  that agents execute the Azure estate was amended 2026-08-29 for Azure, Entra, Fabric and
  GitHub; it says nothing about a second cloud, and this design does not assume it extends.

---

## 7. Out of scope

- Writing to AWS. The role reads; the only write is Athena's own results staging.
- Replacing or migrating the Fabric lakehouse.
- Cost attribution for AWS spend in the control tower's FinOps tab. **Still out of scope.**
- Making the L8 agent eval grade AWS answers. The eval's own interpretability is F184 and
  is tracked separately; adding a second data source does not depend on it and must not
  wait for it.

  **This boundary moved underneath us, and in the good direction.** On 2026-09-17T00:37Z the
  eval scored **9/10 with `unobservable: 0`** — it grades now — and its answers carry AWS
  figures, because the agent volunteers both lakehouses for an ambiguous question. Its
  *golden expectations remain Fabric-only*, so **no eval question asserts an AWS number**
  and this item is still out of scope as written. What changed is that the artifact now
  contains AWS evidence a reader could mistake for a graded assertion. It is not one; V8.6
  is.

---

## 8. Open risks

| Risk | Mitigation | Outcome |
|---|---|---|
| OIDC trust policy fails with an opaque `AccessDenied` | Setup script resolves and prints issuer, audience and ARN, and re-reads them back. Expect two attempts; budget for it. | **Did not materialise.** The trust policy was right first time because all three of its values were read from live systems. The `AccessDenied` that *did* appear was the honest one — no role existed yet — and it was diagnostic, not opaque: an STS refusal is unreachable without presenting a web identity token, so it proved the Azure half worked |
| Athena latency exceeds the agent's patience | Declared timeout per criterion; workgroup data-scanned cap keeps queries small. | **Partly materialised, one level up.** Athena itself was fine (4,431 ms for 286,473 rows). What is over budget is the *agent's* p95 — 34.18 s observed against V8.5's 20 s, driven by a cold start on the first question and by disambiguation querying both lakehouses |
| The Glue schema is unknown to the tool description | The tool advertises the dialect, not the schema; a schema-listing call resolves tables at runtime rather than pinning names written from memory. | **Held, and paid for itself twice.** Runtime enumeration is what found the two views, and it is what let the agent list all five tables live during the demo. Separately the dialect's promise was made true rather than decorative: the session probe `SELECT day_of_week(DATE '2026-08-22')` met a real engine and returned **6**. Had it returned 7 — Fabric's numbering, the most plausible wrong answer — the tool would have refused |
| Sponsor round-trip on AWS scripts consumes the window | AWS scripts are authored and handed over **first**, before the Azure backend, so the round-trip overlaps with Azure-side work instead of following it. | **Worked as designed, and the round trip was still the long pole.** Two agents were authorised to create the role and both were blocked by the harness permission classifier; neither routed around it. The sponsor ran it, and the entire Azure side was already waiting and correct |

**Deferred, and still open at hand-back:**

- **The Key Vault grant has never deployed.** In Bicep, live only by hand. First `layer-07-apps`
  run after 2026-09-17T00:51Z fixes it; until then a teardown costs two criteria.
- **`mls-rg-identity` and the AWS IAM role survive the teardown by design**, and so do both
  OIDC providers — those two because `01-oidc-provider.sh` recorded them as pre-existing and
  `teardown.sh` refuses to delete what it did not create. Four objects needing four deliberate
  decisions at shutdown, not one.
- **No AWS cost telemetry anywhere.** Athena bills per terabyte scanned against the sponsor's
  account and nothing in this estate observes it. Out of scope by §7 and worth naming as a gap
  rather than a silence.

# `data/seed/` — the data-plane seeding layer (L5 + L6)

One entry point, two planes, ten tables, exact row counts.

```
pwsh data/seed/seed.ps1 -Target both -WhatIf
```

| | |
|---|---|
| **Layers** | L5 (Fabric lakehouse, analytical plane) and L6 (Azure SQL, operational plane) |
| **Generator seed** | `20260822` — deterministic, so every downstream expectation is exact |
| **Row counts** | `launches` 1200 · `scrubs` 475 · `vehicles` 12 · `pads` 11 · `telemetry_summary` 1200 · `parts` 300 · `suppliers` 24 · `work_orders` 800 · `cost_daily` 4515 · `findings_history` 420 |

## Layout

```
data/seed/
  seed.ps1              ONE entry point: generate -> SQL -> lakehouse
  schema-manifest.json  the contract: tables, ordered columns, types, keys, row counts
  seed-common.psm1      manifest reader, generated-data reader, status output
  sql/                  T-SQL DDL (12 files) + sql-seed.psm1        -> README.md
  lakehouse/            Fabric REST loader (lakehouse-seed.psm1)    -> README.md
  tests/                Pester 5-syntax suites; every cloud call mocked
```

`seed.ps1` is the only thing meant to be invoked. The two `.psm1` loaders are libraries;
they are modules rather than scripts so that a glob over `data/seed/*.ps1` finds exactly
one entry point.

## What a run does

1. **Generate** — `python -m generators build` from `data/`, but only when
   `data/generated/` is missing or incomplete (any of the twenty files: 10 tables ×
   CSV + JSON). The seed, not the artifacts, is the source of truth; `data/generated/`
   is gitignored and disposable.
2. **Azure SQL** (`-Target sql|both`) — apply `sql/*.sql` in filename order, then load
   the ten tables and verify every count.
3. **Lakehouse** (`-Target lakehouse|both`) — upload the ten CSVs to OneLake and load
   them as Delta tables over the Fabric REST API.

`data/generators/` is Track A's and is never modified from here.

## The two planes

The master plan makes Azure SQL the per-app **operational** database and the lakehouse
the **analytical** plane. Both are seeded from the same generator output, so a demo
question answered from either plane gives the same number.

- **Azure SQL** loads from the generated **JSON**. That is a fidelity decision: JSON has
  native `null`, native `true`/`false`, and unambiguous whitespace, so a null never
  arrives as an empty string, a boolean never arrives as the text `"True"`, and the
  deliberately dirty values (`"  Aurora Sat Networks"`, `"Inconel 718 "`) are never
  trimmed on the way in.
- **The lakehouse** loads from the generated **CSV**, because the Fabric Load Table API
  accepts `Csv` or `Parquet` and the generators emit no Parquet.

Per-table plane assignments (`operational` / `reference` / `analytical-mirror`) are in
[`sql/README.md`](sql/README.md) and machine-readable in `schema-manifest.json`.

## How generator-schema parity is guaranteed

Three independent descriptions of the same ten tables have to agree, and nothing at
runtime would tell us if they stopped:

```
data/generators/build.py + pools.py   ──┐
                                        ├──► asserted equal, both directions
data/seed/schema-manifest.json        ──┤    (tests/schema-parity.Tests.ps1)
                                        │
data/seed/sql/*.sql                   ──┘
```

`tests/schema-parity.Tests.ps1` parses all three and compares them: 67 assertions
covering column names, **column order**, SQL types, nullability, primary keys, foreign
keys, FK-safe file and load ordering, plane assignment, and the ten row counts against
the Verifier's own numbers. It also asserts that its parsers extracted something — a
parity test that silently extracts nothing would pass forever.

The generator side is read from the `rows.append({...})` literal in each `gen_*`
function, not from the whole function body: a function region also contains module-level
dicts and comparisons like `if status == "closed":`, both of which look exactly like
dict keys to a naive scan.

## Row-count fidelity

Row counts are contract (L5 V5.3: `launches` = 1,200 ± 0), so every stage is built not to
lose or duplicate a row:

- Nothing de-duplicates. No `MERGE`, no `SELECT DISTINCT`, no `IGNORE_DUP_KEY`, no
  `Append` mode.
- A reload **wipes first** (`DELETE` in reverse dependency order) rather than appending,
  so a second run cannot double a table. No constraint is ever disabled to make the wipe
  easier.
- `UQ_telemetry_summary_launch_id` and `UQ_cost_daily_date_cost_center` are anti-duplicate
  tripwires: a double-append fails loudly instead of inflating a count.
- Every SQL table's count is **read back** after loading and compared to the manifest; a
  mismatch throws. The lakehouse table list is read back and compared the same way.
- Type conversion never drops a row silently: a non-ISO date throws, and an over-long
  string is a server-side error, not a truncation.

## Idempotency and `-WhatIf`

- **Second run no-ops.** The SQL *load* short-circuits when every table already holds
  exactly its expected count; the lakehouse short-circuits when every Delta table already
  exists. All DDL (`sql/*.sql`) is guarded (`IF NOT EXISTS` / `sys.database_principals`)
  and is **always** re-applied, regardless of the load short-circuit — a DDL-only fix
  (a grant, an index, a new guarded statement) must land on a replay against an
  already-seeded estate, not only on a first run.
- **`-SchemaOnly`** (`-Target sql` only; [F20](../../compliance/findings/2026-08-26-prepublication-review.md#f20))
  applies the DDL and stops — no row-count read, no table load, and no requirement that
  `data/generated/` exists. This is the post-L7 invocation that re-applies
  `sql/900-contained-users.sql` once the data-api identity exists: a grant is DDL, not
  data, so it needs none of the dataset machinery a reseed does.
- **`-Force`** wipes and reloads both planes — the L5 playbook's wipe-and-reseed
  remediation.
- **`-WhatIf`** makes no mutating call anywhere: no generator subprocess, no `INSERT`, no
  OneLake upload, no table load. Prerequisites are still checked, because they are local.
  The SQL half issues *no database call at all* under `-WhatIf`, not even a count — the
  alternative would fail on a database whose DDL has not been applied yet, which is
  exactly the state a dry run is most useful in.

## Failing fast

Every prerequisite is checked before the first write, and each failure names the thing to
fix — a half-seeded database or a lakehouse with four of ten tables is far more expensive
than a run that refuses to start:

| Missing | Message names |
|---|---|
| `python` | install Python 3.14, or `-PythonExecutable`, or stage the data and use `-SkipGenerate` |
| generated dataset | `python -m generators build` from `data/` |
| SqlServer module | `Install-Module SqlServer -MinimumVersion 22.0.0` (22+ for `-AccessToken`) |
| `-SqlServerInstance` / `-SqlDatabase` | the parameter, and `-Target lakehouse` as the way to skip this half |
| `-Token` | `az account get-access-token --resource https://api.fabric.microsoft.com` |
| `-OneLakeToken` | that OneLake is a **storage** audience, with the `https://storage.azure.com` line to run |
| workspace / lakehouse absent | `infra/fabric/provision-workspace.ps1` owns creating them |
| generator ran but data still incomplete | refuses to seed from a partial dataset |

## Tests

```
pwsh -NoProfile -Command "Invoke-Pester -Path data/seed/tests"
```

171 assertions, **zero live calls**. Azure SQL goes through one choke point
(`Invoke-SeedSqlCommand`), Fabric through two (`Invoke-FabricApi`,
`Invoke-SeedWebRequest`), and the generator subprocess through one
(`Invoke-GeneratorProcess`); all are mocked. `data/generated/` is never read — rows are
in-memory fixtures — and nothing is written outside Pester's `TestDrive`.

The only real filesystem reads are of repo-tracked sources (the manifest, the DDL, the
generator `.py` files) in the parity suite, where reading them **is** the thing under
test.

## Related

- [`sql/README.md`](sql/README.md) — DDL ordering, plane split, type rules, idempotency
- [`lakehouse/README.md`](lakehouse/README.md) — the REST load mechanism, sources,
  rejected alternatives, and the column-type open item
- `docs/runbooks/layers/L05.md` · `L06.md` — the playbooks this implements
- `infra/fabric/teardown-items.ps1` — the other half of the kill/rebuild cycle

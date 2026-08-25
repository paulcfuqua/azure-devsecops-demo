# `data/seed/sql/` — Azure SQL operational schema (L6)

T-SQL DDL for the Azure SQL **serverless** database the master plan makes the per-app
operational store (`mls-ops-demo-sql`, auto-pause 60 min / min 0.5 vCore — L6 playbook
V6.1). The lakehouse `mls_operations` is the analytical plane; see
[`../lakehouse/README.md`](../lakehouse/README.md).

Applied by [`../seed.ps1`](../seed.ps1) `-Target sql`. Nothing here talks to Fabric.

## Ordering — apply in filename order, one pass

Filenames are zero-padded so plain lexicographic sort *is* the dependency order. Run
them in that order and the whole schema applies in a single pass with no forward
references:

| # | File | Table | Plane | Depends on |
|---|---|---|---|---|
| 000 | `000_schema_version.sql` | `schema_version` | meta | — |
| 010 | `010_vehicles.sql` | `vehicles` | reference | — |
| 020 | `020_pads.sql` | `pads` | reference | — |
| 030 | `030_suppliers.sql` | `suppliers` | reference | — |
| 040 | `040_parts.sql` | `parts` | reference | 030 |
| 050 | `050_launches.sql` | `launches` | **operational** | 010, 020 |
| 060 | `060_scrubs.sql` | `scrubs` | **operational** | 050 |
| 070 | `070_telemetry_summary.sql` | `telemetry_summary` | analytical mirror | 050 |
| 080 | `080_work_orders.sql` | `work_orders` | **operational** | 010, 040, 050 |
| 090 | `090_cost_daily.sql` | `cost_daily` | analytical mirror | — |
| 100 | `100_findings_history.sql` | `findings_history` | analytical mirror | — |
| 110 | `110_indexes.sql` | (all) | — | every table |

Data load order is the same minus the meta and index files — it is `load_order` in
[`../schema-manifest.json`](../schema-manifest.json), and `seed.ps1` reads it from there
rather than re-deriving it.

## Operational vs analytical

The master plan puts the operational database in Azure SQL, per app, and the analytical
plane in the lakehouse. That split is real here, not decorative:

- **operational** — `launches`, `scrubs`, `work_orders`. Azure SQL is the system of
  record. `apps/launch-ops` (L7) does CRUD against these; the seed only provides the
  starting state.
- **reference** — `vehicles`, `pads`, `suppliers`, `parts`. Seeded once, read-mostly,
  and the FK targets for everything above. An app may read them; nothing writes them
  outside a reseed.
- **analytical mirror** — `telemetry_summary`, `cost_daily`, `findings_history`. The
  **lakehouse** is the system of record (L6: the Cost Management export → Function
  pipeline writes `cost_daily` into `mls_operations`). The Azure SQL copies exist so L7
  app views can join without crossing planes. They are refreshed by re-seeding, never by
  app writes — if you find app code writing one of these, the plane split has been
  violated.

Nothing enforces the split at the database level (no `DENY`, no separate schema): it is
a design contract, stated here and in the header comment of every file, and the `plane`
field in `schema-manifest.json` is the machine-readable copy.

## Idempotency

Every statement is guarded (`IF NOT EXISTS (SELECT 1 FROM sys.tables …)` /
`sys.indexes`), so re-running the whole directory on a rebuilt database is a no-op. All
table constraints — PK, FK, UNIQUE, CHECK — are declared **inline in `CREATE TABLE`**
rather than as follow-up `ALTER TABLE` statements. That is deliberate: it keeps each
table's definition in one guarded block, so "table exists" and "table is fully
constrained" can never disagree, and there is no batch in which an `ALTER` could
reference a table its own file just created.

`dbo.schema_version` records `(script_name, schema_version, generator_seed, applied_utc)`
and every file stamps itself into it. `SELECT * FROM dbo.schema_version ORDER BY
applied_utc` is the audit trail for what a given database actually has.

## Batch separation

Batches are separated by a line containing only `GO`. `GO` is a client-side batch
separator, not T-SQL, so `seed.ps1` splits on it itself (`Split-SqlBatch`) and submits
each batch separately — the files therefore work with `Invoke-Sqlcmd`, with `sqlcmd`,
and with a raw client, and do not depend on any one of them.

## Type rules

Column names and their order match `data/generators/writers.py` output exactly (dict
insertion order == CSV header order == JSON key order). Types follow one rule set:

| Generator value | Azure SQL type | Why |
|---|---|---|
| real number, non-currency | `FLOAT` | IEEE double — round-trips a Python float exactly, cannot overflow |
| currency | `DECIMAL(18,2)` | exact for `round(x, 2)`; no binary-fraction drift on sums |
| counter / year | `INT` | |
| ISO `YYYY-MM-DD` | `DATE` | |
| `True`/`False` | `BIT` | the loader reads the **JSON** output, where these are native booleans |
| string | `NVARCHAR(n)`, n ≈ 2–4× widest seeded value | headroom without `MAX` |

`NOT NULL` is asserted wherever the generator never emits a null. Only the five
`NULLABLE_COLUMNS` (`launches.weather_delay_min`, `launches.insurance_value_musd`,
`scrubs.recycle_hours`, `telemetry_summary.data_dropout_s`, `parts.material`) plus the
four structurally-optional columns (`vehicles.gto_capacity_kg`,
`vehicles.last_flight_year`, `work_orders.launch_id`, `work_orders.closed_date`,
`work_orders.disposition`, `findings_history.cve_id`, `findings_history.closed_date`)
are nullable. `apps/launch-ops` types several of these defensively as `| null` in
TypeScript; that is caller-side caution, not a schema relaxation.

## Messiness is preserved, on purpose

`launches.customer`, `parts.material` and `work_orders.technician` carry deliberate
casing/whitespace damage (`DIRTY_RATE` 0.06). There is no `TRIM`, no computed
normalising column and no `CHECK` on any of them — the mess is the demo material for
the data-quality story. Anything that "cleans" these on load is a regression.

## Row counts

Post-seed counts at generator seed `20260822`, asserted by `seed.ps1` after every load
and re-derived independently by `verification/layer-05-audit.ps1`:

| table | rows | | table | rows |
|---|---:|---|---|---:|
| `launches` | 1200 | | `parts` | 300 |
| `scrubs` | 475 | | `suppliers` | 24 |
| `vehicles` | 12 | | `work_orders` | 800 |
| `pads` | 11 | | `cost_daily` | 4515 |
| `telemetry_summary` | 1200 | | `findings_history` | 420 |

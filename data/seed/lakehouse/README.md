# `data/seed/lakehouse/` — Fabric lakehouse load (L5)

Creates and loads the ten Delta tables in lakehouse `mls_operations` (workspace
`mls-operations`) over the Fabric REST API, as a **service principal**, with **no portal
step**. Driven by [`../seed.ps1`](../seed.ps1) `-Target lakehouse`.

The workspace and the lakehouse must already exist —
`infra/fabric/provision-workspace.ps1` owns creating them, and this loader refuses
rather than quietly creating a second one under a name nobody expects.

## The mechanism, and why this one

Two calls per table.

**1 — stage the CSV in OneLake** (ADLS Gen2 / DFS API):

```
PUT   https://onelake.dfs.fabric.microsoft.com/{workspaceId}/{lakehouseId}/Files/seed/{table}/{table}.csv?resource=file
PATCH https://onelake.dfs.fabric.microsoft.com/{workspaceId}/{lakehouseId}/Files/seed/{table}/{table}.csv?action=append&position=0&flush=true
```

**2 — load it as a Delta table**:

```
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/lakehouses/{lakehouseId}/tables/{tableName}/load
{
  "relativePath":  "Files/seed/{table}/{table}.csv",
  "pathType":      "File",
  "mode":          "Overwrite",
  "recursive":     false,
  "formatOptions": { "format": "Csv", "header": true, "delimiter": "," }
}
```

→ `202 Accepted` with `Location`, `x-ms-operation-id` and `Retry-After`; the loader polls
the `Location` URL verbatim until the operation reports success.

**There is no separate "create table" step.** No Fabric REST operation writes a Delta
table directly; Load Table in `Overwrite` mode creates the table when it is absent, so
creation and load are the same call.

### Sources

| Claim | Source |
|---|---|
| Load Table operation, request body (`pathType`, `relativePath`, `mode`, `recursive`, `formatOptions`), 202 + `Location`/`x-ms-operation-id`/`Retry-After`, `tableName` pattern `^(?=[0-9]*[a-zA-Z_])[a-zA-Z0-9_]{1,256}$`, **service principal supported**, **Preview** | <https://learn.microsoft.com/en-us/rest/api/fabric/lakehouse/tables/load-table> |
| OneLake DFS endpoint and both path forms (`{workspace}/{item}.{itemtype}/…` and `{workspaceGUID}/{itemGUID}/…`) | <https://learn.microsoft.com/en-us/fabric/onelake/onelake-access-api> |
| `PUT ?resource=file` creates the file (a body is rejected with `ContentLengthMustBeZero`, so it is necessarily empty) | <https://learn.microsoft.com/en-us/rest/api/storageservices/datalakestoragegen2/path/create> |
| `flush=true` on an append — "if 'true' the data will be flushed with the append call" | <https://learn.microsoft.com/en-us/rest/api/storageservices/datalakestoragegen2/path/update> |
| Fabric long-running-operation polling contract | <https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation> |
| OneLake token audience — "Use the OneLake resource scope `https://storage.azure.com/.default` when requesting the token" | <https://learn.microsoft.com/en-us/fabric/onelake/security/onelake-security-integrations-external-engines> |

### Two tokens, two audiences

The detail that breaks a first attempt:

| Plane | Audience | `seed.ps1` parameter |
|---|---|---|
| Fabric control plane (Load Table, item CRUD, LRO polling) | `https://api.fabric.microsoft.com/.default` | `-Token` |
| OneLake data plane (the CSV upload) | `https://storage.azure.com/.default` | `-OneLakeToken` |

Sending the Fabric token to OneLake returns a bare `401` with a bearer challenge rather
than anything diagnostic, so `Assert-LakehouseSeedPrerequisite` checks for both tokens
before the first upload and names the `az account get-access-token` line to run.

The GUID path form is used (`{workspaceId}/{lakehouseId}/…`) rather than
`{workspace}/{lakehouse}.Lakehouse/…`: it needs no name escaping and no item-type
suffix, so a workspace rename cannot break a running seed. Note the docs are explicit
that the two forms cannot be mixed — GUIDs for both segments or names for both.

### Alternatives considered, and why not

| Option | Verdict |
|---|---|
| **Livy API** (`…/lakehouses/{id}/livyapi/…`) | Rejected. Real Spark sessions for 4,515 rows is heavy, and it needs a tenant-admin toggle this layer cannot set — L5 must stay deliverable on the trial capacity without a human in the portal. |
| **Notebook + on-demand job** (create a notebook item with an inline base64 definition, then `POST /items/{id}/jobs/instances?jobType=RunNotebook`) | Rejected as the default, kept as the documented escape hatch — see *Column types* below. Fully SP-scriptable, but it means shipping and versioning Spark source, a second item in the workspace that teardown must then remove, and a much larger failure surface than two HTTP calls. |
| **OneLake shortcuts** | Rejected. A shortcut points at data that already lives somewhere else; there is no other copy of this dataset in the cloud, so it solves nothing here. |
| **A "create/upload Delta table" REST API** | Does not exist. Load Table is the only REST path from a file to a Delta table. |

## Row-count fidelity

`launches` must be **1,200 ± 0** at L5 V5.3, and the same exactness applies to the other
nine tables. Four settings carry that, and each one prevents a specific failure:

| Setting | What it prevents |
|---|---|
| `"header": true` | With `header:false` Fabric names the columns `_c0, _c1, …` **and the header row becomes a data row** — every table would come in one row heavy with the wrong column names. |
| `"mode": "Overwrite"` | `Append` has no merge or de-duplicate semantics. A second run would double every table. Overwrite makes the load exactly-once by construction. |
| `"pathType": "File"` + `"recursive": false` | A folder-scoped load concatenates everything in the folder. Each table is staged alone in `Files/seed/{table}/`, and the load names the file. |
| Table list read back after loading | Catches a load that reported success but registered nothing (L5 failure mode 4). |

Nothing in the path de-duplicates, filters or samples. The loader uploads the generator's
bytes unmodified and Fabric parses them.

## Column types — the one open item

**The Load Table API cannot be given a schema.** Its body has no schema element, and a
CSV source without one is not guaranteed to arrive typed — the documented behaviour for
schemaless CSV is that columns land as strings. The generators emit CSV and JSON, not
Parquet, and nothing in this repo can produce Parquet without adding a dependency to
`data/generators/`, which is out of scope here.

Consequences, stated plainly:

- **Unaffected:** V5.1 (workspace/lakehouse exist), V5.2 (table list matches manifest),
  V5.3 (`COUNT(*)` per table). None of them depends on a column type. The L5 audit passes
  either way.
- **Affected:** L8. If the columns land as strings, SQL generated against the SQL
  analytics endpoint — `AVG(payload_mass_kg)`, `SUM(amount_usd)`,
  `DATEPART(weekday, actual_date)` — needs a `CAST`. The trial-phase default answer path
  (MCP `query_lakehouse_sql` over the local CSVs) infers its own types and is unaffected;
  the paid-F2 Fabric data agent path is the one to watch.

**This is a handoff, not a silent gap.** Two ways to close it when L8 needs it, in order
of cost:

1. Have the data agent's `aiInstructions` require `CAST` on numeric and date columns.
   No code change; `infra/fabric/create-data-agent.ps1` already owns that text.
2. Switch this loader to the notebook path and read with an explicit
   `spark.read.schema(...)`. `spark_type` is already carried per column in
   [`../schema-manifest.json`](../schema-manifest.json) precisely so that this is a
   mechanical change rather than a re-derivation of the schema.

## Idempotency and `-WhatIf`

- **Second run is a no-op.** If every table in the manifest is already registered in the
  lakehouse, nothing is uploaded and nothing is loaded.
- **`-Force`** re-uploads and re-loads in `Overwrite` mode — exactly-once by
  construction, and the L5 playbook's wipe-and-reseed remediation.
- **`-WhatIf`** issues GETs only: workspace lookup, lakehouse lookup, table list. No
  `PUT`, `PATCH` or `POST` is reachable, asserted end to end in
  [`../tests/lakehouse-seed.Tests.ps1`](../tests/lakehouse-seed.Tests.ps1) by letting the
  real helpers run against transports that throw if touched.

## Preview status

Load Table carries: *"This API is part of a Preview release and is provided for
evaluation and development purposes only."* Accepted with eyes open — it is the only
scriptable path that meets the no-portal constraint. The notebook route above is the
documented fallback for the day that changes.

## Permissions this script cannot bootstrap

- Workspace **Contributor** for the deployer SP.
- Tenant toggle **"Service principals can use Fabric APIs"** (G0 item C4).

Both are asserted by `scripts/bootstrap/verify-g0.ps1`; without them the first REST call
returns 401/403 (L5 failure mode 1).

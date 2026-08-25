# @mls/cost-ingest

The missing leg of the FinOps pipeline: **Cost Management daily export → storage
→ this Function → lakehouse `cost_daily`**.

The master plan specifies that chain at L6, and the control tower's
cost-over-time visual and the MCP `get_cost_series` tool both read the table it
writes. Without this Function the lakehouse only ever holds the generator's
synthetic cost history — the chart works, but nothing behind it is real.

| | |
|---|---|
| **Layer** | L6 (`docs/runbooks/layers/L06.md`, deploy step 3) |
| **Host** | Azure Functions, consumption plan, Node v4 programming model |
| **Trigger** | Blob created in the cost-export container |
| **Auth** | Managed identity only — see [Authentication](#authentication) |
| **Teardown** | Dies with `mls-rg-platform`; gate-free |

## The pipeline in one paragraph

Cost Management writes a `MonthToDate` actual-cost export to blob storage every
day. The blob trigger hands the CSV to `ingestExport()`, which parses it,
normalises every row to the six-column `cost_daily` shape from
`data/generators/README.md`, aggregates the export's per-resource grain up to
one row per `(date, cost_center)`, and **replaces the whole month's partition**
in OneLake. The `cost_daily` Delta table is defined over that folder by the L5
loader, so this Function owns the data and the lakehouse owns the table.

```
costexports/<rg>/<period>/part_0.csv        (Cost Management writes)
        │
        ▼  blob trigger, identity-based connection
   parseCsv ──► normaliseExport ──► groupByMonth ──► replacePartition
        │              │                                    │
   RFC 4180      column aliases,                   OneLake ADLS Gen2 DFS
   BOM, CRLF,    date/amount coercion,             PUT ?resource=file
   ragged rows   tag → cost centre,                PATCH ?action=append
                 grain aggregation                 PATCH ?action=flush
                                                            │
                                                            ▼
        <workspace>/<lakehouse>.Lakehouse/Files/cost_daily/month=YYYY-MM/cost_daily.csv
```

## The `cost_daily` shape

Fixed by `data/generators/README.md § cost_daily`, because the L5 seed populates
the same table:

| column | type | source |
|---|---|---|
| `cost_id` | str | **derived**: `CST-<YYYYMMDD>-<COST-CENTER-SLUG>` |
| `date` | date | usage date, ISO `YYYY-MM-DD` |
| `cost_center` | str | the `costCenter` tag L2's policy enforces |
| `amount_usd` | float | summed for the day and centre, rounded once |
| `budget_usd` | float / null | `COST_CENTER_BUDGETS` app setting |
| `currency` | str | as billed; `USD` for this estate |

**One deliberate divergence from the generator.** The generator mints sequential
ids (`CST-00001`); ingested rows derive theirs from the natural key instead. A
sequence is stateful, and this Function's whole contract is that re-processing
yesterday's export produces exactly the rows it produced yesterday. The two id
spaces cannot collide — a generator id is `CST-` plus five digits and carries one
hyphen; a derived id always carries at least two.

## Idempotency — "a re-exported day updates, it does not duplicate"

This is the requirement that shapes the design, so it is worth being precise
about *why* the obvious approaches fail.

A `MonthToDate` daily export **re-emits the entire month every day**, with
earlier days restated as amortisation and credits settle. So on the 15th of the
month the export contains days 1–15, and on the 16th it contains days 1–16 with
days 1–15 possibly *different*.

* **Appending** would write day 1 fifteen times over.
* **Upserting by `(date, cost_center)`** fixes the duplicates but keeps rows that
  a restatement removed entirely.
* **Replacing the whole month** is the only operation whose semantics match the
  source's own. It is what this Function does.

Three properties make the replace safe to repeat:

1. `cost_id` is a pure function of `(date, cost_center)` — `src/costDaily.ts`.
2. Rows are aggregated and **totally ordered** by `(date, cost_center)`, and the
   CSV writer emits a fixed column order with LF newlines — so re-ingesting an
   unchanged export produces a **byte-identical** file, not merely an equivalent
   one. `tests/ingest.test.ts` asserts exactly that.
3. `PUT …?resource=file` on an existing OneLake path **truncates** it, so the
   replace is a single create — there is no delete-then-write window in which
   the month is missing.

Months not present in the export are never touched.

### The refusal that protects the chart

A header-only export — which Cost Management does occasionally land — yields
zero rows, and `ingestExport()` **skips the write entirely** rather than
replacing a good month with nothing. Without that, a single empty file would
blank the control tower's cost history until the next day's export restored it:
an intermittent, unexplainable gap. `tests/ingest.test.ts` pins the behaviour.

Its counterpart: if **every** row rejects, the Function *throws*. That is not
messy data, it is schema drift (L06 failure mode 5), and a human needs to see a
failed invocation rather than a quiet no-op.

## Real-world messiness this handles

None of the following is hypothetical; each has a test.

| What arrives | What the code does |
|---|---|
| UTF-8 BOM on the first header | stripped before the header is read |
| CRLF / LF / no final newline | all three parse identically |
| `Tags` as `"""costCenter"": ""Propulsion"""` | RFC 4180 doubled-quote unescaping |
| `Tags` unquoted as `{"costCenter":"Propulsion"}` | a quote mid-field is literal, not a delimiter |
| `Tags` as legacy `costCenter:Propulsion;env:demo` | fallback key/value scan |
| **Column set varies by export version** — `UsageDate`+`PreTaxCost` (EA), `date`+`costInBillingCurrency` (MCA), `ChargePeriodStart`+`BilledCost` (FOCUS) | ordered alias table, case/space/underscore-insensitive; first match wins, so a USD column beats a billing-currency one |
| **Amounts as strings**: `"1,234.50"`, `$42.00`, `1.2345E-05`, `(5.25)` for a credit | `parseAmount` handles separators, symbols, scientific notation and accounting negatives |
| A blank or `n/a` amount | rejected — **never** coerced to `0`, which would invent free usage |
| Dates as `2026-08-15`, `08/15/2026` or `20260815` | all normalise to ISO; `2026-02-30` is rejected, not guessed at |
| One row per resource per meter per day | summed up to the `(date, cost_center)` grain |
| A resource with no `costCenter` tag | resource-group map, then `Unallocated` — a cost that vanishes from the dashboard is worse than one filed under a catch-all |
| Ragged rows (column-count mismatch) | dropped and **counted**, never padded — padding would shift every column |
| `manifest.json`, `_common/…`, `.parquet` in the same container | `shouldIngest()` skips them |

## Authentication

**Managed identity only. There is no credential in this app to store, rotate or
leak** (CLAUDE.md hard rule 5).

* The **trigger** uses an identity-based connection: `connection: "CostExports"`
  resolves `CostExports__blobServiceUri` and
  `CostExports__credential=managedidentity`. No `AzureWebJobsStorage` connection
  string points at this container and no SAS exists.
* The **write** uses `DefaultAzureCredential` → the same managed identity, with a
  token scoped to `https://storage.azure.com/.default`, the audience OneLake's
  ADLS Gen2 surface accepts.

RBAC the identity needs (granted by L6's Bicep):

| Scope | Role | Why |
|---|---|---|
| cost-export storage account | Storage Blob Data Reader | read the export |
| Fabric workspace `mls-operations` | Contributor | write into OneLake |

`tests/lakehouse.test.ts` asserts that every outbound request carries a bearer
token and that no request URL ever contains a SAS signature or account key.

## Application settings

All placed by L6's platform deployment. None is a secret.

| Setting | Required | Default | Purpose |
|---|---|---|---|
| `FABRIC_WORKSPACE` | yes | — | workspace holding the lakehouse |
| `FABRIC_LAKEHOUSE` | yes | — | lakehouse name, no `.Lakehouse` suffix |
| `CostExports__blobServiceUri` | yes | — | trigger's identity-based connection |
| `CostExports__credential` | yes | — | `managedidentity` |
| `COST_EXPORT_CONTAINER` | no | `costexports` | container the trigger watches |
| `LAKEHOUSE_COST_PATH` | no | `cost_daily` | folder under `Files/` |
| `ONELAKE_ENDPOINT` | no | `https://onelake.dfs.fabric.microsoft.com` | sovereign-cloud override |
| `COST_CENTER_BUDGETS` | no | `{}` | JSON: `{"Propulsion": 8610, …}` → `budget_usd` |
| `RESOURCE_GROUP_COST_CENTERS` | no | `{}` | JSON: RG → cost centre, for untaggable resources |
| `FALLBACK_COST_CENTER` | no | `Unallocated` | where unresolvable rows land |
| `DEFAULT_CURRENCY` | no | `USD` | used when the export has no currency column |

A malformed JSON setting throws `ConfigurationError` at startup rather than
degrading to `{}`. Silently losing every budget is worse than a failed
invocation with a message.

## A paused Fabric capacity (L06 failure mode 5)

OneLake *storage* operations do not need the capacity resumed, but a throttled or
unreachable workspace still fails the write. When that happens the handler
**rethrows**, so the Functions host's own retry policy (`host.json`:
exponential backoff, 5 attempts, 10 s → 5 min) re-runs the invocation and, after
the budget, moves the blob receipt to the poison queue. That is the platform's
"queue and retry until the next resumed window", and it beats a bespoke retry
loop inside a consumption-plan Function.

## Layout

```
src/
  csv.ts                     RFC 4180 reader + byte-stable writer (no deps)
  costDaily.ts               the six-column contract, derived ids, ordering
  normalise.ts               column aliases, coercion, tags, grain aggregation
  lakehouse.ts               OneLake ADLS Gen2 writer + the PartitionWriter port
  ingest.ts                  orchestration, the refusals, the idempotency contract
  config.ts                  app settings -> typed config
  functions/cost-ingest.ts   the ONLY host-aware file: bindings + managed identity
tests/                       node --test, zero cloud calls, zero npm install
```

The split mirrors `apps/directline-token`: the binding shim owns the SDK
dependencies, the logic owns none. Every module under test imports nothing but
Node built-ins, which is why the suite runs with no `npm install` at all.

## Tests

```sh
cd apps/cost-ingest
npm test         # node --test "tests/**/*.test.ts" — 84 tests, no network
```

The script uses a **glob**, not a bare directory: `node --test tests/` does not
do what the docs imply here and silently runs nothing. The `.ts` sources execute
directly under Node 22+/24 type stripping, so there is no build step for tests.

```sh
npm run typecheck   # tsc --noEmit
npm run build       # tsc -> dist/, which is what deploys
```

Coverage, by the brief's four headings:

* **parse** — `tests/csv.test.ts`: BOM, CRLF, quotes, doubled quotes, embedded
  newlines, ragged rows, blank lines, round-trip through the writer.
* **normalisation** — `tests/normalise.test.ts`: three export versions, alias
  precedence, all three date shapes, amount coercion including credits and
  scientific notation, tag formats, cost-centre resolution order, grain
  aggregation, rounding once.
* **idempotency** — `tests/ingest.test.ts`: re-ingest is byte-identical; day-6
  MTD over day-5 keeps the row count flat and the ids unique; a restatement
  overwrites rather than sums; only months in the export are touched;
  `tests/lakehouse.test.ts` pins the truncating create.
* **malformed input** — both: not-a-cost-export throws with the headers it saw;
  every-row-rejected throws; header-only skips *without* clobbering a good
  month; partial rejections still write the good rows; a writer failure
  propagates.

## Known gaps

* **Not a repo-root workspace member.** Like `apps/directline-token`, this app
  deploys as its own Functions app with its own dependency closure. It still
  needs adding to the root `package.json` `workspaces` list so `npm test` at the
  root reaches it — that file is owned elsewhere this round.
* **Non-USD amounts.** If the export has no USD column and bills in another
  currency, the value lands in `amount_usd` with `currency` set to the real code.
  The column name then overstates what it holds. For this demo's single-currency
  estate that never happens; a multi-currency estate needs an FX step here.
* **Never run against a tenant.** Cost Management is tenant-only and its first
  export can take 24 h (L06 V6.3), so the end-to-end path is deferred by design.
  Everything above is proven against fixtures.

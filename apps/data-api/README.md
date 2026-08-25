# @mls/data-api — the serving layer (L7)

Both frontends already contained an `ApiProvider` that fetched `/tables/…` and
`/feeds/…`. Nothing served them (Phase Q gap **Q-4**). This package is that
server, and it was written to the providers rather than the other way round:
the routes, the response shapes and the row types here are copies of what
`apps/launch-ops/src/providers` and `apps/control-tower/src/providers` already
expected, and a test re-derives them from those files on every run.

## The served contract

| Route | Answers | Consumed by |
|---|---|---|
| `GET /tables/:table` | a bare JSON **array** of rows | launch-ops (`launches`, `vehicles`, `pads`, `scrubs`), control tower (`cost_daily`, `telemetry_summary`) |
| `GET /feeds/:name` | the feed payload, shape per feed | control tower Dev + Sec tabs |
| `GET /healthz` | liveness, backend mode, allowlists, telemetry state | Container Apps probes, L7 V7.1 |

Ten allowlisted tables: `launches`, `scrubs`, `vehicles`, `pads`, `parts`,
`suppliers`, `work_orders`, `telemetry_summary`, `cost_daily`,
`findings_history`.

Six allowlisted feeds, and the top-level shape each one answers with:

| Feed | Shape | Upstream |
|---|---|---|
| `workflow-runs` | `{ total_count, workflow_runs[] }` | GitHub Actions runs |
| `code-scanning-alerts` | array | GitHub code scanning |
| `dependabot-alerts` | array | GitHub Dependabot |
| `secure-score` | `{ value[] }` | Defender for Cloud |
| `secure-score-controls` | `{ value[] }` | Defender for Cloud |
| `app-requests` | `{ tables[] }` | Log Analytics query API |

The array-vs-object distinction is not cosmetic: launch-ops' provider throws
unless `/tables/:table` returns an array, which is why row metadata lives in
response headers (`X-MLS-Row-Count`, `X-MLS-Row-Cap`, `X-MLS-Truncated`) rather
than in an envelope.

## Two backends behind one interface

Selected once at boot by `MLS_DATA_BACKENDS`, and reported on `/healthz`.

- **`local`** — `data/generated/*.json` for tables, committed fixtures for
  feeds. A test harness: it is what CI and a laptop run against. Since the
  2026-08-24 sponsor directive it is explicitly *not* a deliverable.
- **`cloud`** — Azure SQL for the operational seven, the Fabric lakehouse SQL
  analytics endpoint for the analytical three (`telemetry_summary`,
  `cost_daily`, `findings_history`), and the live GitHub / Defender / Log
  Analytics APIs for the feeds. Everything authenticates with the container
  app's managed identity through `@azure/identity`.

Both run every row through the same normalizer, so a `Date` from TDS and a
string from JSON land on the wire identically. `tests/local-backend.test.ts`
asserts the local path is byte-for-byte the generator output; the cloud tests
assert a TDS-shaped row produces exactly the same JSON.

## Guardrails

- **Allowlists, not validation.** The path segment is matched against a frozen
  tuple and then discarded — every SQL object name, column list, upstream URL
  and file path is looked up from a constant keyed by the matched *literal*. No
  caller string is ever concatenated into SQL or a path.
- **Fixed projections.** `SELECT TOP (@limit) <explicit columns>` — never
  `SELECT *` — so a column added by a later migration cannot reach a browser.
- **Row cap.** `MLS_MAX_ROWS` (default 10 000) is a ceiling; `?limit=` clamps
  below it. Cloud reads ask for cap+1 so truncation is measured, not assumed.
- **CORS.** Exact-origin match from `MLS_ALLOWED_ORIGINS`; `*` is refused at
  boot. Trace-context headers are permitted so browser telemetry correlates;
  `Authorization` is not.
- **Errors.** One typed envelope (`{ error: { code, message, status,
  requestId } }`). Upstream text never reaches a client, and everything logged
  goes through a redactor covering connection strings, bearer tokens, JWTs,
  GitHub tokens and SAS signatures.
- **Read-only.** No body parser is installed; anything but `GET`/`HEAD` is
  refused before routing.

## OpenTelemetry

One hand-built server span per request, exported to Azure Monitor when
`APPLICATIONINSIGHTS_CONNECTION_STRING` is set and a silent no-op when it is
not. There is deliberately no auto-instrumentation: attributes come from an
allowlist (`src/telemetry/attributes.ts`), so no raw path, query string, header
or upstream message can become telemetry. Incoming W3C trace context is
continued, so a browser page view and this service's span share one trace.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `MLS_DATA_BACKENDS` | `local` | `local` \| `cloud` |
| `PORT` | `8080` | |
| `MLS_ROUTE_PREFIX` | *(none)* | Mount point for the data routes, e.g. `/api` |
| `MLS_ALLOWED_ORIGINS` | *(none)* | Comma-separated exact origins |
| `MLS_MAX_ROWS` | `10000` | Hard row ceiling |
| `MLS_TABLE_CACHE_SECONDS` | `60` | |
| `MLS_FEED_CACHE_SECONDS` | `30` | |
| `MLS_DATA_DIR` | `data/generated` | LOCAL only |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | *(none)* | Absent ⇒ tracing off |

Cloud mode additionally requires `MLS_SQL_SERVER`, `MLS_SQL_DATABASE`,
`MLS_FABRIC_SQL_ENDPOINT`, `MLS_FABRIC_DATABASE`, `MLS_GITHUB_REPO`,
`MLS_DEFENDER_SUBSCRIPTION_ID` and `MLS_LOG_ANALYTICS_WORKSPACE_ID`; boot fails
naming anything missing rather than 502-ing later. `MLS_GITHUB_TOKEN` is
optional — without it the three GitHub feeds fail closed with a typed error and
`/healthz` says so. It is the one credential-shaped input, and it must arrive
as a Container Apps secret reference resolved from Key Vault by the app's
managed identity, exactly like the Direct Line secret.

## How the browser reaches this service — CLOSED

Both `ApiProvider`s default to `baseUrl = "/api"`, i.e. a **same-origin**
request to the app's own host. That used to fall through each frontend's SPA
fallback and return `index.html` where the provider expected JSON.

Resolved by **option 1, the same-origin proxy**: each frontend now ships
`nginx.conf.template` with an `/api/` location proxying to `${DATA_API_ORIGIN}`,
substituted at container start by the nginx entrypoint's envsubst. The
`proxy_pass` carries a **trailing slash**, so the prefix is stripped and
`/api/tables/launches` arrives here as `/tables/launches` — therefore leave
`MLS_ROUTE_PREFIX` unset. Same-origin also means no CORS preflight on the data
path, so `MLS_ALLOWED_ORIGINS` stays empty in the normal deployment; the CORS
support remains for the cross-origin variant.

The L7 deploy must set `DATA_API_ORIGIN` on both frontend container apps to
this service's URL. Its Dockerfile default is a deliberately unreachable
loopback address rather than a hostname: nginx resolves names in `proxy_pass`
at startup and refuses to start if one does not resolve, so a hostname default
would turn "API not wired yet" into "the app is down". As shipped, the SPA
serves normally and only `/api` returns 502 until the variable is set.

`/healthz` still reports `routePrefix`, so a prefix mismatch is one request
away from being diagnosed rather than a mystery.

## Running

```bash
npm run dev  --workspace apps/data-api    # tsx, LOCAL backends
npm test     --workspace apps/data-api    # vitest
npm run build --workspace apps/data-api   # tsc -> dist/
```

LOCAL mode reads generator output, so run `python -m generators build` from
`data/` first.

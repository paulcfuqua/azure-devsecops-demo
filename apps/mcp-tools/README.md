# @mls/mcp-tools

The Meridian Launch Systems **MCP tool server** — the tool half of showpiece #1
(L8). It exposes exactly five read-only operations tools over the Model Context
Protocol so a **custom Microsoft Copilot Studio agent** can attach to it and
call them.

```
Copilot Studio agent  ──MCP / Streamable HTTP──▶  POST /mcp  (this service)
   (all orchestration)                              5 tools, data only
```

There is **no LLM in this package**. Per the sponsor-directed amendment
[`docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md`](../../docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md),
all runtime LLM work moved into Copilot Studio: it owns the prompt, the tool
choice, the multi-turn reasoning and the answer surface (Adaptive Cards,
embedded in control-tower via Direct Line). This service owns the tools and
nothing else. No Anthropic SDK, no API key, no prompt, no `/ask`.

## Attaching this server to the Copilot Studio agent

| | |
| --- | --- |
| Transport | **Streamable HTTP** (`POST`). SSE is not offered — Copilot Studio dropped SSE support after August 2025. |
| URL | `https://<container-app-fqdn>/mcp` (local: `http://localhost:8080/mcp`) |
| Session | **Stateless.** No `Mcp-Session-Id` is issued or required; every POST is self-contained, so the container app can scale to zero and back mid-conversation. `GET`/`DELETE /mcp` answer `405` — there is no server-initiated stream and no session to delete. |
| Auth | **None inside the app.** The container app is the security boundary: Entra ID / managed identity at the ingress, per the amendment ("Entra ID / managed identity throughout"). The service holds no secret of any kind and issues no token. If the connector needs a header, terminate it at ingress, not here. |
| Tools | Exactly five (below). `tools/list` returning anything other than five is an audit failure (V8.3). |
| Result shape | Data only — each result is one `text` block containing the adapter's JSON, plus the same payload as `structuredContent.result`. No prose, no UI, no component specs: the agent renders the Adaptive Card. |
| Errors | A bad query or a failing adapter comes back as an `isError` tool result with the message, not a protocol error, so the agent can correct itself and retry. |

Registering it: Copilot Studio → **Tools → Add a tool → Model Context
Protocol → connect to an existing MCP server**, pointing at the `/mcp` URL
([docs](https://learn.microsoft.com/en-us/microsoft-copilot-studio/mcp-add-existing-server-to-agent)).
The Fabric data agent is attached separately as a *knowledge* source for NL2SQL;
these five are *tools*. If the Fabric preview is unavailable in the region,
`query_lakehouse_sql` here is the documented fallback for lakehouse questions.

## The five tools

| Tool | What it answers | Local backend (Phase P) | Cloud backend (L5–L8) |
| --- | --- | --- | --- |
| `query_lakehouse_sql` | anything in the operations lakehouse | real SQL via sql.js over `data/generated/*.csv` (SQLite) | Fabric lakehouse SQL analytics endpoint (T-SQL) |
| `query_log_analytics` | platform health/latency/errors | committed fixture | Azure Monitor Log Analytics |
| `get_github_security` | open dependency and code-scanning alerts | committed fixture | GitHub Security REST API |
| `get_defender_posture` | secure score and failing controls | committed fixture | Defender for Cloud (ARM) |
| `get_cost_series` | daily spend vs budget by cost center | real query over `cost_daily` | Azure Cost Management |

### Tool descriptions are agent-facing surface area

The agent's orchestrator sees **only** each tool's name, description and input
JSON Schema. Those three strings are the entire basis on which it decides which
tool to call and with what arguments — the descriptions in
[`src/tools/index.ts`](./src/tools/index.ts) are therefore *behaviour*, not
documentation. `query_lakehouse_sql` carries the full table/column schema, the
enum values, the date idioms and the 500-row cap for exactly this reason: it is
the only place the agent can learn them.

Editing a description is a behavioural change. Review it like code, and re-run
`npm run eval` after.

### The SQL dialect follows the active backend

`query_lakehouse_sql`'s description is **generated**, not written, because the
idioms it must advertise depend on the engine behind it:

| | local (`sqlite`) | cloud (`tsql`) |
| --- | --- | --- |
| day of week | `strftime('%w', actual_date)` → 0=Sun..6=Sat | `DATEPART(weekday, actual_date)` → 1=Sun..7=Sat |
| month bucket | `strftime('%Y-%m', date)` | `CONVERT(char(7), date, 126)` / `FORMAT(date,'yyyy-MM')` |
| row limit | `LIMIT n` | `SELECT TOP (n)` |

`strftime` does not exist in T-SQL. A single hardcoded description is therefore
wrong in one of the two modes, so each backend declares its `dialect` and
`tools/list` advertises the idioms of the engine the query will actually hit.
The reasoning, and the DATEFIRST pin behind the T-SQL weekday numbering, are in
[`src/tools/sql-dialect.ts`](./src/tools/sql-dialect.ts).

The **read-only gate is one function in both dialects**
(`assertReadOnlySingleStatement`): exactly one statement, `SELECT`/`WITH` only,
DDL/DML refused, 500-row cap. T-SQL adds refusals SQLite never needed (`SET`,
`EXEC`, `sp_`/`xp_`, `OPENROWSET`) because a TDS batch would execute them.

## Backends

`src/tools/backends.ts` defines one interface per tool with two full
implementations: a LOCAL adapter and a CLOUD adapter (in `src/tools/cloud/`).
Swapping backends does not touch the MCP surface — same tool names, same
schemas, **same response shapes**, asserted by `tests/shape-parity.test.ts` from
one shared shape function so drift on either side fails a test.

| Tool | Local | Cloud | Auth |
| --- | --- | --- | --- |
| `query_lakehouse_sql` | sql.js over `data/generated/*.csv` | Fabric SQL analytics endpoint (TDS via `mssql`) | managed identity, `https://database.windows.net/.default` |
| `query_log_analytics` | fixture | Azure Monitor query API | managed identity, `https://api.loganalytics.io/.default` |
| `get_github_security` | fixture | GitHub REST (Dependabot + code scanning) | `GITHUB_TOKEN` from the environment |
| `get_defender_posture` | fixture | ARM `Microsoft.Security/secureScores` | managed identity, `https://management.azure.com/.default` |
| `get_cost_series` | `cost_daily` | Cost Management query + Consumption budgets | managed identity, `https://management.azure.com/.default` |

- **`query_lakehouse_sql`** executes real SQL through **sql.js** (SQLite
  compiled to WebAssembly — no native modules, so it builds on Windows ARM64)
  against an in-memory database loaded from Track A's deterministic CSVs.
- **Fixtures** (`fixtures/*.json`) are shaped exactly like the real API
  responses they stand in for, so the cloud wiring is a backend swap, not a
  reshape. Synthetic data only. Locally the KQL and the alert filters are
  recorded, not executed; the shape is the contract.
- **No stored credentials** (hard rule 5). Every Azure upstream authenticates
  with `DefaultAzureCredential` — the container app's managed identity in the
  cloud, `az login` on a laptop — with `AZURE_CLIENT_ID` selecting a
  user-assigned identity when the app has more than one. Tokens are cached per
  scope and shared by all four Azure adapters. GitHub has no managed-identity
  equivalent, so its token is injected by the platform and never logged.
- **Resilience**, shared by all four HTTP adapters (`src/tools/http.ts`):
  pagination (`Link: rel=next` for GitHub, `nextLink` for ARM and Cost
  Management), retry on **429/503 only** honouring `Retry-After` with jittered
  exponential backoff behind a total elapsed budget, and a typed error surface
  (`AdapterError` with `kind` ∈ config/auth/bad_request/not_found/throttled/
  upstream/timeout). Adapter failures reach the agent as MCP `isError` results
  carrying the upstream's own message, redacted, so it can self-correct.

### Selecting the backend set

`MLS_TOOL_BACKENDS=local|cloud`. `local` needs nothing. `cloud` needs six
settings and **fails fast at boot listing every missing one at once**:

```sh
MLS_TOOL_BACKENDS=cloud
MLS_FABRIC_SQL_ENDPOINT=<guid>.datawarehouse.fabric.microsoft.com
MLS_FABRIC_DATABASE=mls_operations
MLS_LOG_ANALYTICS_WORKSPACE_ID=<workspace GUID>
MLS_GITHUB_REPO=paulcfuqua/azure-devsecops
GITHUB_TOKEN=<security_events scope>          # or MLS_GITHUB_TOKEN
AZURE_SUBSCRIPTION_ID=<subscription>
# optional
AZURE_CLIENT_ID=<user-assigned managed identity>
MLS_COST_SCOPE=/subscriptions/<id>/resourceGroups/mls-rg-apps
MLS_COST_CENTER_TAG=costCenter
APPLICATIONINSIGHTS_CONNECTION_STRING=<App Insights>
```

The selection is observable on `GET /healthz`, which reports `mode`,
`sqlDialect` and the implementation class behind each of the five tools — a
`cloud` server still advertising `sqlite` would mean the descriptions and the
engine had come apart.

## Telemetry

OpenTelemetry traces + metrics, exported to Azure Monitor / Application Insights
when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set and a clean no-op when it is
not. One span per tool call, `mcp.tool/<name>`, carrying:

```
mls.tool.name  mls.backend.mode  mls.sql.dialect
mls.tool.row_count  mls.tool.truncated  mls.tool.outcome
mls.tool.duration_ms  mls.error.kind
```

plus `mls.mcp.tool.calls` (counter), `mls.mcp.tool.duration` and
`mls.mcp.tool.rows` (histograms).

**A span never carries the SQL text, the KQL text, any argument value or any
result cell.** Attributes go through an allowlist that drops everything else,
and `tests/telemetry.test.ts` asserts end-to-end through MCP that a query's text
does not appear anywhere in its span. On failure the span records the error
*kind*, never the upstream's message.

### Data prerequisite

The lakehouse adapter reads `data/generated/*.csv` (gitignored generator
output). If it is missing:

```sh
cd data && python -m generators build
```

Override the location with `MLS_DATA_DIR`.

## Golden-question eval

```sh
npm run eval          # the tool layer — offline, no tenant, pass bar 10/10
npm run eval:agent    # the deployed agent over Direct Line — L8, placeholder today
```

The ten golden questions survive the amendment intact; what changed is what they
measure. `npm run eval` boots this service in-process, connects the official MCP
SDK client over Streamable HTTP and, for each question, issues the tool call
that answers it — asserting the returned data carries facts **re-derived
independently** from the lakehouse by differently-phrased SQL. A pass means *the
answer to this question is reachable through the MCP tool surface*. Ranking
questions ("most", "highest", "lowest") are checked against row 0, so a ranked
list that merely contains the winner does not pass. It also asserts the surface
itself: `tools/list` returns exactly five, and all five answer a smoke call.

The one documented hardcode is the canonical question — *"Which day of the week
has the most launches?"* → **Saturday (309)**, the generator's built-in weekday
bias. The harness fails loudly on seed drift rather than silently re-baselining.

`npm run eval:agent` is the other half, and is **implemented**: it opens one
Direct Line conversation against the deployed Copilot Studio agent, asks a
discarded warm-up question (so V8.5's p95 excludes the cold start), then the ten
golden questions, polls by watermark until each turn settles, and fact-checks
the returned Adaptive Cards with the *same* independently re-derived
expectations and the same `resultContains` walker the tool suite uses — a card
is JSON, so the walker works on it unchanged. It writes
`evals/agent-eval-results.json` (per question: pass/fail, latency, tool calls,
card payloads, missing facts, and which path answered) and exits non-zero below
the L8 pass bar of 9/10.

Until the tenant and the published agent exist there is nothing to call, so with
no `DIRECTLINE_SECRET` (or `MLS_DIRECTLINE_SECRET`) set it prints why and exits
0, **making no network call** — `--require-configured` turns that same refusal
into exit 1 for L8's own workflow. Both paths are unit-tested, the unconfigured
one against a `fetch` that throws if it is called at all. The client is
[`evals/directline.ts`](./evals/directline.ts); the harness is
[`evals/agent-eval.ts`](./evals/agent-eval.ts).

Each `npm run eval` run writes `evals/eval-results.json` — per question:
pass/fail, the exact tool call issued, expected and missing facts, the returned
payload and latency. That is the artifact CI uploads and the Verifier consumes
as *claims* to re-derive.

## Develop

```sh
npm install
npm test        # vitest, 248 tests — see below
npm run eval    # 10/10 through the MCP tool surface
npm run build   # tsc -> dist/
npm run dev     # tsx src/index.ts, listens on :8080
```

The suite covers the MCP client smoke test, the allowlist, the sql.js adapter,
the CSV parser, the SQLite/T-SQL dialect and its shared read-only gate, the five
cloud adapters, the shared HTTP retry/pagination layer, local↔cloud shape
parity, the OTel span contract, backend selection, and the eval:agent Direct
Line driver. **Every cloud test runs against a mocked `fetch` or an injected TDS
executor — the suite makes zero live cloud calls**, which is also why it needs no
tenant to be meaningful.

Container build (context is the repo root by convention with the other apps;
nothing needs pre-building into it):

```sh
docker build -f apps/mcp-tools/Dockerfile -t mls-mcp-tools:local .
```

## HTTP surface

| Route | Response |
| --- | --- |
| `POST /mcp` | MCP over Streamable HTTP (`initialize`, `tools/list`, `tools/call`) |
| `GET /mcp`, `DELETE /mcp` | `405` — stateless, POST only |
| `GET /healthz` | `{ ok, mode, tools, transport, endpoint, sqlDialect, adapters, telemetry }` |

`/healthz` is unauthenticated at the ingress, so it reports *which* adapter and
exporter are live and never a workspace id, an endpoint FQDN, a token or a
connection string.

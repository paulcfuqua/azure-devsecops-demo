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
| Tools | Exactly five (below). `tools/list` returning anything other than five is an audit failure (V8.2). |
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
| `query_lakehouse_sql` | anything in the operations lakehouse | real SQL via sql.js over `data/generated/*.csv` | Fabric lakehouse SQL analytics endpoint |
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
enum values, the SQLite date idioms and the 500-row cap for exactly this
reason: it is the only place the agent can learn them.

Editing a description is a behavioural change. Review it like code, and re-run
`npm run eval` after.

## Backends

`src/tools/backends.ts` defines one interface per tool with two
implementations: a LOCAL adapter (used now) and a typed cloud stub (implemented
at L5–L8, currently rejecting with an explicit "implemented at L8" error).
Swapping backends does not touch the MCP surface — same tool names, same
schemas, same result shapes.

- **`query_lakehouse_sql`** executes real SQL through **sql.js** (SQLite
  compiled to WebAssembly — no native modules, so it builds on Windows ARM64)
  against an in-memory database loaded from Track A's deterministic CSVs.
  Statements are read-only (`SELECT`/`WITH` only) and results are capped at 500
  rows.
- **Fixtures** (`fixtures/*.json`) are shaped exactly like the real API
  responses they stand in for — Log Analytics `tables[{columns, rows}]`, GitHub
  `dependabot_alerts`/`code_scanning_alerts` items, Defender `secureScores` +
  controls — so L8 wiring is a backend swap, not a reshape. Synthetic data only.
  Locally the KQL and the alert filters are recorded, not executed; the shape is
  the contract.

`MLS_TOOL_BACKENDS` selects the adapter set. Only `local` is constructible
today; `cloud` fails fast at boot with the list of what L5–L8 must supply.

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

`npm run eval:agent` is the other half, and is a **documented placeholder**: it
will drive the deployed Copilot Studio agent over Direct Line and fact-check its
Adaptive Cards with the same expectations (L8 pass bar ≥ 9/10). Until the tenant
and the published agent exist there is nothing to call, so with no
`DIRECTLINE_SECRET` set it prints why and exits 0 — `--require-configured` turns
that into a failure for L8's own workflow. It makes no network call in either
case. The protocol it will speak is written out in
[`evals/run-agent.ts`](./evals/run-agent.ts).

Each `npm run eval` run writes `evals/eval-results.json` — per question:
pass/fail, the exact tool call issued, expected and missing facts, the returned
payload and latency. That is the artifact CI uploads and the Verifier consumes
as *claims* to re-derive.

## Develop

```sh
npm install
npm test        # vitest: MCP client smoke test, allowlist, sql.js adapter, CSV parser
npm run eval    # 10/10 through the MCP tool surface
npm run build   # tsc -> dist/
npm run dev     # tsx src/index.ts, listens on :8080
```

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
| `GET /healthz` | `{ ok, mode, tools, transport, endpoint }` |

# @mls/copilot-svc

The Meridian Launch Systems copilot service — **showpiece #1 (L8)**. It answers
operational questions by running an LLM tool-use loop over exactly five
allowlisted tools and returning a **JSON component spec** for
[`@mls/spec-renderer`](../shared/spec-renderer) — never generated UI code.

```
POST /ask  { "question": "Which day of the week has the most launches?" }
        ->  { "spec": <renderer JSON spec>, "sql": [...], "toolTrace": [...] }
```

## The two contracts this service enforces

1. **Tool allowlist (audit V8.2).** Exactly five tools are registered with the
   model, and the loop refuses any other tool name *before execution*, returning
   an `is_error` tool result and recording the attempt in `toolTrace` with
   `rejected: true`:

   | Tool | Local backend (Phase P) | Cloud backend (L8) |
   | --- | --- | --- |
   | `query_lakehouse_sql` | real SQL via sql.js over `data/generated/*.csv` | Fabric lakehouse SQL analytics endpoint |
   | `query_log_analytics` | committed fixture | Azure Monitor Log Analytics |
   | `get_github_security` | committed fixture | GitHub Security REST API |
   | `get_defender_posture` | committed fixture | Defender for Cloud (ARM) |
   | `get_cost_series` | real query over `cost_daily` | Azure Cost Management |

2. **Spec validation gate (audit V8.1b).** The model's final answer is parsed as
   JSON and validated against the renderer schema **before** it leaves the
   service. An invalid spec buys the model exactly **one repair round** (the
   JSON-Pointer errors go back to it); a still-invalid answer returns a
   structured `422 invalid_spec` error. An invalid spec is never returned, and
   runtime-generated UI code is never returned at all.

## Backends

`src/tools/backends.ts` defines one interface per tool with two implementations:
a LOCAL adapter (used now) and a typed cloud stub (implemented at L8, currently
rejecting with an explicit "implemented at L8" error). Swapping backends does not
touch the tool loop.

- **`query_lakehouse_sql`** executes real SQL through **sql.js** (SQLite compiled
  to WebAssembly — no native modules, so it builds on Windows ARM64) against an
  in-memory database loaded from Track A's deterministic CSVs. Statements are
  read-only (`SELECT`/`WITH` only) and results are capped at 500 rows.
- **Fixtures** (`fixtures/*.json`) are shaped exactly like the real API
  responses they stand in for — Log Analytics `tables[{columns, rows}]`, GitHub
  `dependabot_alerts`/`code_scanning_alerts` items, Defender `secureScores` +
  controls — so L8 wiring is a backend swap, not a reshape. Synthetic data only.

### Data prerequisite

The lakehouse adapter reads `data/generated/*.csv` (gitignored generator output).
If it is missing:

```sh
cd data && python -m generators build
```

Override the location with `MLS_DATA_DIR`.

## LLM modes

| Condition | Mode | Driver |
| --- | --- | --- |
| `MOCK_LLM=1` | mock | `src/llm/mock.ts` — deterministic replay |
| `ANTHROPIC_API_KEY` set (and `MOCK_LLM != 1`) | live | `src/llm/live.ts` — Anthropic Messages API |
| neither | mock | (the service never fails for a missing key) |

**Mock mode** is a real end-to-end exercise, not a stub: the fake driver replays
a recorded tool plan (`src/llm/plans.ts`), the tools **actually execute** (real
SQL, real fixtures), and the composed spec goes through the same validation gate.
Tools → SQL → spec → validation is fully covered without an API key.

**Model configuration** lives in [`config/copilot.json`](./config/copilot.json)
— `claude-opus-5`, adaptive thinking, 16 000 max tokens — pinned in committed
config so a model change is a deliberate PR, never drift (L08 playbook, failure
mode 4). `COPILOT_MODEL` overrides at runtime. The model id is never hardcoded
in source.

## Golden-question eval

```sh
npm run eval        # mock mode — CI path, no API key, pass bar 10/10
npm run eval:live   # live mode — the L8 audit instrument, pass bar >= 9/10
```

Ten questions whose answers derive from the deterministic seed (`20260822`).
Expectations are **computed at eval time** by running independent SQL against the
lakehouse — they are not copied from the mock plans, mirroring how the Verifier
re-executes the copilot's SQL at V8.1. The one documented hardcode is the
canonical question: *"Which day of the week has the most launches?"* →
**Saturday (309)**, the generator's built-in weekday bias; the harness fails loudly
on seed drift rather than silently re-baselining.

Each run writes `evals/eval-results.json` — per question: pass/fail, expected and
missing facts, the returned spec, every SQL statement executed, latency, and the
full tool-call trace. That is the artifact L8's eval workflow uploads and the
Verifier consumes as *claims* to re-derive.

## Develop

```sh
npm install
npm test        # vitest: 29 tests (allowlist, sql.js adapter, validation gate, /ask e2e, CSV)
npm run eval    # 10/10 in mock mode
npm run build   # tsc -> dist/
npm run dev     # tsx src/index.ts, listens on :8080
```

Container build (context is the **repo root**, because of the sibling
`@mls/spec-renderer` dependency):

```sh
docker build -f apps/copilot-svc/Dockerfile -t mls-copilot-svc:local .
```

`ANTHROPIC_API_KEY` is injected at deploy time as a Key Vault reference — it is
never baked into the image or committed anywhere.

## HTTP surface

| Route | Response |
| --- | --- |
| `POST /ask` | `200 {spec, sql?, toolTrace}` · `400 bad_request` (missing/empty question) · `422 invalid_spec` (gate failed after repair) · `502 llm_error` |
| `GET /healthz` | `{ok, mode, model}` |

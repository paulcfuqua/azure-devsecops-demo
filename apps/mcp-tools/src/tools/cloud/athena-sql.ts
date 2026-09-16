/**
 * `query_lakehouse_sql` — CLOUD adapter: AWS Athena over the Glue Data Catalog
 * (the sponsor's `launch-intel` lakehouse, database `launch_intel_lakehouse`).
 *
 * Athena's query surface is HTTP (the AWS SDK), not a persistent connection,
 * but it is asynchronous in a way the ARM/Log Analytics adapters are not: a
 * query is SUBMITTED (`StartQueryExecution`), then POLLED
 * (`GetQueryExecution`) until it leaves QUEUED/RUNNING, then its rows are
 * PULLED (`GetQueryResults`). All three calls sit behind `AthenaExecutor`, a
 * one-method seam — `run(sql, maxRows)` — that the unit tests implement
 * directly, exactly as `TdsExecutor` seams the Fabric TDS adapter. Everything
 * that makes this adapter *correct* — the dialect gate, the truncation probe,
 * the poll deadline, `AdapterError` on every failure path — lives above that
 * seam and is tested with no AWS account, no S3 bucket and no IAM role.
 *
 * ── Auth (hard rule 5) ───────────────────────────────────────────────────────
 * There is no managed identity in AWS, so trust runs the other direction: an
 * Entra token (scope `${audience}/.default`, the same `TokenProvider` seam
 * every other cloud adapter uses) is exchanged for temporary AWS credentials
 * via STS `AssumeRoleWithWebIdentity`, wrapped by `fromWebToken({ roleArn,
 * webIdentityToken })` from `@aws-sdk/credential-providers`. The Entra app is
 * registered for **token version 1** (`requestedAccessTokenVersion: 1`,
 * confirmed against the live tenant), so the audience AWS's trust policy
 * matches is the `api://` identifier URI, not a v2-style App ID URI variant.
 * No AWS access key or secret ever exists ahead of time — the only credential
 * this adapter starts with is the Entra identity already running the
 * container app.
 *
 * ── No workgroup default (confirmed from the sponsor's Terraform state) ─────
 * The `primary` workgroup in this account has no `aws_athena_workgroup`
 * resource behind it, so it enforces no result configuration of its own.
 * `StartQueryExecution` therefore always passes
 * `ResultConfiguration.OutputLocation` explicitly; relying on a workgroup
 * default would fail every single query with a configuration error.
 *
 * ── The 500-row cap, and the header row ─────────────────────────────────────
 * Athena has nothing like Fabric's TDS stream to cut short mid-flight, so the
 * cap is applied the same way: ask for one row more than the cap and see
 * whether it showed up (`MAX_RESULT_ROWS + 1`, the identical trick
 * `FabricLakehouseSqlBackend` uses). `GetQueryResults`' first row is *always*
 * the column header, never data, so the default executor requests
 * `MaxResults: maxRows + 1` off the wire (one more than what it was asked
 * for, to make room for that header) and drops row zero before handing the
 * caller's `maxRows` worth of data rows back up to `query()`, which then
 * applies the shared `MAX_RESULT_ROWS + 1` probe every adapter uses.
 *
 * ── What is NOT here ─────────────────────────────────────────────────────────
 * The trino dialect's idioms text (`sql-dialect.ts`) promises that
 * `day_of_week`'s numbering "is confirmed against the live endpoint by a
 * session probe at first query", mirroring Fabric's `SESSION_PROBE_SQL`. That
 * probe is separate, later work; this file does not add one, and the promise
 * stays unmet until it lands.
 */
import { assertReadOnlySingleStatement, MAX_RESULT_ROWS, type SqlDialect } from "../sql-dialect.js";
import { AdapterError, isAdapterError } from "../errors.js";
import type { TokenProvider } from "../auth.js";
import type { LakehouseQueryResult } from "../../data/lakehouse.js";
import type { LakehouseSqlBackend } from "../backends.js";

/** One result set off the wire: column names in order, rows as positional arrays. */
export interface AthenaRawResult {
  columns: string[];
  rows: unknown[][];
}

/**
 * The Athena seam. One method: submit `sql`, get back at most `maxRows` rows.
 * Everything about StartQueryExecution / poll / GetQueryResults lives on the
 * far side of this seam — the default implementation below, or a test's own.
 *
 * `maxRows` is a hard read limit, not a hint, exactly as `TdsExecutor.execute`'s
 * is: the adapter asks for MAX_RESULT_ROWS + 1 so it can tell "exactly 500"
 * from "more than 500".
 */
export interface AthenaExecutor {
  run(sql: string, maxRows: number): Promise<AthenaRawResult>;
}

export interface AthenaLakehouseOptions {
  /** IAM role the Entra token is exchanged for, via AssumeRoleWithWebIdentity. */
  roleArn: string;
  /** Entra identifier URI (`api://...`) AWS's trust policy matches as `aud`. */
  audience: string;
  region: string;
  /** The Glue Data Catalog database (`launch_intel_lakehouse`). */
  database: string;
  workgroup: string;
  /**
   * `s3://` URI Athena writes query results to. Required explicitly because
   * `workgroup` carries no default of its own — see the header note above.
   */
  outputLocation: string;
  tokens: TokenProvider;
  /** Injected by tests; the default lazily builds an `AthenaClient`. */
  executor?: AthenaExecutor;
  /** How long to wait for a query to leave QUEUED/RUNNING before giving up. */
  pollTimeoutMs?: number;
}

const DEFAULT_POLL_TIMEOUT_MS = 60_000;

export class AthenaLakehouseSqlBackend implements LakehouseSqlBackend {
  readonly dialect: SqlDialect = "trino";

  private readonly roleArn: string;
  private readonly audience: string;
  private readonly region: string;
  private readonly database: string;
  private readonly workgroup: string;
  private readonly outputLocation: string;
  private readonly tokens: TokenProvider;
  private readonly pollTimeoutMs: number;
  private executor: AthenaExecutor | undefined;

  constructor(options: AthenaLakehouseOptions) {
    this.roleArn = options.roleArn;
    this.audience = options.audience;
    this.region = options.region;
    this.database = options.database;
    this.workgroup = options.workgroup;
    this.outputLocation = options.outputLocation;
    this.tokens = options.tokens;
    this.pollTimeoutMs = options.pollTimeoutMs ?? DEFAULT_POLL_TIMEOUT_MS;
    this.executor = options.executor;
  }

  private getExecutor(): AthenaExecutor {
    if (!this.executor) {
      this.executor = createAthenaExecutor({
        roleArn: this.roleArn,
        audience: this.audience,
        region: this.region,
        database: this.database,
        workgroup: this.workgroup,
        outputLocation: this.outputLocation,
        tokens: this.tokens,
        pollTimeoutMs: this.pollTimeoutMs,
      });
    }
    return this.executor;
  }

  /**
   * Race an in-flight call against the poll deadline. A hung executor — a cold
   * query the demo cannot wait out, or, in a test, one that never resolves at
   * all — must fail the whole call as `timeout` rather than leave the agent
   * waiting on a Copilot Studio request that will itself time out with no
   * useful message.
   */
  private withPollTimeout<T>(promise: Promise<T>): Promise<T> {
    const pollTimeoutMs = this.pollTimeoutMs;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(
          new AdapterError("timeout", `Athena query did not complete within ${pollTimeoutMs}ms.`, {
            service: "athena-sql",
          }),
        );
      }, pollTimeoutMs);
      promise.then(
        (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        (err: unknown) => {
          clearTimeout(timer);
          reject(err);
        },
      );
    });
  }

  async query(sql: string): Promise<LakehouseQueryResult> {
    // The same gate every backend runs, in Trino mode: single statement,
    // SELECT/WITH only, no UNLOAD/CALL/session-state verbs — checked before
    // the engine (or the credential exchange) is ever touched.
    const statement = assertReadOnlySingleStatement(sql, "trino");

    const executor = this.getExecutor();

    let result: AthenaRawResult;
    try {
      result = await this.withPollTimeout(executor.run(statement, MAX_RESULT_ROWS + 1));
    } catch (err) {
      if (isAdapterError(err)) throw err;
      // Athena reports a bad statement — or any other engine failure — as
      // plain text on the FAILED query execution's StateChangeReason; that
      // upstream message is what the agent needs in order to reformulate.
      const message = err instanceof Error ? err.message : String(err);
      throw new AdapterError("upstream", `Athena query failed: ${message}`, {
        service: "athena-sql",
        cause: err,
      });
    }

    const truncated = result.rows.length > MAX_RESULT_ROWS;
    const rows = truncated ? result.rows.slice(0, MAX_RESULT_ROWS) : result.rows;
    return { columns: result.columns, rows, rowCount: rows.length, truncated };
  }

  async close(): Promise<void> {
    this.executor = undefined;
  }
}

/* ------------------------------------------------------------------ */
/* The default executor: @aws-sdk/client-athena via a federated token  */
/* ------------------------------------------------------------------ */

interface AthenaExecutorOptions {
  roleArn: string;
  audience: string;
  region: string;
  database: string;
  workgroup: string;
  outputLocation: string;
  tokens: TokenProvider;
  pollTimeoutMs: number;
}

/** How often to re-poll `GetQueryExecution`. Athena queries rarely resolve
 *  faster than this, and the AWS API is not free to hammer. */
const POLL_INTERVAL_MS = 1_000;

const IN_FLIGHT_STATES: ReadonlySet<string> = new Set(["QUEUED", "RUNNING"]);

/**
 * Coerce an Athena `Datum` (always a string, or absent for NULL) to the type
 * the LOCAL and Fabric adapters would have produced for the same cell, so all
 * three lakehouse backends are interchangeable to the agent (`backends.ts`'s
 * shape contract). Athena's own JDBC/ODBC drivers do exactly this coercion
 * client-side; its REST API leaves it to the caller.
 */
export function coerceAthenaValue(raw: string | undefined, type: string): unknown {
  if (raw === undefined) return null;
  switch (type) {
    case "tinyint":
    case "smallint":
    case "integer":
    case "bigint":
    case "double":
    case "float":
    case "real":
    case "decimal": {
      const n = Number(raw);
      return Number.isFinite(n) ? n : raw;
    }
    case "boolean":
      return raw === "true";
    default:
      // varchar/char, date, timestamp, json, array/map/row: Athena already
      // renders these as text, and that text is what sql.js's CSV-backed
      // columns and Fabric's normalised DATE strings both look like.
      return raw;
  }
}

/**
 * Lazily build an `AthenaClient` whose credentials come from exchanging this
 * container's Entra token for temporary AWS credentials
 * (`AssumeRoleWithWebIdentity`, wrapped by `fromWebToken`). Imported
 * dynamically for the same reason `mssql` and `@azure/identity` are: the
 * local and Fabric backends must not pay to load the AWS SDK.
 */
export function createAthenaExecutor(options: AthenaExecutorOptions): AthenaExecutor {
  let clientPromise: Promise<any> | undefined;
  let sdkPromise: Promise<any> | undefined;

  const getSdk = async (): Promise<any> => {
    if (!sdkPromise) {
      sdkPromise = import("@aws-sdk/client-athena").catch((err) => {
        sdkPromise = undefined;
        throw new AdapterError(
          "config",
          "MLS_TOOL_BACKENDS=cloud with an AWS lakehouse configured requires the " +
            "@aws-sdk/client-athena package. Run `npm install` in apps/mcp-tools — it is a " +
            "declared dependency the local and Fabric backends never load.",
          { service: "athena-sql", cause: err },
        );
      });
    }
    return sdkPromise;
  };

  const getClient = async (): Promise<any> => {
    if (!clientPromise) {
      clientPromise = (async () => {
        const sdk = await getSdk();
        let credentialProviders: any;
        try {
          credentialProviders = await import("@aws-sdk/credential-providers");
        } catch (err) {
          throw new AdapterError(
            "config",
            "MLS_TOOL_BACKENDS=cloud with an AWS lakehouse configured requires the " +
              "@aws-sdk/credential-providers package. Run `npm install` in apps/mcp-tools — " +
              "it is a declared dependency the local and Fabric backends never load.",
            { service: "athena-sql", cause: err },
          );
        }
        const credentials = credentialProviders.fromWebToken({
          roleArn: options.roleArn,
          webIdentityToken: await options.tokens.getToken(`${options.audience}/.default`),
        });
        return new sdk.AthenaClient({ region: options.region, credentials });
      })().catch((err) => {
        // A failed exchange (expired trust, throttled STS) must be retried on
        // the next call, not cached forever.
        clientPromise = undefined;
        throw err;
      });
    }
    return clientPromise;
  };

  return {
    async run(sql: string, maxRows: number): Promise<AthenaRawResult> {
      const sdk = await getSdk();
      const client = await getClient();
      const deadline = Date.now() + options.pollTimeoutMs;

      const start = await client.send(
        new sdk.StartQueryExecutionCommand({
          QueryString: sql,
          QueryExecutionContext: { Database: options.database },
          WorkGroup: options.workgroup,
          // `primary` enforces no output location of its own (no
          // aws_athena_workgroup resource exists behind it in this account) —
          // this is required, not a redundant belt-and-braces default.
          ResultConfiguration: { OutputLocation: options.outputLocation },
        }),
      );
      const queryExecutionId: string | undefined = start.QueryExecutionId;
      if (!queryExecutionId) {
        throw new AdapterError(
          "upstream",
          "Athena StartQueryExecution returned no QueryExecutionId.",
          { service: "athena-sql" },
        );
      }

      let state: string | undefined;
      let stateChangeReason: string | undefined;
      for (;;) {
        const execution = await client.send(
          new sdk.GetQueryExecutionCommand({ QueryExecutionId: queryExecutionId }),
        );
        state = execution.QueryExecution?.Status?.State;
        stateChangeReason = execution.QueryExecution?.Status?.StateChangeReason;
        if (!state || !IN_FLIGHT_STATES.has(state)) break;
        if (Date.now() >= deadline) {
          throw new AdapterError(
            "timeout",
            `Athena query ${queryExecutionId} did not leave ${state} within ` +
              `${options.pollTimeoutMs}ms.`,
            { service: "athena-sql" },
          );
        }
        await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
      }

      if (state !== "SUCCEEDED") {
        throw new Error(
          stateChangeReason ?? `Athena query ${queryExecutionId} ended in state ${state}.`,
        );
      }

      const results = await client.send(
        new sdk.GetQueryResultsCommand({
          QueryExecutionId: queryExecutionId,
          // One more than the caller's cap, to make room for the header row
          // GetQueryResults always returns first and which is never data.
          MaxResults: maxRows + 1,
        }),
      );
      const columnInfo: Array<{ Name?: string; Type?: string }> =
        results.ResultSet?.ResultSetMetadata?.ColumnInfo ?? [];
      const columns = columnInfo.map((c, i) => c.Name ?? `column${i + 1}`);
      const allRows: Array<{ Data?: Array<{ VarCharValue?: string }> }> =
        results.ResultSet?.Rows ?? [];
      // Row 0 is the header Athena always prepends; everything from row 1 on
      // is data.
      const dataRows = allRows.slice(1);
      const rows = dataRows.map((row) =>
        (row.Data ?? []).map((datum, i) =>
          coerceAthenaValue(datum.VarCharValue, columnInfo[i]?.Type ?? "varchar"),
        ),
      );
      return { columns, rows };
    },
  };
}

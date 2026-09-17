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
 * WHICH Entra identity is not a detail. The container app carries two
 * user-assigned managed identities, and the AWS IAM trust policy's `sub`
 * condition is pinned to one of them; `TokenProvider` here is built on a
 * credential naming that one explicitly (`cloud/index.ts`), never the shared
 * Azure one. When the exchange fails anyway, STS answers `AccessDenied` and
 * names neither the identity nor the audience it rejected — so `query()` adds
 * both, plus the role, to the error rather than leaving a reader to diff three
 * systems by hand against a message that blames the trust policy.
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
 * ── The session probe ────────────────────────────────────────────────────────
 * The trino dialect's idioms text (`sql-dialect.ts`) tells the agent that
 * `day_of_week`'s ISO numbering "is confirmed against the live endpoint by a
 * session probe at first query". It now is — see `ensureDialectContract` below,
 * which mirrors Fabric's `SESSION_PROBE_SQL` and fails loudly rather than
 * warning. A description asserting a verification that never happens is this
 * repository's signature defect aimed at its own agent, and the cheapest place
 * to catch it is the first query rather than the answer it silently skews.
 */
import {
  assertReadOnlySingleStatement,
  MAX_RESULT_ROWS,
  TRINO_SATURDAY_WEEKDAY,
  TRINO_SESSION_PROBE_DATE,
  TRINO_SESSION_PROBE_SQL,
  type SqlDialect,
} from "../sql-dialect.js";
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
  /**
   * Client id of the managed identity `tokens` was built on. Diagnostic only —
   * nothing authenticates with it here — but an STS `AccessDenied` names neither
   * the identity nor the audience it refused, and those are two of the three
   * values that have to match for the exchange to work.
   */
  identityClientId?: string;
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
  private readonly identityClientId: string | undefined;
  private readonly pollTimeoutMs: number;
  private executor: AthenaExecutor | undefined;
  private dialectContract: Promise<void> | undefined;

  constructor(options: AthenaLakehouseOptions) {
    this.roleArn = options.roleArn;
    this.audience = options.audience;
    this.region = options.region;
    this.database = options.database;
    this.workgroup = options.workgroup;
    this.outputLocation = options.outputLocation;
    this.tokens = options.tokens;
    this.identityClientId = options.identityClientId;
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

  /**
   * Turn an STS refusal into something a reader can act on.
   *
   * `AssumeRoleWithWebIdentity` answers `AccessDenied` and names none of the
   * three values that had to match — the role, the `aud` claim, and the `sub`
   * claim, which is decided by WHICH managed identity minted the token. A
   * container with two user-assigned identities can produce a perfectly valid
   * token from the wrong one, and the resulting message blames the AWS trust
   * policy for what is an Azure credential-selection problem. So say which three
   * were used; comparing them against the trust policy is then a diff rather
   * than an investigation across two clouds.
   *
   * Matched on the error text rather than an SDK error class because the
   * credential provider surfaces these through several wrapper types, and a
   * missed hint costs nothing while an absent one costs a demo.
   */
  private exchangeHint(message: string): string {
    if (!/AccessDenied|WebIdentity|InvalidIdentityToken|IDPRejectedClaim|not authorized/i.test(message)) {
      return "";
    }
    return (
      ` — this is the STS credential exchange, not the SQL. The token was requested from ` +
      `managed identity client id ${this.identityClientId ?? "(not recorded)"} for audience ` +
      `${this.audience}, and exchanged for ${this.roleArn}. The IAM trust policy must match ` +
      `that audience as 'aud' and that identity's PRINCIPAL id (not its client id) as 'sub'. ` +
      `A wrong identity here produces exactly this message while the trust policy is correct.`
    );
  }

  /**
   * Run once per process, before the first real answer: prove the engine numbers
   * `day_of_week` the way this tool's description tells the agent it does.
   *
   * `2026-08-22` is a Saturday, so ISO numbering must return 6. This is the
   * Trino counterpart of `FabricLakehouseSqlBackend.ensureSessionContract`, with
   * one difference that matters: Fabric PINS its numbering with `SET DATEFIRST 7`
   * and probes to confirm the pin took, while Athena offers nothing to pin, so
   * the probe is the only thing standing between the description and a guess.
   *
   * It FAILS rather than warns. A warning would be read by nobody and the agent
   * would carry on composing weekday filters against a numbering the tool told
   * it was verified — an answer that is wrong by exactly one day, in the
   * direction the Fabric tool's own numbering would produce, which is the least
   * detectable wrong answer available.
   */
  private async ensureDialectContract(): Promise<void> {
    if (!this.dialectContract) {
      this.dialectContract = (async () => {
        const executor = this.getExecutor();
        let probe: AthenaRawResult;
        try {
          probe = await this.withPollTimeout(executor.run(TRINO_SESSION_PROBE_SQL, 2));
        } catch (err) {
          if (isAdapterError(err)) throw err;
          // The probe is the FIRST thing that touches AWS, so the credential
          // exchange fails here rather than on the agent's own statement. Same
          // typed shape and same hint as `query()` gives — an untyped throw out
          // of a private method is how a credential problem ends up reported as
          // a tool crash.
          const message = err instanceof Error ? err.message : String(err);
          throw new AdapterError(
            "upstream",
            `The Athena dialect probe failed before any query ran: ${message}` +
              `${this.exchangeHint(message)}`,
            { service: "athena-sql", cause: err },
          );
        }
        const index = probe.columns.findIndex((c) => c.toLowerCase() === "seed_date_weekday");
        const weekday = Number(probe.rows[0]?.[index === -1 ? 0 : index]);
        if (weekday !== TRINO_SATURDAY_WEEKDAY) {
          throw new AdapterError(
            "config",
            `The Athena engine does not number day_of_week the way this tool's description ` +
              `promises: expected day_of_week(DATE '${TRINO_SESSION_PROBE_DATE}')=` +
              `${TRINO_SATURDAY_WEEKDAY} (a Saturday, ISO 1=Monday..7=Sunday), got ` +
              `${Number.isNaN(weekday) ? "no usable value" : weekday}. The tool description ` +
              `states this is confirmed by a session probe at first query, so refusing is the ` +
              `only honest outcome — returning weekday numbers that mean something else would ` +
              `be wrong by one day in exactly the direction the Fabric tool's numbering ` +
              `produces.`,
            { service: "athena-sql" },
          );
        }
      })().catch((err) => {
        // A failed probe must be retried on the next call, not cached forever —
        // a throttled STS exchange or a cold Athena queue is a normal transient.
        this.dialectContract = undefined;
        throw err;
      });
    }
    return this.dialectContract;
  }

  async query(sql: string): Promise<LakehouseQueryResult> {
    // The same gate every backend runs, in Trino mode: single statement,
    // SELECT/WITH only, no UNLOAD/CALL/session-state verbs — checked before
    // the engine (or the credential exchange) is ever touched.
    const statement = assertReadOnlySingleStatement(sql, "trino");

    await this.ensureDialectContract();
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
      throw new AdapterError("upstream", `Athena query failed: ${message}${this.exchangeHint(message)}`, {
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
    // The contract belongs to the executor that observed it, not to the object:
    // a new executor is a new session and must re-prove it.
    this.dialectContract = undefined;
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

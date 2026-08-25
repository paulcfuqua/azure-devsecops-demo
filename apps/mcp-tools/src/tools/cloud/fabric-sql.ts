/**
 * `query_lakehouse_sql` — CLOUD adapter: the Microsoft Fabric lakehouse **SQL
 * analytics endpoint**.
 *
 * Transport is TDS over TCP 1433 to `<guid>.datawarehouse.fabric.microsoft.com`,
 * not HTTP — Fabric offers no REST query surface for a lakehouse, so this is the
 * one adapter in the set that is not a `fetch` call. The TDS work therefore sits
 * behind `TdsExecutor`, a two-method seam the unit tests implement directly;
 * everything that makes this adapter *correct* — the dialect gate, the session
 * contract, truncation, value normalisation — lives above the seam and is tested
 * without a driver, a socket or a tenant.
 *
 * ── Auth (hard rule 5) ───────────────────────────────────────────────────────
 * Entra access token from `DefaultAzureCredential`, scope
 * `https://database.windows.net/.default`. SQL authentication is not supported by
 * Fabric at all, which is convenient: there is no password-shaped hole to leave
 * open. The token is passed to the driver as
 * `authentication: { type: "azure-active-directory-access-token" }` and is never
 * logged; the connection is described in errors by FQDN + database only.
 *
 * NOTE for the tenant runbook: a service principal's first Fabric API call is
 * what materialises its Fabric token — "Service principals can use Fabric APIs"
 * must be on in the tenant settings, and the identity needs at least Viewer on
 * the workspace plus read on the lakehouse.
 *
 * ── The 500-row cap ──────────────────────────────────────────────────────────
 * `SET ROWCOUNT` is on Fabric's *unsupported* T-SQL surface-area list, and
 * wrapping the agent's statement in `SELECT TOP (501) * FROM (…) q` is not
 * sound either — a derived table may not carry `ORDER BY` without `TOP`, so the
 * wrap would reject exactly the ranking queries the golden questions ask. The
 * cap is therefore applied by **reading at most 501 rows off the TDS stream and
 * cancelling**, which yields byte-identical `{rows, rowCount, truncated}`
 * semantics to the local sql.js adapter (truncated ⟺ a 501st row existed) and
 * never transfers the tail of a runaway SELECT.
 */
import {
  assertReadOnlySingleStatement,
  MAX_RESULT_ROWS,
  TSQL_SATURDAY_WEEKDAY,
  TSQL_SESSION_PROLOGUE,
  type SqlDialect,
} from "../sql-dialect.js";
import { AdapterError, isAdapterError } from "../errors.js";
import { SCOPES, type TokenProvider } from "../auth.js";
import type { LakehouseQueryResult } from "../../data/lakehouse.js";
import type { LakehouseSqlBackend } from "../backends.js";

/** One result set off the wire: column names in order, rows as positional arrays. */
export interface TdsQueryResult {
  columns: string[];
  rows: unknown[][];
}

/**
 * The TDS seam. One method to run a batch, one to release the pool.
 *
 * `maxRows` is a hard read limit, not a hint: the implementation must stop
 * consuming (and cancel the request) once it has that many rows. The adapter
 * asks for MAX_RESULT_ROWS + 1 so it can tell "exactly 500" from "more than 500".
 */
export interface TdsExecutor {
  execute(batch: string, maxRows: number): Promise<TdsQueryResult>;
  close(): Promise<void>;
}

export interface FabricLakehouseOptions {
  /** e.g. `abcd1234-….datawarehouse.fabric.microsoft.com` */
  sqlEndpoint: string;
  /** The lakehouse (or warehouse) item name, used as the initial catalog. */
  database: string;
  tokens: TokenProvider;
  /** Injected by tests; the default lazily builds an `mssql` pool. */
  executor?: TdsExecutor;
  /** Connection timeout in ms for the driver. */
  connectTimeoutMs?: number;
}

/**
 * The session contract this adapter guarantees to the agent.
 *
 * `2026-08-22` is Track A's master seed date and a **Saturday**, which makes it a
 * one-value assertion of the whole day-of-week story: under the pinned
 * `SET DATEFIRST 7`, `DATEPART(weekday, '2026-08-22')` must be 7. If the
 * endpoint ignored the pin (Microsoft's docs are contradictory about whether
 * `SET DATEFIRST` is in the SQL-analytics-endpoint surface area — it is absent
 * from the unsupported list but the reference page carries no Fabric badge), the
 * probe fails loudly at first query instead of the agent silently reading a
 * Monday-based numbering out of a tool description that promised Sunday-based.
 */
export const SESSION_PROBE_DATE = "2026-08-22";
export const SESSION_PROBE_SQL =
  `SELECT @@DATEFIRST AS datefirst, ` +
  `DATEPART(weekday, CAST('${SESSION_PROBE_DATE}' AS date)) AS seed_date_weekday`;

/**
 * Normalise a TDS value to what the LOCAL adapter would have produced for the
 * same cell, so the two backends are interchangeable to the agent and to the
 * eval's fact walker.
 *
 * The one that matters: a Delta `DATE` column arrives as `date` and tedious
 * hands it to Node as a **JS Date**. `JSON.stringify` would render that as
 * `"2026-08-22T00:00:00.000Z"`, while sql.js returns the CSV text `"2026-08-22"`.
 * `get_cost_series` advertises `date (ISO YYYY-MM-DD)` in its own description, so
 * this is a contract difference, not a cosmetic one.
 */
export function normalizeTdsValue(value: unknown): unknown {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) {
    const iso = value.toISOString();
    // Midnight UTC means a `date` column, not a `datetime2` instant.
    return iso.endsWith("T00:00:00.000Z") ? iso.slice(0, 10) : iso;
  }
  if (typeof value === "bigint") {
    // Counts fit; anything past 2^53 keeps full precision as text rather than
    // silently rounding in JSON.
    return value <= BigInt(Number.MAX_SAFE_INTEGER) && value >= BigInt(Number.MIN_SAFE_INTEGER)
      ? Number(value)
      : value.toString();
  }
  if (value instanceof Uint8Array) return Buffer.from(value).toString("base64");
  return value;
}

export class FabricLakehouseSqlBackend implements LakehouseSqlBackend {
  readonly dialect: SqlDialect = "tsql";
  readonly sqlEndpoint: string;
  readonly database: string;

  private readonly tokens: TokenProvider;
  private readonly connectTimeoutMs: number;
  private executor: TdsExecutor | undefined;
  private sessionContract: Promise<void> | undefined;

  constructor(options: FabricLakehouseOptions) {
    this.sqlEndpoint = options.sqlEndpoint;
    this.database = options.database;
    this.tokens = options.tokens;
    this.connectTimeoutMs = options.connectTimeoutMs ?? 30_000;
    this.executor = options.executor;
  }

  /** Human-safe description of where we are pointed. Never a connection string. */
  get target(): string {
    return `${this.sqlEndpoint}/${this.database}`;
  }

  private async getExecutor(): Promise<TdsExecutor> {
    if (!this.executor) {
      this.executor = await createMssqlExecutor({
        sqlEndpoint: this.sqlEndpoint,
        database: this.database,
        tokens: this.tokens,
        connectTimeoutMs: this.connectTimeoutMs,
      });
    }
    return this.executor;
  }

  /**
   * Run once per process: prove the endpoint honoured `SET DATEFIRST 7`, so the
   * "1=Sunday .. 7=Saturday" the tool description promises is a verified fact
   * rather than an assumption about the login's default language.
   */
  private async ensureSessionContract(): Promise<void> {
    if (!this.sessionContract) {
      this.sessionContract = (async () => {
        const executor = await this.getExecutor();
        const probe = await executor.execute(TSQL_SESSION_PROLOGUE + SESSION_PROBE_SQL, 2);
        const row = probe.rows[0] ?? [];
        const index = (name: string) => probe.columns.findIndex((c) => c.toLowerCase() === name);
        const datefirst = Number(row[index("datefirst")]);
        const weekday = Number(row[index("seed_date_weekday")]);
        if (datefirst !== 7 || weekday !== TSQL_SATURDAY_WEEKDAY) {
          throw new AdapterError(
            "config",
            `The Fabric SQL analytics endpoint did not honour the pinned session settings: ` +
              `expected @@DATEFIRST=7 and DATEPART(weekday, '${SESSION_PROBE_DATE}')=` +
              `${TSQL_SATURDAY_WEEKDAY} (a Saturday), got @@DATEFIRST=${datefirst} and ` +
              `weekday=${weekday}. The day-of-week numbering advertised in this tool's ` +
              `description cannot be guaranteed against this endpoint; refusing rather than ` +
              `returning weekdays that mean something else.`,
            { service: "fabric-sql" },
          );
        }
      })().catch((err) => {
        // A failed probe must be retried on the next call, not cached forever —
        // a cold Fabric capacity is a normal transient at demo time.
        this.sessionContract = undefined;
        throw err;
      });
    }
    return this.sessionContract;
  }

  async query(sql: string): Promise<LakehouseQueryResult> {
    // The SAME gate the local adapter runs, in T-SQL mode: single statement,
    // SELECT/WITH only, no DDL/DML, plus the T-SQL extras (SET/EXEC/sp_/xp_/
    // OPENROWSET) that a TDS batch would otherwise happily execute.
    const statement = assertReadOnlySingleStatement(sql, "tsql");

    await this.ensureSessionContract();
    const executor = await this.getExecutor();

    let result: TdsQueryResult;
    try {
      result = await executor.execute(
        TSQL_SESSION_PROLOGUE + statement,
        MAX_RESULT_ROWS + 1,
      );
    } catch (err) {
      if (isAdapterError(err)) throw err;
      // A T-SQL syntax/name error is the agent's to fix, and the server's own
      // message is the most useful thing it can be given ("Invalid object name
      // 'strftime'" is precisely the SQLite-habit failure this port exists to
      // prevent). Classified bad_request so the agent reformulates rather than
      // waits and retries.
      const message = err instanceof Error ? err.message : String(err);
      throw new AdapterError("bad_request", `Fabric SQL rejected the query: ${message}`, {
        service: "fabric-sql",
        cause: err,
      });
    }

    const truncated = result.rows.length > MAX_RESULT_ROWS;
    const rows = (truncated ? result.rows.slice(0, MAX_RESULT_ROWS) : result.rows).map((row) =>
      row.map(normalizeTdsValue),
    );
    return { columns: result.columns, rows, rowCount: rows.length, truncated };
  }

  async close(): Promise<void> {
    await this.executor?.close();
    this.executor = undefined;
    this.sessionContract = undefined;
  }
}

/* ------------------------------------------------------------------ */
/* The default executor: mssql (tedious) over TDS                      */
/* ------------------------------------------------------------------ */

interface MssqlExecutorOptions {
  sqlEndpoint: string;
  database: string;
  tokens: TokenProvider;
  connectTimeoutMs: number;
}

/**
 * Lazily build an `mssql` connection pool bound to a managed-identity token.
 *
 * Imported dynamically for the same reason `@azure/identity` is: the local
 * backend must not load a TDS driver. `MultipleActiveResultSets` is deliberately
 * absent — Fabric does not support MARS and including it breaks the connection.
 */
export async function createMssqlExecutor(options: MssqlExecutorOptions): Promise<TdsExecutor> {
  let mssql: any;
  try {
    mssql = await import("mssql");
  } catch (err) {
    throw new AdapterError(
      "config",
      "MLS_TOOL_BACKENDS=cloud requires the `mssql` package to reach the Fabric SQL " +
        "analytics endpoint (TDS). Run `npm install` in apps/mcp-tools — it is a declared " +
        "dependency that the local backend never loads.",
      { service: "fabric-sql", cause: err },
    );
  }
  const sql = mssql.default ?? mssql;

  let pool: any;
  const connect = async (): Promise<any> => {
    if (pool?.connected) return pool;
    const token = await options.tokens.getToken(SCOPES.sql);
    pool = await new sql.ConnectionPool({
      server: options.sqlEndpoint,
      port: 1433,
      database: options.database,
      authentication: {
        type: "azure-active-directory-access-token",
        options: { token },
      },
      options: {
        encrypt: true,
        trustServerCertificate: false,
        enableArithAbort: true,
        // Fabric does not support MARS; the driver default is false and it is
        // named here so nobody "helpfully" turns it on later.
        multipleActiveResultSets: false,
      },
      connectionTimeout: options.connectTimeoutMs,
      requestTimeout: options.connectTimeoutMs,
      pool: { max: 4, min: 0, idleTimeoutMillis: 30_000 },
    }).connect();
    return pool;
  };

  return {
    async execute(batch: string, maxRows: number): Promise<TdsQueryResult> {
      const connected = await connect();
      return new Promise<TdsQueryResult>((resolve, reject) => {
        const request = new sql.Request(connected);
        request.stream = true;
        // Positional rows + column metadata, matching sql.js's shape exactly.
        request.arrayRowMode = true;

        let columns: string[] = [];
        const rows: unknown[][] = [];
        let settled = false;

        const finish = (err?: Error): void => {
          if (settled) return;
          settled = true;
          if (err) reject(err);
          else resolve({ columns, rows });
        };

        request.on("recordset", (meta: any) => {
          // With arrayRowMode the recordset event carries an ordered column array.
          columns = Array.isArray(meta)
            ? meta.map((c: any, i: number) => String(c?.name ?? `column${i + 1}`))
            : Object.keys(meta ?? {});
        });
        request.on("row", (row: unknown[]) => {
          if (rows.length >= maxRows) {
            // Read limit reached: stop the server mid-stream rather than pull
            // the tail of a runaway SELECT across the wire.
            try {
              request.cancel();
            } catch {
              /* cancel is best-effort; the finish() below still settles */
            }
            finish();
            return;
          }
          rows.push(row);
        });
        request.on("error", (err: Error) => {
          // A cancel after the read limit surfaces as an error on some drivers;
          // if we already have our rows, that is success, not failure.
          if (rows.length >= maxRows) finish();
          else finish(err);
        });
        request.on("done", () => finish());

        request.query(batch);
      });
    },
    async close(): Promise<void> {
      if (pool?.connected) await pool.close();
      pool = undefined;
    },
  };
}

/**
 * T-SQL access for both SQL-shaped upstreams: Azure SQL (operational tables)
 * and the Fabric lakehouse SQL analytics endpoint (analytical tables). Same
 * TDS protocol, same Entra audience, same driver — only the host, the database
 * and which tables live there differ, so one client class serves both.
 *
 * Statement construction lives here and nowhere else, and it never sees a
 * caller string. `buildSelect` takes an allowlist literal, looks the object
 * name and column list up in frozen constants, bracket-quotes every identifier,
 * and parameterises the only value in the statement (`TOP (@limit)`). The
 * identifiers are additionally shape-checked at module load, so a typo in
 * `allowlist.ts` fails at boot instead of producing a malformed statement.
 */
import type { TableName, TableStore } from "../contract/allowlist.js";
import { TABLE_FIELDS, TABLE_NAMES, TABLE_ORDER_BY } from "../contract/allowlist.js";
import { ApiError } from "../errors.js";
import { SCOPE_SQL, type TokenProvider } from "./azureAuth.js";

/* ------------------------------------------------------------------ */
/* statement construction                                              */
/* ------------------------------------------------------------------ */

/** Schema every table lands in, in both stores. */
const SCHEMA = "dbo";

const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

function quote(identifier: string): string {
  if (!IDENTIFIER.test(identifier)) {
    // Unreachable from a request: everything passed here is a repo constant.
    // Reachable from a bad edit, which is exactly when you want a hard stop.
    throw new Error(
      `Refusing to build SQL: ${JSON.stringify(identifier)} is not a bare identifier.`,
    );
  }
  return `[${identifier}]`;
}

// Fail at import time rather than at first query if a constant is malformed.
for (const table of TABLE_NAMES) {
  quote(table);
  quote(TABLE_ORDER_BY[table]);
  for (const field of TABLE_FIELDS[table]) quote(field.name);
}

/**
 * `SELECT TOP (@limit) <fixed columns> FROM [dbo].[<literal>] ORDER BY <pk>`.
 *
 * The explicit column list is not stylistic: it pins the projection to the
 * contract, so a column added to the table by a later migration cannot appear
 * in a browser payload.
 */
export function buildSelect(table: TableName): string {
  const columns = TABLE_FIELDS[table].map((field) => quote(field.name)).join(", ");
  return (
    `SELECT TOP (@limit) ${columns} ` +
    `FROM ${quote(SCHEMA)}.${quote(table)} ` +
    `ORDER BY ${quote(TABLE_ORDER_BY[table])} ASC`
  );
}

/* ------------------------------------------------------------------ */
/* client                                                              */
/* ------------------------------------------------------------------ */

export interface SqlClient {
  /** Run a statement built by `buildSelect`, with the row cap as a parameter. */
  select(table: TableName, limit: number): Promise<Record<string, unknown>[]>;
  close(): Promise<void>;
}

/* Minimal structural view of the `mssql` surface this file uses. Written out
 * rather than imported so the driver's own typings (which model a much larger
 * API) cannot drift this file, and so tests can substitute a fake. */
interface MssqlRequest {
  input(name: string, value: unknown): MssqlRequest;
  query<T>(statement: string): Promise<{ recordset: T[] }>;
}

interface MssqlPool {
  connect(): Promise<MssqlPool>;
  close(): Promise<void>;
  request(): MssqlRequest;
  on(event: string, listener: (...args: unknown[]) => void): unknown;
}

interface MssqlModule {
  ConnectionPool: new (config: Record<string, unknown>) => MssqlPool;
}

export interface SqlEndpoint {
  /** Which store this client is: used in error text and span attributes. */
  readonly store: TableStore;
  /** Server FQDN. */
  readonly server: string;
  readonly database: string;
  readonly timeoutMs: number;
}

/**
 * Pools are rebuilt when the access token they were opened with is close to
 * expiry. Azure SQL terminates a session at token expiry, so a long-lived pool
 * with a stale token fails mid-query; rebuilding on our own schedule turns
 * that into a cheap reconnect at a moment of our choosing.
 */
const POOL_LIFETIME_MS = 45 * 60 * 1000;

export class MssqlClient implements SqlClient {
  private pool: MssqlPool | undefined;
  private poolExpiresAt = 0;
  private opening: Promise<MssqlPool> | undefined;

  constructor(
    private readonly endpoint: SqlEndpoint,
    private readonly tokens: TokenProvider,
    /** Test seam: injected in unit tests so no driver and no socket is used. */
    private readonly loadDriver: () => Promise<MssqlModule> = defaultDriver,
  ) {}

  async select(table: TableName, limit: number): Promise<Record<string, unknown>[]> {
    const pool = await this.getPool();
    const statement = buildSelect(table);
    try {
      const result = await pool
        .request()
        .input("limit", limit)
        .query<Record<string, unknown>>(statement);
      return result.recordset;
    } catch (err) {
      // Drop the pool: a failure here is usually an expired token or a dropped
      // socket, and the next request should not inherit a poisoned pool.
      void this.discard();
      throw ApiError.upstream(this.label(), err);
    }
  }

  async close(): Promise<void> {
    await this.discard();
  }

  private label(): string {
    return this.endpoint.store === "sql"
      ? "Azure SQL"
      : "Fabric lakehouse SQL analytics endpoint";
  }

  private async getPool(): Promise<MssqlPool> {
    const now = Date.now();
    if (this.pool && this.poolExpiresAt > now) return this.pool;
    if (this.opening) return this.opening;

    this.opening = this.openPool()
      .then((pool) => {
        this.pool = pool;
        this.poolExpiresAt = Date.now() + POOL_LIFETIME_MS;
        return pool;
      })
      .finally(() => {
        this.opening = undefined;
      });
    return this.opening;
  }

  private async openPool(): Promise<MssqlPool> {
    await this.discard();

    const token = await this.tokens.getToken(SCOPE_SQL);
    const driver = await this.loadDriver();

    const pool = new driver.ConnectionPool({
      server: this.endpoint.server,
      database: this.endpoint.database,
      // Entra access token from the managed identity. No user, no password,
      // no connection string — there is nothing here to leak or rotate.
      authentication: {
        type: "azure-active-directory-access-token",
        options: { token },
      },
      options: {
        encrypt: true,
        trustServerCertificate: false,
        // Serverless Azure SQL auto-pauses; the first query after a pause pays
        // a resume. Fabric's endpoint has a comparable cold path.
        connectTimeout: this.endpoint.timeoutMs,
        requestTimeout: this.endpoint.timeoutMs,
      },
      pool: { max: 4, min: 0, idleTimeoutMillis: 30_000 },
    });

    // An unhandled 'error' on a pool takes the process down; this API prefers
    // to answer 502 and keep serving the routes that still work.
    pool.on("error", () => {
      void this.discard();
    });

    try {
      return await pool.connect();
    } catch (err) {
      throw ApiError.upstream(this.label(), err);
    }
  }

  private async discard(): Promise<void> {
    const pool = this.pool;
    this.pool = undefined;
    this.poolExpiresAt = 0;
    if (!pool) return;
    try {
      await pool.close();
    } catch {
      // Closing an already-broken pool is best-effort by definition.
    }
  }
}

async function defaultDriver(): Promise<MssqlModule> {
  // Dynamic so LOCAL mode never loads a TDS driver — the tests, and any
  // laptop run, keep the module graph small and socket-free.
  const loaded = (await import("mssql")) as unknown as
    | MssqlModule
    | { default: MssqlModule };
  return "ConnectionPool" in loaded ? loaded : loaded.default;
}

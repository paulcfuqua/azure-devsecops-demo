/**
 * `query_lakehouse_sql` cloud adapter — the Fabric SQL analytics endpoint.
 *
 * The Fabric endpoint speaks TDS, not HTTP, so the seam under test is
 * `TdsExecutor` rather than `fetch`. Everything that makes the adapter correct
 * sits above that seam — the dialect gate, the pinned session, the 500-row cap,
 * the value normalisation — and is asserted here with no driver, no socket and
 * no tenant, exactly as the other four adapters are asserted with no network.
 */
import { describe, expect, it } from "vitest";
import {
  FabricLakehouseSqlBackend,
  normalizeTdsValue,
  SESSION_PROBE_DATE,
  type TdsExecutor,
  type TdsQueryResult,
} from "../src/tools/cloud/fabric-sql.js";
import { MAX_RESULT_ROWS, TSQL_SESSION_PROLOGUE } from "../src/tools/sql-dialect.js";
import { TokenProvider } from "../src/tools/auth.js";
import { AdapterError } from "../src/tools/errors.js";
import { rejection } from "./helpers/rejection.js";

/** A credential that hands back a fixed, obviously-fake token. */
const fakeTokens = (): TokenProvider =>
  new TokenProvider({
    async getToken() {
      return {
        token: "fake-token-never-used-by-the-executor",
        expiresOnTimestamp: Date.now() + 3_600_000,
      };
    },
  });

interface RecordedBatch {
  batch: string;
  maxRows: number;
}

/**
 * A scripted TDS executor. The session probe is recognised by its CONTENT, not
 * by call order — a failed probe is retried, so "the first call" and "the probe"
 * are not the same thing.
 */
function fakeExecutor(
  responses: Array<TdsQueryResult | Error>,
  probe?: TdsQueryResult | Error,
): { executor: TdsExecutor; batches: RecordedBatch[]; closed: () => boolean } {
  const batches: RecordedBatch[] = [];
  let isClosed = false;
  const executor: TdsExecutor = {
    async execute(batch, maxRows) {
      batches.push({ batch, maxRows });
      if (batch.includes("@@DATEFIRST")) {
        const answer = probe ?? {
          columns: ["datefirst", "seed_date_weekday"],
          rows: [[7, 7]],
        };
        if (answer instanceof Error) throw answer;
        return answer;
      }
      const next = responses.shift();
      if (next === undefined) throw new Error("fakeExecutor: no scripted response left");
      if (next instanceof Error) throw next;
      return next;
    },
    async close() {
      isClosed = true;
    },
  };
  return { executor, batches, closed: () => isClosed };
}

function makeBackend(
  responses: Array<TdsQueryResult | Error>,
  probe?: TdsQueryResult | Error,
): { backend: FabricLakehouseSqlBackend; batches: RecordedBatch[]; closed: () => boolean } {
  const { executor, batches, closed } = fakeExecutor(responses, probe);
  const backend = new FabricLakehouseSqlBackend({
    sqlEndpoint: "abc123.datawarehouse.fabric.microsoft.com",
    database: "mls_operations",
    tokens: fakeTokens(),
    executor,
  });
  return { backend, batches, closed };
}

describe("FabricLakehouseSqlBackend — dialect and session contract", () => {
  it("declares the T-SQL dialect, which is what drives the tool description", () => {
    const { backend } = makeBackend([]);
    expect(backend.dialect).toBe("tsql");
  });

  it("pins DATEFIRST in the prologue of every batch it sends", async () => {
    const { backend, batches } = makeBackend([
      { columns: ["n"], rows: [[1200]] },
      { columns: ["n"], rows: [[1200]] },
    ]);
    await backend.query("SELECT COUNT(*) AS n FROM launches");
    await backend.query("SELECT COUNT(*) AS n FROM launches");

    // batches[0] is the probe; 1 and 2 are the queries. All three carry the pin,
    // because a pooled connection may be a different session each time.
    expect(batches).toHaveLength(3);
    for (const { batch } of batches) {
      expect(batch.startsWith(TSQL_SESSION_PROLOGUE)).toBe(true);
      expect(batch).toContain("SET DATEFIRST 7;");
    }
  });

  it("probes the endpoint once, and the probe asserts Saturday == 7", async () => {
    const { backend, batches } = makeBackend([
      { columns: ["n"], rows: [[1]] },
      { columns: ["n"], rows: [[2]] },
    ]);
    await backend.query("SELECT 1 AS n");
    await backend.query("SELECT 2 AS n");

    expect(batches[0]?.batch).toContain("@@DATEFIRST");
    expect(batches[0]?.batch).toContain(SESSION_PROBE_DATE);
    expect(batches[0]?.batch).toContain("DATEPART(weekday");
    // Probed once, not once per query.
    expect(batches.filter((b) => b.batch.includes("@@DATEFIRST"))).toHaveLength(1);
  });

  it("refuses to serve if the endpoint ignored the DATEFIRST pin", async () => {
    // DATEFIRST 1 (Monday-first) would silently shift every weekday answer by
    // one — the canonical golden question would report Sunday, confidently.
    const { backend } = makeBackend([], {
      columns: ["datefirst", "seed_date_weekday"],
      rows: [[1, 6]],
    });
    await expect(backend.query("SELECT 1")).rejects.toThrow(/did not honour the pinned session/i);
    await expect(backend.query("SELECT 1")).rejects.toThrow(/@@DATEFIRST=1/);
  });

  it("retries the probe on the next call rather than caching a failure forever", async () => {
    const { executor, batches } = fakeExecutor([{ columns: ["n"], rows: [[1]] }]);
    let probeCalls = 0;
    const flaky: TdsExecutor = {
      async execute(batch, maxRows) {
        if (batch.includes("@@DATEFIRST")) {
          probeCalls += 1;
          if (probeCalls === 1) throw new Error("capacity is resuming");
          return { columns: ["datefirst", "seed_date_weekday"], rows: [[7, 7]] };
        }
        return executor.execute(batch, maxRows);
      },
      close: executor.close,
    };
    const backend = new FabricLakehouseSqlBackend({
      sqlEndpoint: "abc.datawarehouse.fabric.microsoft.com",
      database: "mls_operations",
      tokens: fakeTokens(),
      executor: flaky,
    });

    await expect(backend.query("SELECT 1 AS n")).rejects.toThrow();
    // A cold Fabric capacity is a normal transient at demo time; the second
    // attempt must actually try again.
    await expect(backend.query("SELECT 1 AS n")).resolves.toBeDefined();
    expect(probeCalls).toBe(2);
    expect(batches.length).toBeGreaterThan(0);
  });
});

describe("FabricLakehouseSqlBackend — the SELECT-only gate under T-SQL", () => {
  it("refuses DDL/DML before any batch reaches the endpoint", async () => {
    const { backend, batches } = makeBackend([]);
    await expect(backend.query("DROP TABLE launches")).rejects.toThrow(/read-only/i);
    await expect(backend.query("DELETE FROM launches")).rejects.toThrow(/read-only/i);
    // Nothing was sent — not even the session probe.
    expect(batches).toHaveLength(0);
  });

  it("refuses a second statement, which a TDS batch would otherwise execute", async () => {
    const { backend, batches } = makeBackend([]);
    await expect(
      backend.query("SELECT COUNT(*) FROM launches; DROP TABLE launches"),
    ).rejects.toThrow(/single SQL statement/i);
    expect(batches).toHaveLength(0);
  });

  it("refuses EXEC / sp_ / OPENROWSET, which SQLite never had to worry about", async () => {
    const { backend } = makeBackend([]);
    await expect(backend.query("SELECT 1 EXEC sp_who")).rejects.toThrow(/read-only/i);
    await expect(backend.query("SELECT * FROM OPENROWSET('a','b','c')")).rejects.toThrow(
      /read-only/i,
    );
  });

  it("accepts the T-SQL idioms the description advertises", async () => {
    const { backend, batches } = makeBackend([
      { columns: ["weekday", "launches"], rows: [[7, 309]] },
    ]);
    const sql =
      "SELECT TOP (7) DATEPART(weekday, actual_date) AS weekday, COUNT(*) AS launches " +
      "FROM launches GROUP BY DATEPART(weekday, actual_date) ORDER BY launches DESC";
    const result = await backend.query(sql);
    expect(result.rows[0]).toEqual([7, 309]);
    expect(batches[1]?.batch).toContain("DATEPART(weekday, actual_date)");
  });
});

describe("FabricLakehouseSqlBackend — the 500-row cap", () => {
  it("asks the executor for exactly one row more than the cap", async () => {
    const { backend, batches } = makeBackend([{ columns: ["id"], rows: [] }]);
    await backend.query("SELECT launch_id AS id FROM launches");
    expect(batches[1]?.maxRows).toBe(MAX_RESULT_ROWS + 1);
  });

  it("truncated is false at exactly the cap and true one row past it", async () => {
    const rowsAtCap = Array.from({ length: MAX_RESULT_ROWS }, (_, i) => [i]);
    const atCap = makeBackend([{ columns: ["n"], rows: rowsAtCap }]);
    const exact = await atCap.backend.query("SELECT n FROM t");
    expect(exact.rowCount).toBe(MAX_RESULT_ROWS);
    expect(exact.truncated).toBe(false);

    const overCap = makeBackend([{ columns: ["n"], rows: [...rowsAtCap, [MAX_RESULT_ROWS]] }]);
    const capped = await overCap.backend.query("SELECT n FROM t");
    expect(capped.rows).toHaveLength(MAX_RESULT_ROWS);
    expect(capped.rowCount).toBe(MAX_RESULT_ROWS);
    expect(capped.truncated).toBe(true);
  });

  it("does not use SET ROWCOUNT, which Fabric does not support", async () => {
    const { backend, batches } = makeBackend([{ columns: ["n"], rows: [[1]] }]);
    await backend.query("SELECT 1 AS n");
    for (const { batch } of batches) expect(batch).not.toMatch(/SET\s+ROWCOUNT/i);
  });
});

describe("normalizeTdsValue — keeping cell values interchangeable with SQLite's", () => {
  it("renders a DATE column as YYYY-MM-DD, not as an ISO instant", () => {
    // tedious hands `date` columns to Node as a JS Date; JSON.stringify would
    // emit 2026-08-22T00:00:00.000Z where sql.js emits 2026-08-22, and
    // get_cost_series' own description promises the latter.
    expect(normalizeTdsValue(new Date("2026-08-22T00:00:00.000Z"))).toBe("2026-08-22");
  });

  it("keeps the time on an actual timestamp", () => {
    expect(normalizeTdsValue(new Date("2026-08-22T14:02:11.503Z"))).toBe(
      "2026-08-22T14:02:11.503Z",
    );
  });

  it("passes strings, numbers and booleans through untouched", () => {
    expect(normalizeTdsValue("Falcon 9 Block 5")).toBe("Falcon 9 Block 5");
    expect(normalizeTdsValue(1200)).toBe(1200);
    expect(normalizeTdsValue(93.6)).toBe(93.6);
    expect(normalizeTdsValue(true)).toBe(true);
  });

  it("maps undefined to null, matching sql.js's empty-cell handling", () => {
    expect(normalizeTdsValue(null)).toBeNull();
    expect(normalizeTdsValue(undefined)).toBeNull();
  });

  it("narrows a safe bigint to a number and keeps an unsafe one exact as text", () => {
    expect(normalizeTdsValue(1200n)).toBe(1200);
    expect(normalizeTdsValue(90071992547409910n)).toBe("90071992547409910");
  });

  it("base64s binary rather than emitting a byte-array object", () => {
    expect(normalizeTdsValue(new Uint8Array([1, 2, 3]))).toBe("AQID");
  });

  it("is applied to every cell of every returned row", async () => {
    const { backend } = makeBackend([
      {
        columns: ["date", "cost_center", "amount_usd"],
        rows: [[new Date("2026-01-31T00:00:00.000Z"), "Propulsion", 1234.5]],
      },
    ]);
    const result = await backend.query("SELECT date, cost_center, amount_usd FROM cost_daily");
    expect(result.rows[0]).toEqual(["2026-01-31", "Propulsion", 1234.5]);
  });
});

describe("FabricLakehouseSqlBackend — error surface", () => {
  it("maps a server-side SQL error to bad_request so the agent reformulates", async () => {
    const { backend } = makeBackend([new Error("Invalid object name 'strftime'.")]);
    const failure = await rejection<AdapterError>(
      backend.query("SELECT strftime('%w', actual_date) FROM launches"),
    );
    expect(failure).toBeInstanceOf(AdapterError);
    expect(failure.kind).toBe("bad_request");
    // The server's own message is the most useful thing the agent can be given.
    expect(failure.message).toContain("Invalid object name 'strftime'");
    expect(failure.retryable).toBe(false);
  });

  it("never leaks a token or a connection string into an error", async () => {
    const { backend } = makeBackend([
      new Error(
        "Login failed. Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payloadpayloadpayload.sig " +
          "Server=tcp:abc.datawarehouse.fabric.microsoft.com;Password=hunter2hunter2;",
      ),
    ]);
    const failure = await rejection<AdapterError>(backend.query("SELECT 1"));
    expect(failure.message).not.toContain("hunter2hunter2");
    expect(failure.message).not.toContain("eyJhbGciOiJIUzI1NiJ9");
    expect(failure.message).toContain("[redacted]");
  });

  it("exposes its target as FQDN/database, never as a connection string", () => {
    const { backend } = makeBackend([]);
    expect(backend.target).toBe("abc123.datawarehouse.fabric.microsoft.com/mls_operations");
    expect(backend.target).not.toMatch(/password|token|=/i);
  });

  it("close() releases the executor and forgets the session contract", async () => {
    const { backend, closed } = makeBackend([{ columns: ["n"], rows: [[1]] }]);
    await backend.query("SELECT 1 AS n");
    await backend.close();
    expect(closed()).toBe(true);
  });
});

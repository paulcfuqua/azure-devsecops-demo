import { describe, it, expect } from "vitest";
import { AthenaLakehouseSqlBackend, type AthenaExecutor } from "../src/tools/cloud/athena-sql.js";
import {
  TRINO_SATURDAY_WEEKDAY,
  TRINO_SESSION_PROBE_DATE,
  TRINO_SESSION_PROBE_SQL,
} from "../src/tools/sql-dialect.js";

const fakeTokens = { getToken: async () => "fake.jwt.token" } as never;

const OPTIONS = {
  roleArn: "arn:aws:iam::1:role/r",
  audience: "api://a",
  region: "us-east-1",
  database: "launch",
  workgroup: "wg",
  outputLocation: "s3://r/",
  tokens: fakeTokens,
};

/**
 * A stand-in for an engine that DOES number day_of_week the ISO way — the first
 * statement any backend sends is the dialect probe, not the caller's query, and
 * every test below except the probe's own is about what happens after it passes.
 *
 * This is a fixture of a conforming engine, not a test supplying its own answer:
 * nothing that uses this helper asserts anything about the probe, and the tests
 * that DO assert about it build their executors from scratch, below.
 */
function conformingEngine(answer: AthenaExecutor["run"]): AthenaExecutor {
  return {
    async run(sql, maxRows) {
      if (sql === TRINO_SESSION_PROBE_SQL) {
        return { columns: ["seed_date_weekday"], rows: [[TRINO_SATURDAY_WEEKDAY]] };
      }
      return answer(sql, maxRows);
    },
  };
}

function backendWith(run: AthenaExecutor["run"]) {
  return new AthenaLakehouseSqlBackend({ ...OPTIONS, executor: conformingEngine(run) });
}

/**
 * The rejection, as an Error. `.catch(e => e)` widens to "Error | the resolved
 * value", which typechecks away the very assertions below — and, worse, a query
 * that wrongly SUCCEEDED would sail past them with nothing to say. This fails
 * loudly on a resolution instead.
 */
async function rejection(promise: Promise<unknown>): Promise<Error> {
  return promise.then(
    () => {
      throw new Error("expected the query to reject, but it resolved");
    },
    (err: unknown) => (err instanceof Error ? err : new Error(String(err))),
  );
}

describe("AthenaLakehouseSqlBackend", () => {
  it("declares the trino dialect", () => {
    expect(backendWith(async () => ({ columns: [], rows: [] })).dialect).toBe("trino");
  });

  it("returns the shared result shape", async () => {
    const b = backendWith(async () => ({ columns: ["provider", "n"], rows: [["SpaceX", 42]] }));
    const r = await b.query("SELECT provider, COUNT(*) AS n FROM launches GROUP BY provider");
    expect(r).toEqual({ columns: ["provider", "n"], rows: [["SpaceX", 42]], rowCount: 1, truncated: false });
  });

  // The adapter asks for MAX_RESULT_ROWS + 1 so it can tell "exactly 500" from
  // "more than 500" -- the same trick the TDS adapter uses.
  it("marks truncation when the engine returns one more than the cap", async () => {
    const rows = Array.from({ length: 501 }, (_, i) => [i]);
    const r = await backendWith(async () => ({ columns: ["i"], rows })).query("SELECT i FROM t");
    expect(r.rowCount).toBe(500);
    expect(r.truncated).toBe(true);
    expect(r.rows).toHaveLength(500);
  });

  it("refuses a write statement before reaching the engine", async () => {
    let called = false;
    const b = backendWith(async () => { called = true; return { columns: [], rows: [] }; });
    await expect(b.query("UNLOAD (SELECT 1) TO 's3://x/'")).rejects.toThrow();
    expect(called).toBe(false);
  });

  it("surfaces an engine failure as an upstream AdapterError, not a crash", async () => {
    const b = backendWith(async () => { throw new Error("SYNTAX_ERROR line 1:8"); });
    await expect(b.query("SELECT bogus FROM t")).rejects.toMatchObject({ kind: "upstream" });
  });

  it("times out rather than polling forever", async () => {
    const b = new AthenaLakehouseSqlBackend({
      ...OPTIONS,
      executor: conformingEngine(() => new Promise<never>(() => {})),
      pollTimeoutMs: 20,
    });
    await expect(b.query("SELECT 1")).rejects.toMatchObject({ kind: "timeout" });
  });
});

/**
 * The session probe (Task 9).
 *
 * DIALECTS.trino's idioms paragraph tells the agent that day_of_week "is
 * confirmed against the live endpoint by a session probe at first query". These
 * are the tests that make that sentence true rather than decorative. 2026-08-22
 * is a Saturday, so ISO numbering (1=Monday .. 7=Sunday) must return 6.
 */
describe("the day_of_week session probe", () => {
  it("runs the probe BEFORE the caller's statement, exactly once per backend", async () => {
    const seen: string[] = [];
    const b = new AthenaLakehouseSqlBackend({
      ...OPTIONS,
      executor: {
        async run(sql) {
          seen.push(sql);
          return sql === TRINO_SESSION_PROBE_SQL
            ? { columns: ["seed_date_weekday"], rows: [[6]] }
            : { columns: ["n"], rows: [[1]] };
        },
      },
    });
    await b.query("SELECT 1 AS n");
    await b.query("SELECT 2 AS n");
    expect(seen[0]).toBe(TRINO_SESSION_PROBE_SQL);
    expect(seen.filter((s) => s === TRINO_SESSION_PROBE_SQL)).toHaveLength(1);
    expect(seen).toHaveLength(3);
  });

  it("asks the engine about a date that is genuinely a Saturday", () => {
    // If the seed date moved and the expected number did not, the probe would
    // assert a coincidence. Checked against the calendar, not against the
    // constant that would be wrong with it.
    expect(new Date(`${TRINO_SESSION_PROBE_DATE}T00:00:00Z`).getUTCDay()).toBe(6 /* Saturday */);
    // ...and ISO numbering puts Saturday at 6 as well, Monday being 1.
    expect(TRINO_SATURDAY_WEEKDAY).toBe(6);
  });

  // The whole point: a warning nobody reads would let the agent carry on
  // composing weekday filters against a numbering the description called
  // verified, wrong by exactly one day.
  it.each([7, 5, 0])("REFUSES the query when the engine answers %i, not 6", async (wrong) => {
    let ranCallerSql = false;
    const b = new AthenaLakehouseSqlBackend({
      ...OPTIONS,
      executor: {
        async run(sql) {
          if (sql === TRINO_SESSION_PROBE_SQL) {
            return { columns: ["seed_date_weekday"], rows: [[wrong]] };
          }
          ranCallerSql = true;
          return { columns: ["n"], rows: [[1]] };
        },
      },
    });
    await expect(b.query("SELECT 1 AS n")).rejects.toMatchObject({ kind: "config" });
    expect(ranCallerSql).toBe(false);
  });

  it("names both numbers in the refusal so a reader can act on it", async () => {
    const b = new AthenaLakehouseSqlBackend({
      ...OPTIONS,
      executor: {
        async run() {
          return { columns: ["seed_date_weekday"], rows: [[7]] };
        },
      },
    });
    await expect(b.query("SELECT 1 AS n")).rejects.toThrow(
      new RegExp(`${TRINO_SESSION_PROBE_DATE}[\\s\\S]*got 7`),
    );
  });

  it("refuses when the engine answers with no rows at all", async () => {
    const b = new AthenaLakehouseSqlBackend({
      ...OPTIONS,
      executor: { async run() { return { columns: ["seed_date_weekday"], rows: [] }; } },
    });
    await expect(b.query("SELECT 1 AS n")).rejects.toMatchObject({ kind: "config" });
  });

  // A cold queue or a throttled STS exchange is a normal transient at demo time.
  // Caching the failure would turn one bad minute into a dead tool.
  it("retries the probe on the next call rather than caching a failure", async () => {
    let attempt = 0;
    const b = new AthenaLakehouseSqlBackend({
      ...OPTIONS,
      executor: {
        async run(sql) {
          if (sql === TRINO_SESSION_PROBE_SQL) {
            attempt += 1;
            if (attempt === 1) throw new Error("ThrottlingException");
            return { columns: ["seed_date_weekday"], rows: [[6]] };
          }
          return { columns: ["n"], rows: [[1]] };
        },
      },
    });
    await expect(b.query("SELECT 1 AS n")).rejects.toThrow();
    await expect(b.query("SELECT 1 AS n")).resolves.toMatchObject({ rowCount: 1 });
    expect(attempt).toBe(2);
  });

  it("re-proves the contract after close(), because a new executor is a new session", async () => {
    let probes = 0;
    const b = new AthenaLakehouseSqlBackend({
      ...OPTIONS,
      executor: {
        async run(sql) {
          if (sql === TRINO_SESSION_PROBE_SQL) {
            probes += 1;
            return { columns: ["seed_date_weekday"], rows: [[6]] };
          }
          return { columns: ["n"], rows: [[1]] };
        },
      },
    });
    await b.query("SELECT 1 AS n");
    await b.close();
    // close() drops the injected executor too, so give it one back — the
    // assertion is that the CONTRACT was dropped with it.
    (b as unknown as { executor: AthenaExecutor }).executor = {
      async run(sql) {
        if (sql === TRINO_SESSION_PROBE_SQL) {
          probes += 1;
          return { columns: ["seed_date_weekday"], rows: [[6]] };
        }
        return { columns: ["n"], rows: [[1]] };
      },
    };
    await b.query("SELECT 1 AS n");
    expect(probes).toBe(2);
  });

  // An STS AccessDenied names neither the identity nor the audience it refused.
  // The adapter says which three values it used, because the failure LOOKS like
  // a trust-policy problem when it is an Azure credential-selection one.
  it("names the identity, audience and role when the credential exchange is refused", async () => {
    const b = new AthenaLakehouseSqlBackend({
      ...OPTIONS,
      identityClientId: "11111111-1111-1111-1111-111111111111",
      executor: {
        async run() {
          throw new Error("AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity");
        },
      },
    });
    const err = await rejection(b.query("SELECT 1 AS n"));
    expect(err.message).toContain("11111111-1111-1111-1111-111111111111");
    expect(err.message).toContain("api://a");
    expect(err.message).toContain("arn:aws:iam::1:role/r");
  });

  it("does not bolt a credential hint onto an ordinary SQL error", async () => {
    const b = backendWith(async () => {
      throw new Error("SYNTAX_ERROR line 1:8: Column 'bogus' cannot be resolved");
    });
    const err = await rejection(b.query("SELECT bogus FROM t"));
    expect(err.message).toContain("SYNTAX_ERROR");
    expect(err.message).not.toContain("managed identity client id");
    expect(err.message).not.toContain("arn:aws:iam::1:role/r");
  });
});

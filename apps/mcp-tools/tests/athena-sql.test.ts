import { describe, it, expect } from "vitest";
import { AthenaLakehouseSqlBackend, type AthenaExecutor } from "../src/tools/cloud/athena-sql.js";

const fakeTokens = { getToken: async () => "fake.jwt.token" } as never;

function backendWith(executor: AthenaExecutor) {
  return new AthenaLakehouseSqlBackend({
    executor, roleArn: "arn:aws:iam::1:role/r", audience: "api://a", region: "us-east-1",
    database: "launch", workgroup: "wg", outputLocation: "s3://r/", tokens: fakeTokens,
  });
}

describe("AthenaLakehouseSqlBackend", () => {
  it("declares the trino dialect", () => {
    expect(backendWith({ run: async () => ({ columns: [], rows: [] }) }).dialect).toBe("trino");
  });

  it("returns the shared result shape", async () => {
    const b = backendWith({
      run: async () => ({ columns: ["provider", "n"], rows: [["SpaceX", 42]] }),
    });
    const r = await b.query("SELECT provider, COUNT(*) AS n FROM launches GROUP BY provider");
    expect(r).toEqual({ columns: ["provider", "n"], rows: [["SpaceX", 42]], rowCount: 1, truncated: false });
  });

  // The adapter asks for MAX_RESULT_ROWS + 1 so it can tell "exactly 500" from
  // "more than 500" -- the same trick the TDS adapter uses.
  it("marks truncation when the engine returns one more than the cap", async () => {
    const rows = Array.from({ length: 501 }, (_, i) => [i]);
    const r = await backendWith({ run: async () => ({ columns: ["i"], rows }) })
      .query("SELECT i FROM t");
    expect(r.rowCount).toBe(500);
    expect(r.truncated).toBe(true);
    expect(r.rows).toHaveLength(500);
  });

  it("refuses a write statement before reaching the engine", async () => {
    let called = false;
    const b = backendWith({ run: async () => { called = true; return { columns: [], rows: [] }; } });
    await expect(b.query("UNLOAD (SELECT 1) TO 's3://x/'")).rejects.toThrow();
    expect(called).toBe(false);
  });

  it("surfaces an engine failure as an upstream AdapterError, not a crash", async () => {
    const b = backendWith({ run: async () => { throw new Error("SYNTAX_ERROR line 1:8"); } });
    await expect(b.query("SELECT bogus FROM t")).rejects.toMatchObject({ kind: "upstream" });
  });

  it("times out rather than polling forever", async () => {
    const b = new AthenaLakehouseSqlBackend({
      executor: { run: () => new Promise(() => {}) },
      roleArn: "arn:aws:iam::1:role/r", audience: "api://a", region: "us-east-1",
      database: "launch", workgroup: "wg", outputLocation: "s3://r/", tokens: fakeTokens,
      pollTimeoutMs: 20,
    });
    await expect(b.query("SELECT 1")).rejects.toMatchObject({ kind: "timeout" });
  });
});

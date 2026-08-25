/**
 * The SQLite-vs-T-SQL dialect port, and the read-only gate that both dialects
 * share.
 *
 * The bug this file exists to keep fixed: the committed tool description told
 * the agent to write `strftime('%w', actual_date)` for day of week and
 * `strftime('%Y-%m', date)` for month bucketing. Neither function exists in
 * T-SQL, so on the day `MLS_TOOL_BACKENDS=cloud` was switched on, every date
 * question — including the canonical golden one, "which day of the week has the
 * most launches" — would have failed with `Invalid object name 'strftime'`.
 * The fix is that the dialect is a property of the active backend and the
 * description is generated from it; these tests assert that the generated text
 * and the accepted grammar stay in step.
 */
import { describe, expect, it } from "vitest";
import {
  assertReadOnlySingleStatement,
  DIALECTS,
  MAX_RESULT_ROWS,
  scrubSql,
  SqlRejected,
  SQLITE_SATURDAY_WEEKDAY,
  TSQL_SATURDAY_WEEKDAY,
  TSQL_SESSION_PROLOGUE,
} from "../src/tools/sql-dialect.js";
import { buildToolDefinitions, ToolRegistry } from "../src/tools/index.js";
import { createLocalBackends } from "../src/tools/backends.js";
import { SESSION_PROBE_DATE } from "../src/tools/cloud/fabric-sql.js";

function lakehouseDescription(dialect: "sqlite" | "tsql"): string {
  const tool = buildToolDefinitions(dialect).find((t) => t.name === "query_lakehouse_sql");
  return tool?.description ?? "";
}

describe("the advertised dialect follows the active backend", () => {
  it("advertises SQLite idioms in sqlite mode and never mentions T-SQL ones", () => {
    const description = lakehouseDescription("sqlite");
    expect(description).toContain("SQLite dialect");
    expect(description).toContain("strftime('%w', actual_date)");
    expect(description).toContain("strftime('%Y-%m', date)");
    expect(description).toContain("LIMIT n");
    expect(description).not.toContain("DATEPART");
    expect(description).not.toContain("DATEFIRST");
  });

  it("advertises T-SQL idioms in tsql mode and never mentions strftime", () => {
    const description = lakehouseDescription("tsql");
    expect(description).toContain("T-SQL");
    expect(description).toContain("Fabric");
    // The whole point: the agent must not be told to use a function the engine
    // does not have.
    expect(description).not.toContain("strftime(");
    expect(description).toContain("DATEPART(weekday, actual_date)");
    expect(description).toContain("SELECT TOP (n)");
    // …and it must be told that its SQLite habits will not work here.
    expect(description).toContain("strftime, LIMIT and || do not exist here");
  });

  it("states the DATEFIRST pin and the resulting numbering as a guarantee", () => {
    const description = lakehouseDescription("tsql");
    expect(description).toContain("SET DATEFIRST 7");
    expect(description).toContain("1=Sunday");
    expect(description).toContain("7=Saturday");
    expect(description).toContain("regardless of server language");
  });

  it("offers a month-bucketing idiom that exists in each dialect", () => {
    expect(lakehouseDescription("sqlite")).toContain("strftime('%Y-%m', date)");
    const tsql = lakehouseDescription("tsql");
    expect(tsql).toContain("FORMAT(date, 'yyyy-MM')");
    // CONVERT is offered alongside FORMAT because FORMAT is CLR-backed and the
    // slower of the two on a columnar engine; both are valid T-SQL.
    expect(tsql).toContain("CONVERT(char(7), date, 126)");
  });

  it("keeps every dialect-independent promise identical across dialects", () => {
    for (const description of [lakehouseDescription("sqlite"), lakehouseDescription("tsql")]) {
      expect(description).toContain("Exactly one SELECT or WITH statement is accepted");
      expect(description).toContain("INSERT, UPDATE, DELETE and DDL are refused");
      expect(description).toContain(`capped at ${MAX_RESULT_ROWS} rows`);
      // The full table/column schema is the agent's only source for it.
      expect(description).toContain("launches(launch_id");
      expect(description).toContain("findings_history(finding_id");
    }
  });

  it("the four non-SQL tool descriptions are byte-identical across dialects", () => {
    const sqlite = buildToolDefinitions("sqlite").filter((t) => t.name !== "query_lakehouse_sql");
    const tsql = buildToolDefinitions("tsql").filter((t) => t.name !== "query_lakehouse_sql");
    expect(tsql).toEqual(sqlite);
  });

  it("the registry takes its dialect from the backend it is bound to", () => {
    const registry = new ToolRegistry(createLocalBackends());
    expect(registry.dialect).toBe("sqlite");
    expect(registry.definitions.find((t) => t.name === "query_lakehouse_sql")?.description)
      .toContain("strftime");
  });

  it("both dialects still advertise exactly the five allowlisted tools", () => {
    for (const dialect of ["sqlite", "tsql"] as const) {
      const names = buildToolDefinitions(dialect).map((t) => t.name).sort();
      expect(names).toEqual([
        "get_cost_series",
        "get_defender_posture",
        "get_github_security",
        "query_lakehouse_sql",
        "query_log_analytics",
      ]);
    }
  });
});

describe("day-of-week semantics are correct in both dialects", () => {
  it("SQLite: strftime('%w') numbers Saturday 6, and the local eval relies on it", () => {
    expect(SQLITE_SATURDAY_WEEKDAY).toBe("6");
    expect(DIALECTS.sqlite.idioms).toContain("0=Sunday .. 6=Saturday");
  });

  it("T-SQL: with DATEFIRST 7 pinned, DATEPART(weekday) numbers Saturday 7", () => {
    expect(TSQL_SATURDAY_WEEKDAY).toBe(7);
    expect(DIALECTS.tsql.idioms).toContain("1=Sunday, 2=Monday .. 7=Saturday");
  });

  it("pins DATEFIRST in the session prologue rather than trusting the server default", () => {
    // DATEPART(weekday, …) is relative to DATEFIRST, which defaults from the
    // LOGIN'S LANGUAGE. Left unpinned, the numbering the description promises
    // would be a property of whoever's identity connected.
    expect(TSQL_SESSION_PROLOGUE).toContain("SET DATEFIRST 7;");
    expect(TSQL_SESSION_PROLOGUE).toContain("SET NOCOUNT ON;");
  });

  it("the probe date really is a Saturday, so the connect-time check is meaningful", () => {
    // The pin is VERIFIED, not assumed: the adapter asks the endpoint what
    // DATEPART(weekday, <this date>) is and refuses to serve if it is not 7.
    const day = new Date(`${SESSION_PROBE_DATE}T00:00:00Z`).getUTCDay();
    expect(day).toBe(6); // JS: 0=Sunday .. 6=Saturday
  });

  it("an agent cannot unpin DATEFIRST from inside its own statement", () => {
    expect(() =>
      assertReadOnlySingleStatement("SELECT DATEPART(weekday, actual_date) FROM launches", "tsql"),
    ).not.toThrow();
    // SET is refused in T-SQL mode precisely so the pinned numbering holds.
    expect(() =>
      assertReadOnlySingleStatement("SET DATEFIRST 1 SELECT 1", "tsql"),
    ).toThrow(SqlRejected);
  });
});

describe("the read-only gate — one implementation, both dialects", () => {
  const READ_ONLY = [
    "SELECT COUNT(*) FROM launches",
    "  select 1  ",
    "WITH x AS (SELECT 1 AS n) SELECT n FROM x",
    "SELECT COUNT(*) FROM launches;",
    "SELECT COUNT(*) FROM launches;   \n  ",
    "-- a leading comment\nSELECT 1",
    "/* block */ SELECT 1",
  ];

  for (const dialect of ["sqlite", "tsql"] as const) {
    describe(dialect, () => {
      it("accepts single read-only statements", () => {
        for (const sql of READ_ONLY) {
          expect(() => assertReadOnlySingleStatement(sql, dialect)).not.toThrow();
        }
      });

      it("strips the trailing semicolon from what it returns", () => {
        expect(assertReadOnlySingleStatement("SELECT 1;", dialect)).toBe("SELECT 1");
        expect(assertReadOnlySingleStatement("  SELECT 1 ;  ", dialect)).toBe("SELECT 1");
      });

      it("refuses DDL and DML", () => {
        for (const sql of [
          "DROP TABLE launches",
          "DELETE FROM launches",
          "INSERT INTO launches VALUES (1)",
          "UPDATE launches SET outcome = 'success'",
          "CREATE TABLE t (a int)",
          "ALTER TABLE launches ADD c int",
          "TRUNCATE TABLE launches",
          "MERGE launches USING x ON 1=1",
          "GRANT SELECT ON launches TO public",
        ]) {
          expect(() => assertReadOnlySingleStatement(sql, dialect), sql).toThrow(/read-only/i);
        }
      });

      it("refuses a second statement even when the first is a SELECT", () => {
        // sql.js silently runs only the first statement, so this never showed
        // locally — but a TDS batch runs them all.
        expect(() =>
          assertReadOnlySingleStatement("SELECT 1; DROP TABLE launches", dialect),
        ).toThrow(/single SQL statement/i);
        expect(() =>
          assertReadOnlySingleStatement("SELECT 1; SELECT 2", dialect),
        ).toThrow(/single SQL statement/i);
      });

      it("refuses SELECT … INTO, the write that hides inside a SELECT", () => {
        expect(() =>
          assertReadOnlySingleStatement("SELECT * INTO copy FROM launches", dialect),
        ).toThrow(/read-only/i);
      });

      it("refuses empty and non-string input", () => {
        expect(() => assertReadOnlySingleStatement("", dialect)).toThrow(/non-empty/);
        expect(() => assertReadOnlySingleStatement("   ", dialect)).toThrow(/non-empty/);
        expect(() => assertReadOnlySingleStatement(undefined, dialect)).toThrow(/non-empty/);
        expect(() => assertReadOnlySingleStatement(42, dialect)).toThrow(/non-empty/);
      });

      it("does not false-positive on schema columns that embed keywords", () => {
        // insurance_value_musd contains "insu…", data_dropout_s contains "drop",
        // created/updated contain "create"/"update". Word boundaries must hold.
        expect(() =>
          assertReadOnlySingleStatement(
            "SELECT insurance_value_musd, scrub_count FROM launches",
            dialect,
          ),
        ).not.toThrow();
        expect(() =>
          assertReadOnlySingleStatement("SELECT data_dropout_s FROM telemetry_summary", dialect),
        ).not.toThrow();
      });

      it("does not read keywords out of string literals", () => {
        expect(() =>
          assertReadOnlySingleStatement(
            "SELECT * FROM findings_history WHERE title = 'drop table risk; delete everything'",
            dialect,
          ),
        ).not.toThrow();
      });

      it("does not let a comment smuggle a verb into first position", () => {
        expect(() =>
          assertReadOnlySingleStatement("/* SELECT */ DROP TABLE launches", dialect),
        ).toThrow(/read-only/i);
      });
    });
  }

  it("T-SQL refuses the batch/administrative verbs SQLite has never had", () => {
    for (const sql of [
      "SELECT 1 EXEC sp_who",
      "SELECT * FROM OPENROWSET('x','y','z')",
      "SELECT 1 WAITFOR DELAY '00:00:05'",
      "SELECT 1 DBCC FREEPROCCACHE",
      "USE master SELECT 1",
    ]) {
      expect(() => assertReadOnlySingleStatement(sql, "tsql"), sql).toThrow(/read-only/i);
    }
  });

  it("SQLite refuses the file/schema escapes T-SQL has never had", () => {
    for (const sql of [
      "SELECT 1; PRAGMA table_info(launches)",
      "SELECT load_extension('evil')",
      "ATTACH DATABASE 'x' AS y",
    ]) {
      expect(() => assertReadOnlySingleStatement(sql, "sqlite"), sql).toThrow(SqlRejected);
    }
  });

  it("the refusal message is written for the agent, so it can self-correct", () => {
    try {
      assertReadOnlySingleStatement("DELETE FROM launches", "tsql");
      expect.unreachable("should have thrown");
    } catch (err) {
      const message = (err as Error).message;
      expect(message).toMatch(/read-only/i);
      expect(message).toMatch(/DELETE/);
      expect(message).toMatch(/Rewrite it as a plain SELECT/);
    }
  });
});

describe("scrubSql", () => {
  it("removes line and block comments", () => {
    expect(scrubSql("SELECT 1 -- DROP TABLE t\n")).not.toMatch(/drop/i);
    expect(scrubSql("SELECT /* DROP TABLE t */ 1")).not.toMatch(/drop/i);
  });

  it("handles nested block comments (T-SQL allows them)", () => {
    expect(scrubSql("SELECT /* a /* DROP */ b */ 1")).not.toMatch(/drop/i);
  });

  it("removes string literals, including doubled-quote escapes", () => {
    expect(scrubSql("SELECT 'it''s a DROP' AS x")).not.toMatch(/drop/i);
  });

  it("removes quoted and bracketed identifiers", () => {
    expect(scrubSql('SELECT "DROP" FROM t')).not.toMatch(/drop/i);
    expect(scrubSql("SELECT [DROP] FROM t")).not.toMatch(/drop/i);
  });

  it("preserves structure so token boundaries and semicolons survive", () => {
    expect(scrubSql("SELECT 'a';SELECT 'b'")).toMatch(/;/);
    expect(scrubSql("SELECT a FROM b")).toContain("FROM");
  });
});

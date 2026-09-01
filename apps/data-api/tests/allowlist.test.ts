/**
 * Guardrail 3: the table and feed names are an allowlist, and no caller string
 * ever becomes SQL, a URL, or a file path.
 *
 * The negative cases below are the ones that matter. A 404 for "launches2" is
 * table stakes; a 404 for `..%2f..%2fetc%2fpasswd` and for
 * `launches;DROP TABLE launches--` is the actual guarantee, and it holds
 * because the matched *literal* is what flows onward, never the caller's text.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  FEED_NAMES,
  TABLE_FIELDS,
  TABLE_NAMES,
  TABLE_ORDER_BY,
  TABLE_STORE,
  isAllowedFeed,
  isAllowedTable,
} from "../src/contract/allowlist.js";
import { buildSelect } from "../src/backends/sql.js";
import { startServer, type TestServer } from "./helpers.js";

let server: TestServer;

beforeAll(async () => {
  server = await startServer();
});

afterAll(async () => {
  await server.close();
});

const HOSTILE_NAMES = [
  "launches2",
  "LAUNCHES",
  "launches ",
  "launches;DROP TABLE launches--",
  "launches' OR '1'='1",
  "launches UNION SELECT * FROM sys.tables",
  "../../../etc/passwd",
  "..\\..\\windows\\win.ini",
  "%2e%2e%2fpackage.json",
  "sys.databases",
  "__proto__",
  "constructor",
  "",
  " ",
];

describe("allowlist predicates", () => {
  it("accepts exactly the ten tables", () => {
    expect(TABLE_NAMES).toHaveLength(10);
    for (const name of TABLE_NAMES) expect(isAllowedTable(name)).toBe(true);
  });

  it("accepts exactly the seven feeds", () => {
    // Seven since F117 added azure-cost, the Ops tab's replacement for the
    // lakehouse cost table.
    expect(FEED_NAMES).toHaveLength(7);
    for (const name of FEED_NAMES) expect(isAllowedFeed(name)).toBe(true);
  });

  it.each(HOSTILE_NAMES)("rejects %j as a table", (name) => {
    expect(isAllowedTable(name)).toBe(false);
  });

  it.each(HOSTILE_NAMES)("rejects %j as a feed", (name) => {
    expect(isAllowedFeed(name)).toBe(false);
  });

  it("is not fooled by prototype-chain keys", () => {
    expect(isAllowedTable("toString")).toBe(false);
    expect(isAllowedFeed("hasOwnProperty")).toBe(false);
  });
});

describe("HTTP rejects unknown names without touching a backend", () => {
  it.each(HOSTILE_NAMES.filter((name) => name.trim() !== ""))(
    "GET /tables/%j is a typed 404",
    async (name) => {
      const response = await fetch(
        `${server.baseUrl}/tables/${encodeURIComponent(name)}`,
      );
      expect(response.status).toBe(404);
      const body = (await response.json()) as { error: { code: string; message: string } };
      expect(["unknown_table", "not_found"]).toContain(body.error.code);
      // The refusal must not echo what the caller sent — that would make the
      // endpoint a reflection gadget for whoever is probing it.
      expect(body.error.message).not.toContain(name);
    },
  );

  it.each(HOSTILE_NAMES.filter((name) => name.trim() !== ""))(
    "GET /feeds/%j is a typed 404",
    async (name) => {
      const response = await fetch(`${server.baseUrl}/feeds/${encodeURIComponent(name)}`);
      expect(response.status).toBe(404);
      const body = (await response.json()) as { error: { code: string; message: string } };
      expect(["unknown_feed", "not_found"]).toContain(body.error.code);
      expect(body.error.message).not.toContain(name);
    },
  );

  it("names the served set in the refusal, so the mistake is self-correcting", async () => {
    const response = await fetch(`${server.baseUrl}/tables/launchez`);
    const body = (await response.json()) as { error: { message: string } };
    for (const table of TABLE_NAMES) expect(body.error.message).toContain(table);
  });
});

describe("SQL construction never contains caller input", () => {
  it.each(TABLE_NAMES)("builds a fixed projection for %s", (table) => {
    const statement = buildSelect(table);

    // Parameterised row cap — the only value in the statement.
    expect(statement).toContain("SELECT TOP (@limit)");
    // Every contract column, bracket-quoted, and the table itself.
    for (const field of TABLE_FIELDS[table]) {
      expect(statement).toContain(`[${field.name}]`);
    }
    expect(statement).toContain(`FROM [dbo].[${table}]`);
    expect(statement).toContain(`ORDER BY [${TABLE_ORDER_BY[table]}] ASC`);

    // No literal, no terminator, no comment: nothing that could ever end a
    // statement and begin another.
    expect(statement).not.toContain("'");
    expect(statement).not.toContain(";");
    expect(statement).not.toContain("--");
    expect(statement).not.toContain("/*");
  });

  it("never selects a star", () => {
    for (const table of TABLE_NAMES) {
      expect(buildSelect(table)).not.toContain("*");
    }
  });

  it("projects exactly the contract columns, in order", () => {
    for (const table of TABLE_NAMES) {
      const statement = buildSelect(table);
      const columns = statement
        .slice(statement.indexOf(") ") + 2, statement.indexOf(" FROM "))
        .split(", ");
      expect(columns).toEqual(TABLE_FIELDS[table].map((field) => `[${field.name}]`));
    }
  });

  it("routes every table to exactly one store", () => {
    for (const table of TABLE_NAMES) {
      expect(["sql", "lakehouse"]).toContain(TABLE_STORE[table]);
    }
    // The L7 split the runbook describes: CRUD in SQL, analytics in the lakehouse.
    expect(TABLE_STORE.launches).toBe("sql");
    expect(TABLE_STORE.work_orders).toBe("sql");
    expect(TABLE_STORE.cost_daily).toBe("lakehouse");
    expect(TABLE_STORE.telemetry_summary).toBe("lakehouse");
    expect(TABLE_STORE.findings_history).toBe("lakehouse");
  });
});

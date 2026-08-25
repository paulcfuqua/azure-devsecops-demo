/**
 * Local lakehouse: an in-memory SQLite database (sql.js — pure WebAssembly, so
 * it runs on Windows ARM64 with no native dependencies) loaded from Track A's
 * deterministic generated CSVs (`data/generated/*.csv`, seed 20260822).
 *
 * This is the LOCAL stand-in for the Fabric lakehouse SQL analytics endpoint;
 * the query surface (SQL in, columns+rows out) matches what the Fabric adapter
 * will speak at L8.
 */
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import type { Database, SqlJsStatic } from "sql.js";
import { parseCsvTable } from "./csv.js";
import { generatedDataDir } from "../config.js";

const require = createRequire(import.meta.url);

/** The ten Track A tables. */
export const LAKEHOUSE_TABLES = [
  "launches",
  "scrubs",
  "vehicles",
  "pads",
  "telemetry_summary",
  "parts",
  "suppliers",
  "work_orders",
  "cost_daily",
  "findings_history",
] as const;

export interface LakehouseQueryResult {
  columns: string[];
  rows: unknown[][];
  rowCount: number;
  /** True when the result was cut at MAX_RESULT_ROWS (L8 playbook: cap tool result sizes). */
  truncated: boolean;
}

/** Row cap on tool results — unbounded SELECTs are an L8 latency failure mode. */
export const MAX_RESULT_ROWS = 500;

type ColumnType = "INTEGER" | "REAL" | "TEXT";

const INT_RE = /^-?\d+$/;
const NUM_RE = /^-?\d+(\.\d+)?([eE][+-]?\d+)?$/;

function inferColumnType(values: string[]): ColumnType {
  let sawValue = false;
  let allInt = true;
  let allNum = true;
  for (const v of values) {
    if (v === "") continue;
    sawValue = true;
    if (allInt && !INT_RE.test(v)) allInt = false;
    if (allNum && !NUM_RE.test(v)) {
      allNum = false;
      break;
    }
  }
  if (!sawValue) return "TEXT";
  if (allInt) return "INTEGER";
  if (allNum) return "REAL";
  return "TEXT";
}

function quoteIdent(name: string): string {
  return `"${name.replaceAll('"', '""')}"`;
}

async function initSqlJs(): Promise<SqlJsStatic> {
  // sql.js's CJS entry locates its wasm next to itself; createRequire keeps
  // that working from this ESM module.
  const init = require("sql.js") as (config?: object) => Promise<SqlJsStatic>;
  return init({
    locateFile: (file: string) => require.resolve(`sql.js/dist/${file}`),
  });
}

let dbPromise: Promise<Database> | undefined;

/** Build (once) the in-memory SQLite database from data/generated/*.csv. */
export function getLakehouseDb(): Promise<Database> {
  if (!dbPromise) {
    dbPromise = buildDb();
  }
  return dbPromise;
}

async function buildDb(): Promise<Database> {
  if (!fs.existsSync(generatedDataDir)) {
    throw new Error(
      `Generated data not found at ${generatedDataDir}. ` +
        `Run \`python -m generators build\` from the repo's data/ directory first.`,
    );
  }
  const SQL = await initSqlJs();
  const db = new SQL.Database();
  for (const table of LAKEHOUSE_TABLES) {
    const csvPath = path.join(generatedDataDir, `${table}.csv`);
    if (!fs.existsSync(csvPath)) {
      throw new Error(
        `Missing ${csvPath} — run \`python -m generators build\` from data/ to regenerate.`,
      );
    }
    const { columns, rows } = parseCsvTable(fs.readFileSync(csvPath, "utf-8"));
    const types = columns.map((_, i) => inferColumnType(rows.map((r) => r[i] ?? "")));
    const ddl = `CREATE TABLE ${quoteIdent(table)} (${columns
      .map((c, i) => `${quoteIdent(c)} ${types[i]}`)
      .join(", ")});`;
    db.run(ddl);
    const insert = db.prepare(
      `INSERT INTO ${quoteIdent(table)} VALUES (${columns.map(() => "?").join(", ")});`,
    );
    db.run("BEGIN TRANSACTION;");
    try {
      for (const row of rows) {
        const bound = columns.map((_, i) => {
          const v = row[i] ?? "";
          if (v === "") return null;
          const t = types[i];
          if (t === "INTEGER" || t === "REAL") return Number(v);
          return v;
        });
        insert.run(bound as (string | number | null)[]);
      }
      db.run("COMMIT;");
    } catch (err) {
      db.run("ROLLBACK;");
      throw err;
    } finally {
      insert.free();
    }
  }
  return db;
}

const READ_ONLY_RE = /^\s*(select|with)\b/i;

/**
 * Execute a single read-only SQL statement and return capped columns+rows.
 * Non-SELECT statements are refused — the copilot's lakehouse access is
 * read-only by contract.
 */
export async function queryLakehouse(sql: string): Promise<LakehouseQueryResult> {
  if (typeof sql !== "string" || sql.trim().length === 0) {
    throw new Error("query_lakehouse_sql requires a non-empty 'sql' string");
  }
  if (!READ_ONLY_RE.test(sql)) {
    throw new Error("Only read-only SELECT/WITH statements are allowed");
  }
  const db = await getLakehouseDb();
  const stmt = db.prepare(sql);
  try {
    const columns = stmt.getColumnNames();
    const rows: unknown[][] = [];
    let truncated = false;
    while (stmt.step()) {
      if (rows.length >= MAX_RESULT_ROWS) {
        truncated = true;
        break;
      }
      rows.push(stmt.get() as unknown[]);
    }
    return { columns, rows, rowCount: rows.length, truncated };
  } finally {
    stmt.free();
  }
}

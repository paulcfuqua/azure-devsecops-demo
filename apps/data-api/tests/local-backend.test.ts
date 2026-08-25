/**
 * The LOCAL backend against the real Track A generator output.
 *
 * These are the tests that catch *generator* drift rather than frontend drift:
 * if `python -m generators build` starts emitting a new column, a renamed one,
 * or a null where the contract says there cannot be one, the failure lands
 * here rather than in a browser at demo time.
 *
 * They require `data/generated/` to exist. It is gitignored build output, so
 * CI runs the generators first (see .github/workflows/app-data-api-ci.yml).
 */
import fs from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { LocalFeedsBackend, LocalTablesBackend } from "../src/backends/local.js";
import {
  FEED_FIXTURE,
  FEED_NAMES,
  TABLE_FIELDS,
  TABLE_NAMES,
  type TableName,
} from "../src/contract/allowlist.js";
import { ApiError } from "../src/errors.js";
import {
  controlTowerProviderDir,
  generatedDataDir,
  packageRoot,
  startServer,
  type TestServer,
} from "./helpers.js";

const fixturesDir = path.join(packageRoot, "fixtures");

beforeAll(() => {
  if (!fs.existsSync(generatedDataDir)) {
    throw new Error(
      `data/generated is missing at ${generatedDataDir}. ` +
        "Run `python -m generators build` from the data/ directory first — " +
        "these tests assert against the real deterministic dataset, not a stub.",
    );
  }
});

function readGenerated(table: TableName): Array<Record<string, unknown>> {
  const file = path.join(generatedDataDir, `${table}.json`);
  return JSON.parse(fs.readFileSync(file, "utf-8")) as Array<Record<string, unknown>>;
}

describe("generator output matches the served contract", () => {
  it.each(TABLE_NAMES)("%s columns are exactly the contract's, in order", (table) => {
    const rows = readGenerated(table);
    expect(rows.length).toBeGreaterThan(0);
    const expected = TABLE_FIELDS[table].map((field) => field.name);
    // Every row, not just the first: the generators dirty some fields and a
    // sparse writer could drop a key on a subset of rows.
    for (const row of rows) {
      expect(Object.keys(row)).toEqual(expected);
    }
  });

  it.each(TABLE_NAMES)("%s nulls only appear in nullable columns", (table) => {
    const rows = readGenerated(table);
    const nullable = new Map(
      TABLE_FIELDS[table].map((field) => [field.name, field.nullable]),
    );
    for (const row of rows) {
      for (const [key, value] of Object.entries(row)) {
        if (value === null) {
          expect(nullable.get(key), `${table}.${key} is null in the data`).toBe(true);
        }
      }
    }
  });

  it.each(TABLE_NAMES)("%s date columns are ISO YYYY-MM-DD", (table) => {
    const dateFields = TABLE_FIELDS[table].filter((field) => field.date === true);
    if (dateFields.length === 0) return;
    for (const row of readGenerated(table)) {
      for (const field of dateFields) {
        const value = row[field.name];
        if (value === null) continue;
        expect(value).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      }
    }
  });
});

describe("LocalTablesBackend", () => {
  const backend = new LocalTablesBackend(generatedDataDir);

  it.each(TABLE_NAMES)("serves %s unmodified when it fits under the cap", async (table) => {
    const raw = readGenerated(table);
    const result = await backend.getTable(table, 100_000);
    expect(result.truncated).toBe(false);
    expect(result.rows).toHaveLength(raw.length);
    // Deep equality against the file: normalization must be the identity
    // function for generator JSON, or the two modes serve different bytes.
    expect(result.rows).toEqual(raw);
  });

  it("caps and flags truncation", async () => {
    const result = await backend.getTable("launches", 10);
    expect(result.rows).toHaveLength(10);
    expect(result.truncated).toBe(true);
    // Capping takes a stable prefix, not a random sample.
    expect(result.rows).toEqual(readGenerated("launches").slice(0, 10));
  });

  it("does not truncate when the cap exactly equals the row count", async () => {
    const pads = readGenerated("pads");
    const result = await backend.getTable("pads", pads.length);
    expect(result.truncated).toBe(false);
    expect(result.rows).toHaveLength(pads.length);
  });

  it("reports a missing dataset as a typed 503, naming the fix", async () => {
    const missing = new LocalTablesBackend(path.join(packageRoot, "no-such-dir"));
    await expect(missing.getTable("launches", 10)).rejects.toMatchObject({
      code: "backend_not_configured",
      status: 503,
    });
    await expect(missing.getTable("launches", 10)).rejects.toThrow(/generators build/);
  });

  it("surfaces the same typed error over HTTP", async () => {
    const server: TestServer = await startServer({
      config: {
        ...(await import("../src/config.js")).loadConfig({
          MLS_DATA_BACKENDS: "local",
          MLS_DATA_DIR: path.join(packageRoot, "no-such-dir"),
        } as NodeJS.ProcessEnv),
      },
      log: () => undefined,
    });
    try {
      const response = await fetch(`${server.baseUrl}/tables/launches`);
      expect(response.status).toBe(503);
      const body = (await response.json()) as { error: { code: string } };
      expect(body.error.code).toBe("backend_not_configured");
    } finally {
      await server.close();
    }
  });
});

describe("LocalFeedsBackend", () => {
  const backend = new LocalFeedsBackend(fixturesDir);

  it.each(FEED_NAMES)("serves the %s fixture", async (feed) => {
    const payload = await backend.getFeed(feed);
    expect(payload).toBeDefined();
  });

  it("caches a fixture rather than re-reading it", async () => {
    const first = await backend.getFeed("secure-score");
    const second = await backend.getFeed("secure-score");
    expect(second).toBe(first);
  });

  it("ships fixtures byte-identical to the control tower's own", () => {
    // Local API mode must render exactly what the app's LOCAL_DATA mode
    // renders. Same bytes is the only version of that claim worth making.
    const theirs = path.join(controlTowerProviderDir, "..", "fixtures");
    for (const feed of FEED_NAMES) {
      const ourFile = path.join(fixturesDir, FEED_FIXTURE[feed]);
      const theirFile = path.join(
        theirs,
        FEED_FIXTURE[feed].replace(/\.json$/, ".fixture.json"),
      );
      expect(fs.existsSync(theirFile), `${theirFile} should exist`).toBe(true);
      expect(
        JSON.parse(fs.readFileSync(ourFile, "utf-8")),
        `${FEED_FIXTURE[feed]} drifted from the control tower's fixture`,
      ).toEqual(JSON.parse(fs.readFileSync(theirFile, "utf-8")));
    }
  });

  it("reports an unreadable fixture as an internal error, not a crash", async () => {
    const broken = new LocalFeedsBackend(path.join(packageRoot, "no-such-dir"));
    await expect(broken.getFeed("secure-score")).rejects.toBeInstanceOf(ApiError);
  });
});

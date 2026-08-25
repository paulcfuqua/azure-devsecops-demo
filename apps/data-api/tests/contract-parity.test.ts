/**
 * Contract parity with both frontends' `ApiProvider`.
 *
 * This is the test that matters. `apps/launch-ops` and `apps/control-tower`
 * each contain an `ApiProvider` that `fetch`es this service and casts the JSON
 * straight to a declared type. TypeScript checks nothing across that boundary:
 * a cast is a promise, and a promise made in one package about another
 * package's HTTP response is exactly the promise that rots.
 *
 * Four locks, applied together:
 *
 *   1. ROUTES   — every path either provider fetches is re-derived from the
 *                 provider source at test time and requested for real.
 *   2. TYPES    — every row/feed interface this service claims to copy is
 *                 re-extracted from the provider source and compared verbatim.
 *   3. FIELDS   — the copied interfaces are compared against the field specs
 *                 that drive the SQL projection and the runtime validator, so
 *                 `rows.ts` and `allowlist.ts` cannot drift from each other.
 *   4. PAYLOADS — the bytes actually served are validated against those specs,
 *                 including the top-level array/object distinction each
 *                 provider depends on.
 *
 * Chain the four and you get the property that is otherwise untestable without
 * a browser: what this service serves is what those two apps can consume.
 */
import path from "node:path";
import { describe, expect, it, beforeAll, afterAll } from "vitest";
import {
  FEED_NAMES,
  TABLE_FIELDS,
  TABLE_NAMES,
  type FieldSpec,
  type TableName,
} from "../src/contract/allowlist.js";
import {
  controlTowerProviderDir,
  launchOpsProviderDir,
  packageRoot,
  readProviderSource,
  startServer,
  type TestServer,
} from "./helpers.js";
import {
  extractControlTowerPaths,
  extractInterfaces,
  extractLaunchOpsPaths,
  topLevelFields,
} from "./tsSource.js";

/* ------------------------------------------------------------------ */
/* sources under comparison                                            */
/* ------------------------------------------------------------------ */

const launchOpsTypes = readProviderSource(launchOpsProviderDir, "types.ts");
const launchOpsApi = readProviderSource(launchOpsProviderDir, "ApiProvider.ts");
const controlTowerTypes = readProviderSource(controlTowerProviderDir, "types.ts");
const controlTowerApi = readProviderSource(controlTowerProviderDir, "ApiProvider.ts");

const contractDir = path.join(packageRoot, "src", "contract");
const dataApiRows = readProviderSource(contractDir, "rows.ts");
const dataApiFeeds = readProviderSource(contractDir, "feeds.ts");

const launchOpsInterfaces = extractInterfaces(launchOpsTypes);
const controlTowerInterfaces = extractInterfaces(controlTowerTypes);
const ourRowInterfaces = extractInterfaces(dataApiRows);
const ourFeedInterfaces = extractInterfaces(dataApiFeeds);

/** Which of our copies came from where, and which table each row type serves. */
const ROW_COPIES: ReadonlyArray<[name: string, from: "launch-ops" | "control-tower", table: TableName]> = [
  ["LaunchRow", "launch-ops", "launches"],
  ["ScrubRow", "launch-ops", "scrubs"],
  ["VehicleRow", "launch-ops", "vehicles"],
  ["PadRow", "launch-ops", "pads"],
  ["CostDailyRow", "control-tower", "cost_daily"],
  ["TelemetrySummaryRow", "control-tower", "telemetry_summary"],
];

const FEED_COPIES: readonly string[] = [
  "WorkflowRunsFeed",
  "WorkflowRun",
  "CodeScanningAlert",
  "DependabotAlert",
  "SecureScoreResponse",
  "SecureScoreControlsResponse",
  "LogAnalyticsResult",
];

let server: TestServer;

beforeAll(async () => {
  server = await startServer();
});

afterAll(async () => {
  await server.close();
});

async function get(path: string): Promise<{ status: number; body: unknown; headers: Headers }> {
  const response = await fetch(`${server.baseUrl}/${path}`);
  return {
    status: response.status,
    headers: response.headers,
    body: response.status === 204 ? null : await response.json(),
  };
}

/* ------------------------------------------------------------------ */
/* 1. ROUTES                                                           */
/* ------------------------------------------------------------------ */

describe("route parity — every path either ApiProvider fetches is served", () => {
  it("derives the launch-ops paths from its ApiProvider source", () => {
    const paths = extractLaunchOpsPaths(launchOpsApi);
    // If this ever reads 0, the regex stopped matching the provider and every
    // assertion below would vacuously pass. Pin the count.
    expect(paths.length).toBeGreaterThanOrEqual(4);
    expect([...new Set(paths.map((p) => p.path))].sort()).toEqual([
      "tables/launches",
      "tables/pads",
      "tables/scrubs",
      "tables/vehicles",
    ]);
  });

  it("derives the control-tower paths from its ApiProvider source", () => {
    const paths = extractControlTowerPaths(controlTowerApi);
    expect(paths.length).toBeGreaterThanOrEqual(8);
    expect([...new Set(paths.map((p) => p.path))].sort()).toEqual([
      "feeds/app-requests",
      "feeds/code-scanning-alerts",
      "feeds/dependabot-alerts",
      "feeds/secure-score",
      "feeds/secure-score-controls",
      "feeds/workflow-runs",
      "tables/cost_daily",
      "tables/telemetry_summary",
    ]);
  });

  it("builds request URLs the way both providers do (`${baseUrl}/…`)", () => {
    // The providers concatenate baseUrl with the path; a leading slash or a
    // changed segment here would break every call, so assert the templates.
    expect(launchOpsApi).toContain("`${this.baseUrl}/tables/${table}`");
    expect(controlTowerApi).toContain("`${this.baseUrl}/${path}`");
  });

  it("answers 200 on every launch-ops path", async () => {
    for (const { path } of extractLaunchOpsPaths(launchOpsApi)) {
      const response = await get(path);
      expect(response.status, `${path} must be served`).toBe(200);
      // launch-ops' provider throws unless the body is a JSON array.
      expect(Array.isArray(response.body), `${path} must be a JSON array`).toBe(true);
    }
  });

  it("answers 200 on every control-tower path", async () => {
    for (const { path } of extractControlTowerPaths(controlTowerApi)) {
      const response = await get(path);
      expect(response.status, `${path} must be served`).toBe(200);
      expect(response.body, `${path} must have a JSON body`).not.toBeNull();
    }
  });

  it("serves the allowlists as supersets of what the providers ask for", () => {
    const asked = new Set([
      ...extractLaunchOpsPaths(launchOpsApi).map((p) => p.path.replace("tables/", "")),
      ...extractControlTowerPaths(controlTowerApi)
        .filter((p) => p.path.startsWith("tables/"))
        .map((p) => p.path.replace("tables/", "")),
    ]);
    for (const table of asked) {
      expect(TABLE_NAMES as readonly string[]).toContain(table);
    }
    const feedsAsked = extractControlTowerPaths(controlTowerApi)
      .filter((p) => p.path.startsWith("feeds/"))
      .map((p) => p.path.replace("feeds/", ""));
    expect(feedsAsked.length).toBe(6);
    for (const feed of feedsAsked) {
      expect(FEED_NAMES as readonly string[]).toContain(feed);
    }
  });
});

/* ------------------------------------------------------------------ */
/* 2. TYPES                                                            */
/* ------------------------------------------------------------------ */

describe("type parity — our copies are verbatim", () => {
  it("extracted the provider interfaces at all", () => {
    // Guards against a silently-empty extraction making everything pass.
    expect(launchOpsInterfaces.size).toBeGreaterThanOrEqual(5);
    expect(controlTowerInterfaces.size).toBeGreaterThanOrEqual(10);
    expect(ourRowInterfaces.size).toBeGreaterThanOrEqual(10);
    expect(ourFeedInterfaces.size).toBeGreaterThanOrEqual(7);
  });

  it.each(ROW_COPIES)("%s matches the %s declaration verbatim", (name, from) => {
    const source = from === "launch-ops" ? launchOpsInterfaces : controlTowerInterfaces;
    const theirs = source.get(name);
    const ours = ourRowInterfaces.get(name);
    expect(theirs, `${name} is no longer declared in the ${from} provider types`).toBeDefined();
    expect(ours, `${name} is missing from src/contract/rows.ts`).toBeDefined();
    expect(
      ours,
      `${name} drifted. The frontend is the authority — copy it into src/contract/rows.ts.`,
    ).toBe(theirs);
  });

  it.each(FEED_COPIES)("%s matches the control-tower declaration verbatim", (name) => {
    const theirs = controlTowerInterfaces.get(name);
    const ours = ourFeedInterfaces.get(name);
    expect(theirs, `${name} is no longer declared in the control-tower provider types`).toBeDefined();
    expect(ours, `${name} is missing from src/contract/feeds.ts`).toBeDefined();
    expect(
      ours,
      `${name} drifted. The frontend is the authority — copy it into src/contract/feeds.ts.`,
    ).toBe(theirs);
  });
});

/* ------------------------------------------------------------------ */
/* 3. FIELDS                                                           */
/* ------------------------------------------------------------------ */

/** `string` -> string/non-null, `number|null` -> number/nullable, etc. */
function specFromDeclaredType(type: string): { type: FieldSpec["type"]; nullable: boolean } {
  const parts = type.split("|");
  const nullable = parts.includes("null");
  const base = parts.filter((part) => part !== "null" && part !== "undefined");
  expect(base, `unsupported declared type: ${type}`).toHaveLength(1);
  const only = base[0] as string;
  expect(["string", "number", "boolean"], `unsupported declared type: ${type}`).toContain(only);
  return { type: only as FieldSpec["type"], nullable };
}

describe("field parity — the copied types drive the projection", () => {
  it.each(ROW_COPIES)(
    "%s field names, order and nullability match the field spec (from %s, table %s)",
    (name, _from, table) => {
      const declared = topLevelFields(ourRowInterfaces.get(name) as string);
      const specs = TABLE_FIELDS[table];

      expect(declared.map((field) => field.name)).toEqual(specs.map((spec) => spec.name));

      declared.forEach((field, index) => {
        const spec = specs[index] as FieldSpec;
        const expected = specFromDeclaredType(field.type);
        expect({ name: field.name, ...expected }).toEqual({
          name: spec.name,
          type: spec.type,
          nullable: spec.nullable,
        });
      });
    },
  );

  it("every allowlisted table has a field spec and a stable order key", () => {
    for (const table of TABLE_NAMES) {
      expect(TABLE_FIELDS[table].length).toBeGreaterThan(0);
      const names = TABLE_FIELDS[table].map((spec) => spec.name);
      expect(new Set(names).size, `${table} has duplicate columns`).toBe(names.length);
    }
  });
});

/* ------------------------------------------------------------------ */
/* 4. PAYLOADS                                                         */
/* ------------------------------------------------------------------ */

function assertRowMatchesSpec(table: TableName, row: unknown, index: number): void {
  expect(typeof row, `${table}[${index}] must be an object`).toBe("object");
  const record = row as Record<string, unknown>;
  const specs = TABLE_FIELDS[table];

  // Exactly the contract's keys: no extras (a column added upstream must not
  // reach a browser) and none missing (the frontend would read undefined).
  expect(Object.keys(record).sort()).toEqual(specs.map((spec) => spec.name).sort());

  for (const spec of specs) {
    const value = record[spec.name];
    if (value === null) {
      expect(spec.nullable, `${table}[${index}].${spec.name} is null but not nullable`).toBe(true);
      continue;
    }
    expect(typeof value, `${table}[${index}].${spec.name}`).toBe(spec.type);
    if (spec.date === true) {
      expect(value, `${table}[${index}].${spec.name} must be an ISO date`).toMatch(
        /^\d{4}-\d{2}-\d{2}$/,
      );
    }
  }
}

describe("payload parity — served bytes match the declared row types", () => {
  const consumed: TableName[] = [
    "launches",
    "vehicles",
    "pads",
    "scrubs",
    "cost_daily",
    "telemetry_summary",
  ];

  it.each(consumed)("GET /tables/%s serves rows of the declared shape", async (table) => {
    const response = await get(`tables/${table}?limit=50`);
    expect(response.status).toBe(200);
    const rows = response.body as unknown[];
    expect(Array.isArray(rows)).toBe(true);
    expect(rows.length).toBeGreaterThan(0);
    rows.forEach((row, index) => assertRowMatchesSpec(table, row, index));
  });

  it("GET /feeds/workflow-runs matches WorkflowRunsFeed", async () => {
    const { body } = await get("feeds/workflow-runs");
    const feed = body as { total_count: unknown; workflow_runs: unknown };
    expect(typeof feed.total_count).toBe("number");
    expect(Array.isArray(feed.workflow_runs)).toBe(true);
    for (const entry of feed.workflow_runs as Array<Record<string, unknown>>) {
      expect(typeof entry.id).toBe("number");
      expect(typeof entry.name).toBe("string");
      expect(typeof entry.head_branch).toBe("string");
      expect(typeof entry.event).toBe("string");
      expect(typeof entry.status).toBe("string");
      expect(entry.conclusion === null || typeof entry.conclusion === "string").toBe(true);
      expect(typeof entry.run_started_at).toBe("string");
      expect(typeof entry.updated_at).toBe("string");
    }
  });

  it("GET /feeds/code-scanning-alerts matches CodeScanningAlert[]", async () => {
    const { body } = await get("feeds/code-scanning-alerts");
    expect(Array.isArray(body)).toBe(true);
    for (const entry of body as Array<Record<string, unknown>>) {
      expect(typeof entry.number).toBe("number");
      expect(typeof entry.state).toBe("string");
      expect(typeof entry.created_at).toBe("string");
      const rule = entry.rule as Record<string, unknown>;
      expect(typeof rule.id).toBe("string");
      expect(typeof rule.severity).toBe("string");
      expect(typeof rule.description).toBe("string");
      expect(typeof (entry.tool as Record<string, unknown>).name).toBe("string");
    }
  });

  it("GET /feeds/dependabot-alerts matches DependabotAlert[]", async () => {
    const { body } = await get("feeds/dependabot-alerts");
    expect(Array.isArray(body)).toBe(true);
    for (const entry of body as Array<Record<string, unknown>>) {
      expect(typeof entry.number).toBe("number");
      expect(typeof entry.state).toBe("string");
      const pkg = (entry.dependency as { package: Record<string, unknown> }).package;
      expect(typeof pkg.ecosystem).toBe("string");
      expect(typeof pkg.name).toBe("string");
      const advisory = entry.security_advisory as Record<string, unknown>;
      expect(typeof advisory.ghsa_id).toBe("string");
      expect(advisory.cve_id === null || typeof advisory.cve_id === "string").toBe(true);
      expect(typeof advisory.severity).toBe("string");
      expect(typeof advisory.summary).toBe("string");
    }
  });

  it("GET /feeds/secure-score matches SecureScoreResponse", async () => {
    const { body } = await get("feeds/secure-score");
    const value = (body as { value: Array<Record<string, unknown>> }).value;
    expect(Array.isArray(value)).toBe(true);
    expect(value.length).toBeGreaterThan(0);
    for (const entry of value) {
      expect(typeof entry.id).toBe("string");
      expect(typeof entry.name).toBe("string");
      expect(typeof entry.type).toBe("string");
      const properties = entry.properties as Record<string, unknown>;
      expect(typeof properties.displayName).toBe("string");
      const score = properties.score as Record<string, unknown>;
      expect(typeof score.max).toBe("number");
      expect(typeof score.current).toBe("number");
      expect(typeof score.percentage).toBe("number");
    }
  });

  it("GET /feeds/secure-score-controls matches SecureScoreControlsResponse", async () => {
    const { body } = await get("feeds/secure-score-controls");
    const value = (body as { value: Array<Record<string, unknown>> }).value;
    expect(Array.isArray(value)).toBe(true);
    expect(value.length).toBeGreaterThan(0);
    for (const entry of value) {
      expect(typeof entry.name).toBe("string");
      expect(typeof entry.type).toBe("string");
      const properties = entry.properties as Record<string, unknown>;
      expect(typeof properties.displayName).toBe("string");
      expect(typeof properties.healthyResourceCount).toBe("number");
      expect(typeof properties.unhealthyResourceCount).toBe("number");
    }
  });

  it("GET /feeds/app-requests matches LogAnalyticsResult, with the columns the Dev tab reads", async () => {
    const { body } = await get("feeds/app-requests");
    const tables = (body as { tables: Array<Record<string, unknown>> }).tables;
    expect(Array.isArray(tables)).toBe(true);

    // buildDevSpec looks for a table literally named PrimaryResult and three
    // named columns; anything else renders an empty chart with no error.
    const primary = tables.find((table) => table.name === "PrimaryResult");
    expect(primary, "the Dev tab requires a table named PrimaryResult").toBeDefined();
    const columns = (primary as { columns: Array<{ name: string }> }).columns.map(
      (column) => column.name,
    );
    for (const required of ["TimeGenerated", "RequestCount", "FailedCount"]) {
      expect(columns).toContain(required);
    }
    for (const row of (primary as { rows: unknown[][] }).rows) {
      expect(Array.isArray(row)).toBe(true);
      expect(row.length).toBe(columns.length);
    }
  });
});

/**
 * sql.js lakehouse adapter correctness against Track A's deterministic
 * generated data (seed 20260822). Requires data/generated/*.csv — run
 * `python -m generators build` from data/ if absent.
 */
import { describe, expect, it } from "vitest";
import { queryLakehouse, MAX_RESULT_ROWS } from "../src/data/lakehouse.js";
import { LocalCostSeriesBackend } from "../src/tools/backends.js";

describe("query_lakehouse_sql local adapter (sql.js)", () => {
  it("loads all launches: SELECT COUNT(*) FROM launches = 1200", async () => {
    const r = await queryLakehouse("SELECT COUNT(*) FROM launches");
    expect(r.rows[0]?.[0]).toBe(1200);
  });

  it("reproduces the seeded weekday bias: Saturday has the most launches (309)", async () => {
    const r = await queryLakehouse(
      `SELECT CASE strftime('%w', actual_date)
         WHEN '0' THEN 'Sunday' WHEN '1' THEN 'Monday' WHEN '2' THEN 'Tuesday'
         WHEN '3' THEN 'Wednesday' WHEN '4' THEN 'Thursday' WHEN '5' THEN 'Friday'
         ELSE 'Saturday' END AS weekday, COUNT(*) AS n
       FROM launches GROUP BY weekday ORDER BY n DESC, weekday ASC`,
    );
    expect(r.rows[0]).toEqual(["Saturday", 309]);
  });

  it("joins across tables (launches x vehicles) and returns named columns", async () => {
    const r = await queryLakehouse(
      "SELECT v.name, COUNT(*) AS n FROM launches l JOIN vehicles v ON v.vehicle_id = l.vehicle_id GROUP BY v.name ORDER BY n DESC LIMIT 3",
    );
    expect(r.columns).toEqual(["name", "n"]);
    expect(r.rows.length).toBe(3);
    expect(typeof r.rows[0]?.[0]).toBe("string");
    expect(typeof r.rows[0]?.[1]).toBe("number");
  });

  it("treats empty CSV fields as NULL (vehicles.last_flight_year)", async () => {
    const r = await queryLakehouse(
      "SELECT COUNT(*) FROM vehicles WHERE last_flight_year IS NULL",
    );
    expect(Number(r.rows[0]?.[0])).toBeGreaterThan(0);
  });

  it(`caps results at ${MAX_RESULT_ROWS} rows and flags truncation`, async () => {
    const r = await queryLakehouse("SELECT launch_id FROM launches");
    expect(r.rows.length).toBe(MAX_RESULT_ROWS);
    expect(r.truncated).toBe(true);
  });

  it("refuses non-SELECT statements (read-only contract)", async () => {
    await expect(queryLakehouse("DROP TABLE launches")).rejects.toThrow(/read-only/i);
    await expect(queryLakehouse("DELETE FROM launches")).rejects.toThrow(/read-only/i);
    // and the tables are still intact afterwards
    const r = await queryLakehouse("SELECT COUNT(*) FROM launches");
    expect(r.rows[0]?.[0]).toBe(1200);
  });

  it("get_cost_series local adapter reads cost_daily and honors filters", async () => {
    const backend = new LocalCostSeriesBackend();
    const all = await backend.getSeries({});
    expect(all.type).toBe("Microsoft.CostManagement/query");
    expect(all.properties.rows.length).toBeGreaterThan(0);

    const center = String(all.properties.rows[0]?.[1]);
    const filtered = await backend.getSeries({ cost_center: center });
    expect(filtered.properties.rows.length).toBeGreaterThan(0);
    expect(filtered.properties.rows.every((row) => row[1] === center)).toBe(true);

    const window = await backend.getSeries({ start_date: "2024-02-01", end_date: "2024-02-29" });
    expect(
      window.properties.rows.every((row) => row[0] >= "2024-02-01" && row[0] <= "2024-02-29"),
    ).toBe(true);
  });
});

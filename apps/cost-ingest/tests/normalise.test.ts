import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseCsv } from "../src/csv.ts";
import { costCenterSlug, makeCostId, monthOf } from "../src/costDaily.ts";
import {
  CostExportFormatError,
  normaliseExport,
  parseAmount,
  parseExportDate,
  parseTags,
  resolveColumn,
} from "../src/normalise.ts";

const BUDGETS = {
  Propulsion: 8610,
  Avionics: 5670,
  "Range Operations": 4095,
};

function normalise(csv: string, config = {}) {
  return normaliseExport(parseCsv(csv), { costCenterBudgets: BUDGETS, ...config });
}

describe("resolveColumn", () => {
  it("matches case-, space- and underscore-insensitively", () => {
    assert.equal(resolveColumn(["Usage Date", "Cost"], ["usagedate"]), "Usage Date");
    assert.equal(resolveColumn(["usage_date"], ["usagedate"]), "usage_date");
    assert.equal(resolveColumn(["USAGEDATE"], ["usagedate"]), "USAGEDATE");
  });

  it("honours alias order, so a preferred column wins over a present one", () => {
    // costInUSD is listed before costInBillingCurrency for exactly this reason.
    assert.equal(
      resolveColumn(["CostInBillingCurrency", "CostInUsd"], ["costinusd", "costinbillingcurrency"]),
      "CostInUsd",
    );
  });

  it("returns null when no alias is present", () => {
    assert.equal(resolveColumn(["Something"], ["usagedate", "date"]), null);
  });
});

describe("parseExportDate", () => {
  it("accepts ISO, US and compact-integer dates", () => {
    assert.equal(parseExportDate("2026-08-15"), "2026-08-15");
    assert.equal(parseExportDate("08/15/2026"), "2026-08-15");
    assert.equal(parseExportDate("8/5/2026"), "2026-08-05");
    assert.equal(parseExportDate("20260815"), "2026-08-15");
  });

  it("accepts an ISO datetime by taking the date part", () => {
    assert.equal(parseExportDate("2026-08-15T00:00:00Z"), "2026-08-15");
  });

  it("rejects impossible and unrecognised dates rather than guessing", () => {
    for (const bad of ["2026-02-30", "13/40/2026", "20261301", "", "   ", "not a date", "Aug 15 2026"]) {
      assert.equal(parseExportDate(bad), null, `expected null for ${JSON.stringify(bad)}`);
    }
    assert.equal(parseExportDate(undefined), null);
  });
});

describe("parseAmount", () => {
  it("parses plain and scientific notation", () => {
    assert.equal(parseAmount("12.34"), 12.34);
    assert.equal(parseAmount("1.2345E-05"), 1.2345e-5);
    assert.equal(parseAmount("0"), 0);
  });

  it("strips thousands separators and currency symbols", () => {
    assert.equal(parseAmount("1,234.50"), 1234.5);
    assert.equal(parseAmount("$1,234.50"), 1234.5);
    assert.equal(parseAmount("USD 42.00"), 42);
  });

  it("handles both minus-sign and accounting negatives (credits are real)", () => {
    assert.equal(parseAmount("-5.25"), -5.25);
    assert.equal(parseAmount("(5.25)"), -5.25);
    assert.equal(parseAmount("($1,000.00)"), -1000);
  });

  it("returns null — never 0 — for blank or unparseable input", () => {
    for (const bad of ["", "  ", "n/a", "NULL", "1.2.3", "--5", undefined]) {
      assert.equal(parseAmount(bad), null, `expected null for ${JSON.stringify(bad)}`);
    }
  });
});

describe("parseTags", () => {
  it("parses a JSON object", () => {
    assert.deepEqual(parseTags('{"costCenter":"Propulsion","env":"demo"}'), {
      costCenter: "Propulsion",
      env: "demo",
    });
  });

  it("parses the brace-less form Cost Management writes", () => {
    assert.deepEqual(parseTags('"costCenter": "Propulsion","env": "demo"'), {
      costCenter: "Propulsion",
      env: "demo",
    });
  });

  it("parses legacy unquoted key:value pairs", () => {
    assert.deepEqual(parseTags("costCenter:Propulsion;env:demo"), {
      costCenter: "Propulsion",
      env: "demo",
    });
  });

  it("returns an empty object for blank or unusable input", () => {
    assert.deepEqual(parseTags(""), {});
    assert.deepEqual(parseTags(undefined), {});
    assert.deepEqual(parseTags("[1,2,3]"), {});
  });
});

describe("costDaily identity helpers", () => {
  it("slugs a cost centre into an id-safe token", () => {
    assert.equal(costCenterSlug("Range Operations"), "RANGE-OPERATIONS");
    assert.equal(costCenterSlug("Cloud & IT"), "CLOUD-IT");
  });

  it("derives cost_id from the natural key, deterministically", () => {
    assert.equal(makeCostId("2026-08-15", "Range Operations"), "CST-20260815-RANGE-OPERATIONS");
    assert.equal(
      makeCostId("2026-08-15", "Range Operations"),
      makeCostId("2026-08-15", "Range Operations"),
    );
  });

  it("never collides with the generator's sequential id space", () => {
    // Generator ids are CST- plus five digits and carry exactly one hyphen.
    assert.equal(makeCostId("2026-08-15", "Avionics").split("-").length > 2, true);
  });

  it("reduces a date to its billing month", () => {
    assert.equal(monthOf("2026-08-15"), "2026-08");
  });
});

describe("normaliseExport — the six-column cost_daily shape", () => {
  const EA_EXPORT = [
    "UsageDate,ResourceGroup,Cost,Currency,Tags",
    '20260801,mls-rg-platform,"1,234.50",USD,"""costCenter"": ""Propulsion"""',
    '20260801,mls-rg-apps,10.25,USD,"""costCenter"": ""Avionics"""',
    '20260802,mls-rg-platform,5.00,USD,"""costCenter"": ""Propulsion"""',
  ].join("\n");

  it("produces exactly the documented columns, and nothing else", () => {
    const { rows } = normalise(`${EA_EXPORT}\n`);
    assert.deepEqual(Object.keys(rows[0]).sort(), [
      "amount_usd",
      "budget_usd",
      "cost_center",
      "cost_id",
      "currency",
      "date",
    ]);
  });

  it("aggregates the export's per-resource grain into (date, cost_center)", () => {
    const { rows } = normalise(
      [
        "UsageDate,ResourceGroup,Cost,Currency,Tags",
        '20260801,mls-rg-platform,1.10,USD,"""costCenter"": ""Propulsion"""',
        '20260801,mls-rg-data,2.20,USD,"""costCenter"": ""Propulsion"""',
        '20260801,mls-rg-ops,3.30,USD,"""costCenter"": ""Propulsion"""',
        "",
      ].join("\n"),
    );
    assert.equal(rows.length, 1);
    assert.equal(rows[0].amount_usd, 6.6);
  });

  it("orders rows by date then cost centre, so output is byte-stable", () => {
    const { rows } = normalise(`${EA_EXPORT}\n`);
    assert.deepEqual(
      rows.map((row) => `${row.date} ${row.cost_center}`),
      ["2026-08-01 Avionics", "2026-08-01 Propulsion", "2026-08-02 Propulsion"],
    );
  });

  it("attaches the configured daily budget, and null when none is configured", () => {
    const { rows } = normalise(
      [
        "UsageDate,Cost,Currency,Tags",
        '20260801,1.00,USD,"""costCenter"": ""Propulsion"""',
        '20260801,2.00,USD,"""costCenter"": ""Facilities"""',
        "",
      ].join("\n"),
    );
    const byCenter = Object.fromEntries(rows.map((row) => [row.cost_center, row.budget_usd]));
    assert.equal(byCenter.Propulsion, 8610);
    assert.equal(byCenter.Facilities, null);
  });

  it("rounds once at the end, so per-row rounding cannot drift the total", () => {
    const { rows } = normalise(
      [
        "UsageDate,Cost,Tags",
        '20260801,0.005,"""costCenter"": ""Avionics"""',
        '20260801,0.005,"""costCenter"": ""Avionics"""',
        '20260801,0.005,"""costCenter"": ""Avionics"""',
        "",
      ].join("\n"),
    );
    assert.equal(rows[0].amount_usd, 0.02); // 0.015 rounded once, not 3 x 0.01
  });
});

describe("normaliseExport — column sets vary by export version", () => {
  it("reads an MCA-style export (date / costInBillingCurrency / billingCurrency)", () => {
    const { rows, resolvedColumns } = normalise(
      [
        "date,costInBillingCurrency,billingCurrency,tags",
        '2026-08-01,3.50,USD,{"costCenter":"Avionics"}',
        "",
      ].join("\n"),
    );
    assert.equal(resolvedColumns.date, "date");
    assert.equal(resolvedColumns.amount, "costInBillingCurrency");
    assert.equal(rows[0].cost_center, "Avionics");
    assert.equal(rows[0].amount_usd, 3.5);
  });

  it("reads a FOCUS-style export (ChargePeriodStart / BilledCost)", () => {
    const { rows, resolvedColumns } = normalise(
      [
        "ChargePeriodStart,BilledCost,BillingCurrency,Tags",
        '2026-08-03T00:00:00Z,7.75,USD,{"costCenter":"Propulsion"}',
        "",
      ].join("\n"),
    );
    assert.equal(resolvedColumns.date, "ChargePeriodStart");
    assert.equal(resolvedColumns.amount, "BilledCost");
    assert.equal(rows[0].date, "2026-08-03");
  });

  it("prefers a USD column over a billing-currency one when both exist", () => {
    const { rows, resolvedColumns } = normalise(
      [
        "Date,CostInBillingCurrency,CostInUSD,BillingCurrency,Tags",
        '2026-08-01,900.00,10.00,EUR,{"costCenter":"Avionics"}',
        "",
      ].join("\n"),
    );
    assert.equal(resolvedColumns.amount, "CostInUSD");
    assert.equal(rows[0].amount_usd, 10);
  });

  it("defaults the currency when the export carries no currency column", () => {
    const { rows } = normalise(
      ["UsageDate,Cost,Tags", '20260801,1.00,{"costCenter":"Avionics"}', ""].join("\n"),
    );
    assert.equal(rows[0].currency, "USD");
  });
});

describe("normaliseExport — cost centre resolution", () => {
  const CSV = ["UsageDate,ResourceGroup,Cost,Tags", "20260801,MLS-RG-Ops,1.00,", ""].join("\n");

  it("prefers the costCenter tag, case-insensitively on the tag name", () => {
    const { rows } = normalise(
      ["UsageDate,ResourceGroup,Cost,Tags", '20260801,mls-rg-ops,1.00,{"CostCenter":"Propulsion"}', ""].join("\n"),
      { resourceGroupCostCenters: { "mls-rg-ops": "Cloud & IT" } },
    );
    assert.equal(rows[0].cost_center, "Propulsion");
  });

  it("falls back to the resource-group map, matched case-insensitively", () => {
    const { rows } = normalise(CSV, { resourceGroupCostCenters: { "mls-rg-ops": "Cloud & IT" } });
    assert.equal(rows[0].cost_center, "Cloud & IT");
  });

  it("files an untaggable, unmapped row in the fallback centre rather than dropping it", () => {
    const { rows, rejected } = normalise(CSV);
    assert.equal(rejected.length, 0);
    assert.equal(rows[0].cost_center, "Unallocated");
  });

  it("honours a configured fallback centre name", () => {
    const { rows } = normalise(CSV, { fallbackCostCenter: "Shared Platform" });
    assert.equal(rows[0].cost_center, "Shared Platform");
  });
});

describe("normaliseExport — malformed input", () => {
  it("throws with the headers it saw when there is no date column", () => {
    assert.throws(
      () => normalise("Widget,Cost\nsprocket,1.00\n"),
      (error: unknown) => {
        assert.ok(error instanceof CostExportFormatError);
        assert.match(error.message, /no date/);
        assert.match(error.message, /Widget, Cost/);
        return true;
      },
    );
  });

  it("throws when there is no amount column", () => {
    assert.throws(
      () => normalise("UsageDate,ResourceGroup\n20260801,mls-rg-ops\n"),
      (error: unknown) => error instanceof CostExportFormatError && /no amount/.test(error.message),
    );
  });

  it("rejects individual bad rows and keeps the good ones", () => {
    const { rows, rejected } = normalise(
      [
        "UsageDate,Cost,Tags",
        '20260801,1.00,{"costCenter":"Avionics"}',
        '20260899,2.00,{"costCenter":"Avionics"}',
        '20260802,n/a,{"costCenter":"Avionics"}',
        "",
      ].join("\n"),
    );
    assert.equal(rows.length, 1);
    assert.equal(rejected.length, 2);
    assert.match(rejected[0].reason, /unparseable date/);
    assert.match(rejected[1].reason, /unparseable amount/);
  });

  it("never turns a blank amount into a zero-cost row", () => {
    const { rows, rejected } = normalise(
      ["UsageDate,Cost,Tags", '20260801,,{"costCenter":"Avionics"}', ""].join("\n"),
    );
    assert.equal(rows.length, 0);
    assert.equal(rejected.length, 1);
  });

  it("survives a Tags cell that is not parseable at all", () => {
    const { rows } = normalise(
      ["UsageDate,Cost,Tags", '20260801,1.00,"}}not json{{"', ""].join("\n"),
    );
    assert.equal(rows[0].cost_center, "Unallocated");
  });
});

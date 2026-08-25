import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { groupByMonth, ingestExport, shouldIngest } from "../src/ingest.ts";
import type { PartitionWriter } from "../src/lakehouse.ts";

/**
 * An in-memory stand-in for OneLake. It records every call AND keeps the last
 * content per partition, so a test can assert both "how many writes" and "what
 * the lakehouse would now hold" — which is what idempotency actually means.
 */
function stubWriter() {
  const calls: { partitionKey: string; content: string }[] = [];
  const state = new Map<string, string>();
  const writer: PartitionWriter & {
    calls: typeof calls;
    state: typeof state;
  } = {
    calls,
    state,
    async replacePartition(partitionKey, content) {
      calls.push({ partitionKey, content });
      state.set(partitionKey, content); // replace, never append — as OneLake does
      return { path: `cost_daily/month=${partitionKey}/cost_daily.csv`, bytes: content.length };
    },
  };
  return writer;
}

const BUDGETS = { Propulsion: 8610, Avionics: 5670 };

/** A day-N month-to-date export: every day of the month so far, restated. */
function monthToDate(days: number, amountPerDay = 100): string {
  const lines = ["UsageDate,ResourceGroup,Cost,Currency,Tags"];
  for (let day = 1; day <= days; day += 1) {
    const date = `202608${String(day).padStart(2, "0")}`;
    lines.push(`${date},mls-rg-platform,${amountPerDay.toFixed(2)},USD,{"costCenter":"Propulsion"}`);
    lines.push(`${date},mls-rg-apps,${(amountPerDay / 2).toFixed(2)},USD,{"costCenter":"Avionics"}`);
  }
  return `${lines.join("\n")}\n`;
}

describe("shouldIngest", () => {
  it("accepts a data CSV anywhere in the export directory tree", () => {
    assert.equal(shouldIngest("mls-rg-ops/20260801-20260831/part_0_0001.csv"), true);
    assert.equal(shouldIngest("mls-cost-daily.csv"), true);
    assert.equal(shouldIngest("Nested/Path/MLS.CSV"), true);
  });

  it("skips the manifest and the metadata blobs Cost Management also writes", () => {
    assert.equal(shouldIngest("mls-rg-ops/20260801/manifest.json"), false);
    assert.equal(shouldIngest("_common/_metadata"), false);
    assert.equal(shouldIngest("dir/.checkpoint"), false);
  });

  it("skips non-CSV payloads and empty names", () => {
    assert.equal(shouldIngest("export.parquet"), false);
    assert.equal(shouldIngest("export.csv.gz"), false);
    assert.equal(shouldIngest(""), false);
    assert.equal(shouldIngest("   "), false);
  });
});

describe("groupByMonth", () => {
  it("groups by billing month, ascending", () => {
    const grouped = groupByMonth([
      { cost_id: "a", date: "2026-09-01", cost_center: "A", amount_usd: 1, budget_usd: null, currency: "USD" },
      { cost_id: "b", date: "2026-08-31", cost_center: "A", amount_usd: 1, budget_usd: null, currency: "USD" },
      { cost_id: "c", date: "2026-08-01", cost_center: "A", amount_usd: 1, budget_usd: null, currency: "USD" },
    ]);
    assert.deepEqual(grouped.map((group) => group.month), ["2026-08", "2026-09"]);
    assert.equal(grouped[0].rows.length, 2);
  });
});

describe("ingestExport — the happy path", () => {
  it("writes one partition per billing month and reports what it did", async () => {
    const writer = stubWriter();
    const outcome = await ingestExport({
      blobName: "mls-rg-ops/20260801-20260831/part_0.csv",
      content: monthToDate(2),
      writer,
      config: { costCenterBudgets: BUDGETS },
    });

    assert.equal(outcome.skipped, false);
    assert.equal(outcome.rowsWritten, 4); // 2 days x 2 cost centres
    assert.equal(outcome.rowsRejected, 0);
    assert.deepEqual(outcome.partitions.map((p) => p.month), ["2026-08"]);
    assert.equal(outcome.partitions[0].path, "cost_daily/month=2026-08/cost_daily.csv");
    assert.equal(writer.calls.length, 1);
  });

  it("writes the documented cost_daily header and derived ids", async () => {
    const writer = stubWriter();
    await ingestExport({ blobName: "e.csv", content: monthToDate(1), writer, config: { costCenterBudgets: BUDGETS } });

    const written = writer.state.get("2026-08") ?? "";
    const lines = written.trimEnd().split("\n");
    assert.equal(lines[0], "cost_id,date,cost_center,amount_usd,budget_usd,currency");
    assert.equal(lines[1], "CST-20260801-AVIONICS,2026-08-01,Avionics,50,5670,USD");
    assert.equal(lines[2], "CST-20260801-PROPULSION,2026-08-01,Propulsion,100,8610,USD");
  });

  it("splits a file that straddles a month boundary into two partitions", async () => {
    const writer = stubWriter();
    const outcome = await ingestExport({
      blobName: "e.csv",
      content: [
        "UsageDate,Cost,Tags",
        '20260731,1.00,{"costCenter":"Avionics"}',
        '20260801,2.00,{"costCenter":"Avionics"}',
        "",
      ].join("\n"),
      writer,
    });
    assert.deepEqual(outcome.partitions.map((p) => p.month), ["2026-07", "2026-08"]);
    assert.equal(writer.calls.length, 2);
  });
});

describe("ingestExport — idempotency", () => {
  it("re-ingesting the identical export writes byte-identical content", async () => {
    const writer = stubWriter();
    const content = monthToDate(5);
    const args = { blobName: "e.csv", content, writer, config: { costCenterBudgets: BUDGETS } };

    await ingestExport(args);
    const first = writer.state.get("2026-08");
    await ingestExport(args);
    const second = writer.state.get("2026-08");

    assert.equal(writer.calls.length, 2);
    assert.equal(first, second);
  });

  it("a re-exported day UPDATES rather than duplicating: row count stays flat", async () => {
    const writer = stubWriter();

    // Day 5's export, then day 6's — which restates days 1-5 and adds day 6.
    await ingestExport({ blobName: "d5.csv", content: monthToDate(5), writer });
    const afterDay5 = (writer.state.get("2026-08") ?? "").trimEnd().split("\n");
    await ingestExport({ blobName: "d6.csv", content: monthToDate(6), writer });
    const afterDay6 = (writer.state.get("2026-08") ?? "").trimEnd().split("\n");

    assert.equal(afterDay5.length, 1 + 5 * 2); // header + 5 days x 2 centres
    assert.equal(afterDay6.length, 1 + 6 * 2); // header + 6 days x 2 centres — NOT 5+6
    // Every cost_id is unique: an append would have produced 10 duplicates here.
    const ids = afterDay6.slice(1).map((line) => line.split(",")[0]);
    assert.equal(new Set(ids).size, ids.length);
  });

  it("a restated amount overwrites the earlier value instead of summing with it", async () => {
    const writer = stubWriter();
    await ingestExport({ blobName: "d1.csv", content: monthToDate(1, 100), writer });
    await ingestExport({ blobName: "d1-restated.csv", content: monthToDate(1, 80), writer });

    const rows = (writer.state.get("2026-08") ?? "").trimEnd().split("\n").slice(1);
    const propulsion = rows.find((line) => line.includes("Propulsion")) ?? "";
    assert.equal(propulsion.split(",")[3], "80");
  });

  it("touches only the months present in the export", async () => {
    const writer = stubWriter();
    await ingestExport({
      blobName: "july.csv",
      content: ["UsageDate,Cost,Tags", '20260715,9.00,{"costCenter":"Avionics"}', ""].join("\n"),
      writer,
    });
    await ingestExport({ blobName: "august.csv", content: monthToDate(1), writer });

    assert.deepEqual([...writer.state.keys()].sort(), ["2026-07", "2026-08"]);
    assert.match(writer.state.get("2026-07") ?? "", /2026-07-15/);
  });
});

describe("ingestExport — refusals and malformed input", () => {
  it("skips a manifest blob without writing anything", async () => {
    const writer = stubWriter();
    const outcome = await ingestExport({ blobName: "run/manifest.json", content: "{}", writer });
    assert.equal(outcome.skipped, true);
    assert.match(outcome.reason ?? "", /not a Cost Management CSV/);
    assert.equal(writer.calls.length, 0);
  });

  it("skips an empty blob", async () => {
    const writer = stubWriter();
    const outcome = await ingestExport({ blobName: "e.csv", content: "", writer });
    assert.equal(outcome.skipped, true);
    assert.match(outcome.reason ?? "", /empty/);
    assert.equal(writer.calls.length, 0);
  });

  it("REFUSES to replace a good month with a header-only export", async () => {
    const writer = stubWriter();
    await ingestExport({ blobName: "d1.csv", content: monthToDate(3), writer });
    const good = writer.state.get("2026-08");

    const outcome = await ingestExport({
      blobName: "empty.csv",
      content: "UsageDate,Cost,Currency,Tags\n",
      writer,
    });

    assert.equal(outcome.skipped, true);
    assert.match(outcome.reason ?? "", /no data rows/);
    assert.equal(writer.calls.length, 1); // still just the first write
    assert.equal(writer.state.get("2026-08"), good); // history intact
  });

  it("throws when the file is not a cost export at all", async () => {
    const writer = stubWriter();
    await assert.rejects(
      () => ingestExport({ blobName: "e.csv", content: "Widget,Sprocket\n1,2\n", writer }),
      (error: unknown) => (error as Error).name === "CostExportFormatError",
    );
    assert.equal(writer.calls.length, 0);
  });

  it("throws when EVERY row rejects — that is schema drift, not an empty month", async () => {
    const writer = stubWriter();
    await assert.rejects(
      () =>
        ingestExport({
          blobName: "e.csv",
          content: ["UsageDate,Cost,Tags", "not-a-date,n/a,", "also-bad,n/a,", ""].join("\n"),
          writer,
        }),
      /Every one of the 2 row\(s\).*schema drift/s,
    );
    assert.equal(writer.calls.length, 0);
  });

  it("still writes the good rows when only some reject, and counts the rest", async () => {
    const writer = stubWriter();
    const outcome = await ingestExport({
      blobName: "e.csv",
      content: [
        "UsageDate,Cost,Tags",
        '20260801,1.00,{"costCenter":"Avionics"}',
        "bad,2.00,",
        "",
      ].join("\n"),
      writer,
    });
    assert.equal(outcome.skipped, false);
    assert.equal(outcome.rowsWritten, 1);
    assert.equal(outcome.rowsRejected, 1);
  });

  it("reports ragged lines the parser dropped", async () => {
    const writer = stubWriter();
    const outcome = await ingestExport({
      blobName: "e.csv",
      content: [
        "UsageDate,Cost,Tags",
        '20260801,1.00,{"costCenter":"Avionics"}',
        "20260802,2.00",
        "",
      ].join("\n"),
      writer,
    });
    assert.equal(outcome.raggedLines, 1);
    assert.equal(outcome.rowsWritten, 1);
  });

  it("propagates a writer failure rather than reporting success", async () => {
    const failing: PartitionWriter = {
      async replacePartition() {
        throw new Error("OneLake refused the create (403).");
      },
    };
    await assert.rejects(
      () => ingestExport({ blobName: "e.csv", content: monthToDate(1), writer: failing }),
      /OneLake refused/,
    );
  });
});

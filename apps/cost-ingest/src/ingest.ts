// =============================================================================
// The ingestion orchestration: one exported blob in, N month partitions out.
//
// Everything host-specific (blob trigger bindings, app settings, managed
// identity) lives in src/functions/cost-ingest.ts. This module has no
// dependencies and an injected writer, so the whole pipeline is unit-testable
// with zero cloud calls — the same split apps/directline-token uses.
//
// THE IDEMPOTENCY CONTRACT, stated once so it can be tested against:
//
//   Ingesting the same export twice writes byte-identical content to the same
//   path, and ingesting a LATER export of the same month replaces that month
//   rather than adding to it. Both follow from three properties:
//     * cost_id is derived from (date, cost_center)      — costDaily.ts
//     * rows are aggregated and totally ordered          — normalise.ts
//     * a partition is replaced, never appended to       — lakehouse.ts
//
// TWO REFUSALS THAT ARE FEATURES, NOT DEFENSIVENESS:
//
//   * A file that yields ZERO rows never writes. Cost Management occasionally
//     lands a header-only file (a fresh export's first run, a scope with no
//     usage yet). Replacing a good month with an empty file would silently
//     erase cost history from the control tower's chart, and the next day's
//     export would restore it — an intermittent, unexplainable gap. Skipping is
//     always the right answer here.
//   * A file whose rows ALL reject throws. Individually bad rows are ordinary
//     messiness; a 100% rejection rate means the schema moved under us
//     (L06 failure mode 5, "schema drift in the export CSV") and a human needs
//     to see a failed invocation, not a quiet no-op.
// =============================================================================

import { parseCsv, toCsv } from "./csv.ts";
import { COST_DAILY_COLUMNS, monthOf, type CostDailyRow } from "./costDaily.ts";
import { normaliseExport, type NormaliseConfig } from "./normalise.ts";
import type { PartitionWriter } from "./lakehouse.ts";

export type IngestConfig = NormaliseConfig;

export type IngestOutcome = {
  readonly blobName: string;
  /** True when the blob was deliberately not ingested; `reason` says why. */
  readonly skipped: boolean;
  readonly reason?: string;
  /** Partitions written, in ascending month order. */
  readonly partitions: readonly { readonly month: string; readonly rows: number; readonly path: string }[];
  readonly rowsWritten: number;
  readonly rowsRejected: number;
  /** Ragged CSV lines dropped by the parser (column-count mismatch). */
  readonly raggedLines: number;
  readonly resolvedColumns: Readonly<Record<string, string | null>>;
};

/**
 * Should this blob be ingested at all?
 *
 * Cost Management writes more than the data file into the export container: a
 * `manifest.json` per run, and (for partitioned exports) `_common` metadata.
 * The trigger's path filter cannot express "csv only" reliably across export
 * versions, so the check lives here where it can be tested.
 */
export function shouldIngest(blobName: string): boolean {
  const name = (blobName ?? "").trim();
  if (name === "") return false;
  const leaf = name.split("/").pop() ?? "";
  if (leaf.startsWith("_") || leaf.startsWith(".")) return false;
  if (leaf.toLowerCase() === "manifest.json") return false;
  return leaf.toLowerCase().endsWith(".csv");
}

/** Groups normalised rows by billing month, ascending. */
export function groupByMonth(
  rows: readonly CostDailyRow[],
): { month: string; rows: CostDailyRow[] }[] {
  const byMonth = new Map<string, CostDailyRow[]>();
  for (const row of rows) {
    const month = monthOf(row.date);
    const bucket = byMonth.get(month);
    if (bucket) bucket.push(row);
    else byMonth.set(month, [row]);
  }
  return [...byMonth.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([month, monthRows]) => ({ month, rows: monthRows }));
}

/**
 * Ingests one Cost Management export blob into the lakehouse.
 *
 * @throws CostExportFormatError when the file is not a cost export (no
 *         recognisable date/amount column), or when every row rejects.
 * @throws LakehouseWriteError when OneLake refuses a write.
 */
export async function ingestExport(input: {
  readonly blobName: string;
  readonly content: string;
  readonly writer: PartitionWriter;
  readonly config?: IngestConfig;
}): Promise<IngestOutcome> {
  const { blobName, content, writer } = input;

  if (!shouldIngest(blobName)) {
    return {
      blobName,
      skipped: true,
      reason: "not a Cost Management CSV data file (metadata, manifest or non-CSV blob)",
      partitions: [],
      rowsWritten: 0,
      rowsRejected: 0,
      raggedLines: 0,
      resolvedColumns: {},
    };
  }

  const table = parseCsv(content ?? "");
  if (table.headers.length === 0) {
    return {
      blobName,
      skipped: true,
      reason: "the blob is empty",
      partitions: [],
      rowsWritten: 0,
      rowsRejected: 0,
      raggedLines: 0,
      resolvedColumns: {},
    };
  }

  // Throws CostExportFormatError if this is not a cost export at all.
  const { rows, rejected, resolvedColumns } = normaliseExport(table, input.config);

  if (rows.length === 0) {
    if (rejected.length > 0) {
      // Every row failed: schema drift, not messy data. Fail loudly.
      const reasons = [...new Set(rejected.map((entry) => entry.reason))].join("; ");
      throw new Error(
        `Every one of the ${rejected.length} row(s) in ${blobName} was rejected (${reasons}). ` +
          "Refusing to treat a total rejection as an empty export — this is schema drift " +
          "(L06 failure mode 5); fix the column mapping in normalise.ts.",
      );
    }
    return {
      blobName,
      skipped: true,
      reason: "the export contains no data rows; refusing to replace a partition with nothing",
      partitions: [],
      rowsWritten: 0,
      rowsRejected: 0,
      raggedLines: table.ragged.length,
      resolvedColumns,
    };
  }

  const partitions: { month: string; rows: number; path: string }[] = [];
  for (const group of groupByMonth(rows)) {
    const written = await writer.replacePartition(
      group.month,
      toCsv(COST_DAILY_COLUMNS, group.rows as unknown as Record<string, unknown>[]),
    );
    partitions.push({ month: group.month, rows: group.rows.length, path: written.path });
  }

  return {
    blobName,
    skipped: false,
    partitions,
    rowsWritten: rows.length,
    rowsRejected: rejected.length,
    raggedLines: table.ragged.length,
    resolvedColumns,
  };
}

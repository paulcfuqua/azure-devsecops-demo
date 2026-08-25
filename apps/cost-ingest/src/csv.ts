// =============================================================================
// A small, dependency-free RFC 4180 CSV reader, sized for Cost Management
// exports and nothing else.
//
// Why hand-rolled rather than a library: this module is imported by the ingest
// path, which is unit-tested with `node --test` and no `npm install` (the same
// discipline apps/directline-token uses — the binding shim owns the SDK
// dependencies, the logic does not). A 90-line parser we can read beats a
// transitive dependency graph in a function that runs on a consumption plan.
//
// What it must survive, all of it observed in real Cost Management exports:
//
//   * a UTF-8 BOM on the first header cell (Cost Management writes one);
//   * CRLF, LF, or a mix, including a missing final newline;
//   * quoted fields containing commas, newlines and doubled ("") quotes — the
//     `Tags` column is the usual culprit: `"""costCenter"": ""Propulsion"""`;
//   * ragged rows (a short row is NOT silently padded — the caller decides).
//
// The parser is deliberately not streaming. A daily month-to-date export for
// this demo estate is a few hundred KB; a consumption Function reading that
// into memory is fine, and the blob trigger hands us the whole buffer anyway.
// =============================================================================

/** One parsed record: header name -> raw cell text, both already trimmed. */
export type CsvRecord = Readonly<Record<string, string>>;

export type CsvTable = {
  /** Header names in file order, BOM-stripped, trimmed. */
  readonly headers: readonly string[];
  /** Data rows, header-keyed. Ragged rows are reported, not repaired. */
  readonly records: readonly CsvRecord[];
  /**
   * Rows whose field count did not match the header. Kept out of `records` so
   * a truncated export cannot quietly shift every column by one.
   */
  readonly ragged: readonly { readonly line: number; readonly fields: readonly string[] }[];
};

/** A byte-order mark on the first cell would poison the first header name. */
function stripBom(text: string): string {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

/**
 * Splits CSV text into rows of raw fields. Quotes are honoured; everything
 * outside quotes is split on `,` and newlines.
 */
export function splitCsvRows(text: string): string[][] {
  const rows: string[][] = [];
  const source = stripBom(text);

  let field = "";
  let row: string[] = [];
  let inQuotes = false;
  // A quote only OPENS a quoted field at the start of that field. A quote in the
  // middle of an unquoted field is a literal character — which is exactly how
  // spreadsheets read it, and it matters here because a Cost Management `Tags`
  // cell is sometimes emitted unquoted as {"costCenter":"Propulsion"}. Treating
  // those inner quotes as delimiters would silently strip the braces' contents.
  let fieldStarted = false;
  let rowStarted = false;

  const endRow = (): void => {
    row.push(field);
    rows.push(row);
    row = [];
    field = "";
    fieldStarted = false;
    rowStarted = false;
  };

  for (let i = 0; i < source.length; i += 1) {
    const char = source[i];

    if (inQuotes) {
      if (char === '"') {
        if (source[i + 1] === '"') {
          field += '"';
          i += 1; // consume the escaped quote
        } else {
          inQuotes = false;
        }
      } else {
        field += char;
      }
      continue;
    }

    if (char === '"' && !fieldStarted) {
      inQuotes = true;
      fieldStarted = true;
      rowStarted = true;
      continue;
    }

    if (char === ",") {
      row.push(field);
      field = "";
      fieldStarted = false;
      rowStarted = true;
      continue;
    }

    if (char === "\r") {
      // Swallow CR; the LF that follows (or does not) ends the row.
      if (source[i + 1] === "\n") continue;
      endRow();
      continue;
    }

    if (char === "\n") {
      endRow();
      continue;
    }

    field += char;
    fieldStarted = true;
    rowStarted = true;
  }

  // A file with no trailing newline still has one last row to emit. A file that
  // *did* end with a newline leaves nothing pending, which is the trailing blank
  // line, not a record.
  if (rowStarted || fieldStarted || row.length > 0) {
    row.push(field);
    rows.push(row);
  }

  return rows;
}

/**
 * Parses CSV text into header-keyed records.
 *
 * Blank lines are dropped rather than reported as ragged: Cost Management pads
 * some exports with them and they carry no information.
 */
export function parseCsv(text: string): CsvTable {
  const rows = splitCsvRows(text ?? "");
  const meaningful = rows
    .map((fields, index) => ({ fields, line: index + 1 }))
    .filter((entry) => !(entry.fields.length === 1 && entry.fields[0].trim() === ""));

  if (meaningful.length === 0) {
    return { headers: [], records: [], ragged: [] };
  }

  const headers = meaningful[0].fields.map((name) => name.trim());
  const records: CsvRecord[] = [];
  const ragged: { line: number; fields: readonly string[] }[] = [];

  for (const entry of meaningful.slice(1)) {
    if (entry.fields.length !== headers.length) {
      ragged.push({ line: entry.line, fields: entry.fields });
      continue;
    }
    const record: Record<string, string> = {};
    headers.forEach((name, index) => {
      record[name] = entry.fields[index].trim();
    });
    records.push(record);
  }

  return { headers, records, ragged };
}

/**
 * Renders rows back to CSV with a fixed column order, LF newlines and a
 * trailing newline — byte-stable, so re-ingesting an unchanged export writes an
 * identical file. Byte-stability is what makes the idempotency claim checkable
 * rather than merely asserted.
 */
export function toCsv(
  columns: readonly string[],
  rows: readonly Record<string, unknown>[],
): string {
  const cell = (value: unknown): string => {
    if (value === null || value === undefined) return "";
    const text = String(value);
    return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  };
  const lines = [columns.join(",")];
  for (const row of rows) {
    lines.push(columns.map((column) => cell(row[column])).join(","));
  }
  return `${lines.join("\n")}\n`;
}
